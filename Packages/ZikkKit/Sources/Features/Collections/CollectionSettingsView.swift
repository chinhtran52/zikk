import SwiftUI
import SwiftData
import APICore
import APIStore
import DesignSystem
import Docs

enum ContainerSettingsTab: String, CaseIterable, Hashable {
    case overview, auth, scripts, variables

    var title: String {
        switch self {
        case .overview: L("Overview")
        case .auth: L("Authorization")
        case .scripts: L("Scripts")
        case .variables: L("Variables")
        }
    }
}

/// Settings for a collection: description, auth, scripts and variables. Edits are saved immediately.
struct CollectionSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var collection: APICollection
    let workspace: Workspace
    @State private var tab: ContainerSettingsTab = .overview

    var body: some View {
        ContainerSettingsLayout(title: $collection.name, tab: $tab, tabs: ContainerSettingsTab.allCases) {
            switch tab {
            case .overview:
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button(L("View Documentation"), systemImage: "book") { model.open(.docs(collection.id), title: collection.name + " – " + L("Docs")) }
                        Button(L("Run Collection…"), systemImage: "play") { model.openRunner(collection: collection) }
                    }
                    MarkdownDescriptionEditor(text: $collection.descriptionMD)
                }
            case .auth:
                AuthEditor(auth: Binding(get: { collection.auth }, set: { collection.auth = $0 }), allowsInherit: false, resolver: resolver)
            case .scripts:
                ScriptsEditor(preRequest: $collection.preRequestScript, tests: $collection.testScript)
            case .variables:
                VariablesEditorView(title: "", scope: collection.id, load: { collection.variables }, store: { collection.variables = $0 })
            }
        }
        .onChange(of: collection.name) { try? context.save() }
    }

    private func resolver() -> VariableResolver {
        RequestContext(spec: RequestSpec(), node: collection.rootNodes.first, workspace: workspace, secrets: model.services.secrets).resolver
    }
}

/// Settings for a folder: description, auth and scripts.
struct FolderSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var folder: CollectionNode
    let workspace: Workspace
    @State private var tab: ContainerSettingsTab = .overview

    var body: some View {
        ContainerSettingsLayout(title: $folder.name, tab: $tab, tabs: [.overview, .auth, .scripts]) {
            switch tab {
            case .overview, .variables:
                MarkdownDescriptionEditor(text: $folder.descriptionMD)
            case .auth:
                AuthEditor(auth: Binding(get: { folder.auth }, set: { folder.auth = $0 }), allowsInherit: true, resolver: {
                    RequestContext(spec: RequestSpec(), node: folder, workspace: workspace, secrets: model.services.secrets).resolver
                })
            case .scripts:
                ScriptsEditor(preRequest: $folder.preRequestScript, tests: $folder.testScript)
            }
        }
        .onChange(of: folder.name) {
            model.nodeRenamed(folder)
            try? context.save()
        }
    }
}

private struct ContainerSettingsLayout<Content: View>: View {
    @Binding var title: String
    @Binding var tab: ContainerSettingsTab
    let tabs: [ContainerSettingsTab]
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("Name"), text: $title)
                .textFieldStyle(.plain)
                .font(.title2.bold())
            UnderlineTabs(tabs, selection: $tab, title: \.title)
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDisabled(tab == .scripts || tab == .overview)
        }
        .padding(16)
    }
}

/// Markdown editor with a live rendered preview.
struct MarkdownDescriptionEditor: View {
    @Binding var text: String
    @State private var isPreviewing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $isPreviewing) {
                Text(L("Preview")).tag(true)
                Text(L("Edit")).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if isPreviewing {
                if text.isEmpty {
                    Text(L("No description. Switch to Edit to add one using Markdown."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    WebPreview(data: Data(MarkdownRenderer.page(text).utf8), mimeType: "text/html", baseURL: nil, allowsJavaScript: false)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
            } else {
                CodeEditor(text: $text, language: .plain)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
        }
        .frame(minHeight: 200)
    }

    /// Inline rendering for short texts inside native views.
    static func render(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    }
}
