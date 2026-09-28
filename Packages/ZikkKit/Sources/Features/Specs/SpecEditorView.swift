import SwiftUI
import SwiftData
import AppKit
import APICore
import APIStore
import DesignSystem
import Interop
import SpecKit

struct SpecsSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let workspace: Workspace
    @State private var renaming: APISpec?

    private var specs: [APISpec] {
        workspace.specs.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            ForEach(specs) { spec in
                Button {
                    model.open(.spec(spec.id), title: spec.name)
                } label: {
                    HStack {
                        Label(spec.name, systemImage: "doc.text")
                        Spacer()
                        if spec.linkedCollectionID != nil {
                            Image(systemName: "link").foregroundStyle(.secondary).help(L("Linked to a collection"))
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(L("Rename…")) { renaming = spec }
                    Button(L("Export…")) { model.export(spec) }
                    Divider()
                    Button(L("Delete"), role: .destructive) {
                        model.closeTabs { $0.content == .spec(spec.id) }
                        context.delete(spec)
                        try? context.save()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if specs.isEmpty {
                ContentUnavailableView(L("No API Specs"), systemImage: "doc.text",
                                       description: Text(L("Design APIs with OpenAPI, generate collections from them and validate responses against them.")))
            }
        }
        .safeAreaBar(edge: .bottom) {
            SidebarBottomBar(title: L("New API Spec"), action: add) {
                SidebarIconButton(systemImage: "square.and.arrow.down", help: L("Import…")) { model.isShowingImport = true }
            }
        }
        .renameAlert(item: $renaming, name: \.name) { spec, name in
            spec.name = name
            try? context.save()
        }
    }

    private func add() {
        let spec = APISpec(name: L("New API"), format: .yaml, content: SpecServices.template)
        spec.workspace = workspace
        context.insert(spec)
        try? context.save()
        model.open(.spec(spec.id), title: spec.name)
    }
}

/// OpenAPI editor: outline, source with diagnostics, preview, and collection sync.
struct SpecEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var spec: APISpec
    let workspace: Workspace
    @State private var diagnostics: [SpecDiagnostic] = []
    @State private var outline: [SpecOutline.Item] = []
    @State private var document: SpecDocument?
    @State private var revealLine: Int?
    @State private var showsPreview = false
    @State private var isSyncing = false
    @State private var errorMessage: String?

    private var linkedCollection: APICollection? {
        spec.linkedCollectionID.flatMap { id in workspace.collections.first { $0.id == id && $0.deletedAt == nil } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ResizableHSplit(id: "spec-outline", initialFraction: 0.22, minLeft: 150, minRight: 300) {
                List {
                    OutlineGroup(outline, children: \.children) { item in
                        Button {
                            revealLine = item.line
                        } label: {
                            HStack {
                                Text(item.title).lineLimit(1)
                                if let detail = item.detail {
                                    Text(detail).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)

            } right: {                if showsPreview, let document {
                    SpecPreviewView(document: document)
                        .frame(minWidth: 400)
                } else {
                    ResizableVSplit(id: "spec") {
                        CodeEditor(text: $spec.content, language: spec.format == .json ? .json : .yaml, wrapsLines: false,
                                   identifier: "spec-editor", lineMarkers: markers, revealLine: $revealLine)
                            .frame(minHeight: 200)
                    } bottom: {
                        DiagnosticsList(diagnostics: diagnostics) { revealLine = $0 }
                            .frame(minHeight: 60, idealHeight: 120)
                    }
                    .frame(minWidth: 400)
                }
            }
        }
        .task(id: spec.content) { await revalidate() }
        .sheet(isPresented: $isSyncing) {
            if let document, let linkedCollection {
                SpecSyncSheet(spec: spec, document: document, collection: linkedCollection)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField(L("Name"), text: $spec.name)
                .textFieldStyle(.plain)
                .font(.title3.bold())
                .frame(maxWidth: 260)
            Picker("", selection: $spec.format) {
                Text("YAML").tag(SpecFormat.yaml)
                Text("JSON").tag(SpecFormat.json)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            statusBadge
            Spacer()
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption).lineLimit(1) }
            Toggle(isOn: $showsPreview) { Label(L("Preview"), systemImage: "doc.richtext") }
                .toggleStyle(.button)
                .disabled(document == nil)
            Menu {
                Picker(L("Linked collection"), selection: $spec.linkedCollectionID) {
                    Text(L("None")).tag(UUID?.none)
                    ForEach(workspace.collections.filter { $0.deletedAt == nil }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Divider()
                Button(L("Generate New Collection")) { generate() }
                Button(L("Sync Linked Collection…")) { isSyncing = true }
                    .disabled(linkedCollection == nil || document == nil)
            } label: {
                Label(linkedCollection?.name ?? L("Collection"), systemImage: "link")
            }
            .fixedSize()
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let errors = diagnostics.filter { $0.severity == .error }.count
        let warnings = diagnostics.count - errors
        if errors > 0 {
            Label(String(format: L("%lld errors"), errors), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        } else if warnings > 0 {
            Label(String(format: L("%lld warnings"), warnings), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if document != nil {
            Label(L("Valid"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        }
    }

    private var markers: [Int: NSColor] {
        var result: [Int: NSColor] = [:]
        for diagnostic in diagnostics.reversed() {
            result[diagnostic.line] = diagnostic.severity == .error ? NSColor.systemRed.withAlphaComponent(0.18) : NSColor.systemOrange.withAlphaComponent(0.18)
        }
        return result
    }

    private func revalidate() async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let text = spec.content
        let result = await Task.detached(priority: .userInitiated) { () -> ([SpecDiagnostic], SpecDocument?) in
            (SpecValidator.validate(text), try? SpecDocument(text: text))
        }.value
        diagnostics = result.0
        document = result.1
        outline = result.1.map { SpecOutline($0).items } ?? []
        try? context.save()
    }

    private func generate() {
        do {
            let collection = try SpecServices.generateCollection(from: spec, workspace: workspace, context: context, secrets: model.services.secrets)
            errorMessage = nil
            model.section = .collections
            model.open(.collection(collection.id), title: collection.name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DiagnosticsList: View {
    let diagnostics: [SpecDiagnostic]
    let onSelect: (Int) -> Void

    var body: some View {
        if diagnostics.isEmpty {
            Label(L("No problems found"), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(diagnostics) { diagnostic in
                Button {
                    onSelect(diagnostic.line)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                        Text(diagnostic.message)
                        Spacer()
                        Text(String(format: L("Line %lld"), diagnostic.line)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("spec-diagnostic")
            }
            .listStyle(.plain)
        }
    }
}

/// Lets the user review and apply spec → collection changes.
private struct SpecSyncSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let spec: APISpec
    let document: SpecDocument
    let collection: APICollection
    @State private var changes: [SpecSync.Change] = []
    @State private var selected: Set<String> = []
    @State private var basePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Sync Collection with Spec")).font(.title2.bold())
            Text(String(format: L("Changes to apply to “%@” so it matches the spec. Your scripts, auth and parameter values are kept."), collection.name))
                .foregroundStyle(.secondary)
            if changes.isEmpty {
                ContentUnavailableView(L("Up to date"), systemImage: "checkmark.circle", description: Text(L("The collection already matches the spec.")))
            } else {
                List(changes) { change in
                    Toggle(isOn: Binding(get: { selected.contains(change.id) }, set: { if $0 { selected.insert(change.id) } else { selected.remove(change.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(title(for: change.kind))
                                    .font(.caption.bold())
                                    .foregroundStyle(color(for: change.kind))
                                Text(change.key).font(.system(.body, design: .monospaced))
                                Text(change.name).foregroundStyle(.secondary)
                            }
                            ForEach(change.details, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .frame(minHeight: 240)
            }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Apply Changes")) {
                    SpecServices.apply(changes.filter { selected.contains($0.id) }, to: collection, basePath: basePath, context: context)
                    spec.lastSyncHash = String(spec.content.hashValue)
                    try? context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            let generated = OpenAPIImporter.collection(from: document)
            basePath = SpecSync.basePath(of: generated)
            changes = SpecSync.diff(spec: generated, collection: InteropMapper.export(collection, secrets: model.services.secrets))
            selected = Set(changes.filter { $0.kind != .removed }.map(\.id))
        }
    }

    private func title(for kind: SpecSync.Change.Kind) -> String {
        switch kind {
        case .added: L("ADDED")
        case .removed: L("REMOVED")
        case .modified: L("CHANGED")
        }
    }

    private func color(for kind: SpecSync.Change.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .modified: .orange
        }
    }
}
