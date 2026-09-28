import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import APICore
import APIStore
import DesignSystem
import GRPCEngine
import ProtoKit

enum GRPCTab: String, CaseIterable, Hashable {
    case message, metadata, auth, schema, settings, docs

    var title: String {
        switch self {
        case .message: L("Message")
        case .metadata: L("Metadata")
        case .auth: L("Authorization")
        case .schema: L("Service Definition")
        case .settings: L("Settings")
        case .docs: L("Docs")
        }
    }
}

struct GRPCEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var document: RequestDocument
    let workspace: Workspace
    @State private var tab: GRPCTab = .message
    @State private var isImportingProto = false

    private var session: GRPCSessionModel { document.grpc }
    private var node: CollectionNode? { document.nodeID.flatMap { CollectionQueries.node($0, in: context) } }
    private var requestContext: RequestContext {
        RequestContext(spec: document.spec, node: node, workspace: workspace, secrets: model.services.secrets)
    }

    var body: some View {
        ResizableVSplit(id: "grpc") {
            VStack(alignment: .leading, spacing: 10) {
                RequestTitleBar(document: document)
                targetBar
                methodBar
                UnderlineTabs(GRPCTab.allCases, selection: $tab, title: \.title)
                Divider()
                tabContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding([.horizontal, .top], 14)
            .frame(maxWidth: .infinity, minHeight: 260, idealHeight: 360)
        } bottom: {
            GRPCResponseView(session: session)
                .frame(minHeight: 160)
        }
        .onAppear {
            if session.schema == nil, !document.spec.protoSource.isEmpty { loadSchema() }
        }
        .fileImporter(isPresented: $isImportingProto, allowedContentTypes: [UTType(filenameExtension: "proto") ?? .plainText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                document.spec.protoSource = text
                loadSchema()
            }
        }
    }

    private var targetBar: some View {
        HStack(spacing: 8) {
            Text("gRPC")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.pink)
                .frame(minWidth: 44)
            VariableTextField(L("Server address, e.g. localhost:50051 or grpcs://api.example.com"), text: $document.spec.url,
                              identifier: "url-field", lookup: VariableLookup(workspace: workspace, node: node).info)
            if session.isCalling {
                Button(L("Cancel"), role: .cancel) { session.cancel() }.controlSize(.large)
            } else {
                Button(L("Invoke")) { invoke() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session.method(for: document.spec) == nil)
                    .accessibilityIdentifier("invoke-button")
            }
        }
    }

    private var methodBar: some View {
        HStack(spacing: 8) {
            Picker(L("Method"), selection: $document.spec.grpcMethod) {
                Text(L("Select a method")).tag("")
                ForEach(session.schema?.services ?? [], id: \.fullName) { service in
                    Section(service.fullName) {
                        ForEach(service.methods, id: \.name) { method in
                            Text("\(method.name)  ·  \(method.kindLabel)").tag("\(service.fullName)/\(method.name)")
                        }
                    }
                }
            }
            .frame(maxWidth: 520)
            Button(document.spec.protoSource.isEmpty ? L("Use Server Reflection") : L("Reload .proto")) { loadSchema() }
                .disabled(session.isLoadingSchema)
            if session.isLoadingSchema { ProgressView().controlSize(.small) }
            if let error = session.schemaError {
                Text(error).foregroundStyle(.red).font(.caption).lineLimit(2)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .message:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let method = session.method(for: document.spec) {
                        Text("\(method.inputType) → \(method.outputType)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        if method.clientStreaming {
                            Text(L("Client streaming: enter a JSON array of messages.")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button(L("Use Example Message")) {
                        if let template = session.template(for: document.spec) { document.spec.body.raw = template }
                    }
                    .disabled(session.method(for: document.spec) == nil)
                }
                CodeEditor(text: $document.spec.body.raw, language: .json, identifier: "grpc-message")
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
        case .metadata:
            ScrollView { KeyValueTable(rows: $document.spec.headers, keyPlaceholder: L("Metadata key")) }
        case .auth:
            ScrollView {
                AuthEditor(auth: $document.spec.auth, allowsInherit: true, resolver: { requestContext.resolver })
            }
        case .schema:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("Paste a .proto definition, import a file, or leave empty to use server reflection.")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Import .proto…")) { isImportingProto = true }
                    Button(L("Parse")) { loadSchema() }.disabled(document.spec.protoSource.isEmpty)
                }
                CodeEditor(text: $document.spec.protoSource, language: .plain, identifier: "proto-source")
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
        case .settings:
            Form {
                TextField(L("Deadline (ms, 0 = none)"), value: $document.spec.settings.timeoutMilliseconds, format: .number)
                Toggle(L("Verify TLS certificates"), isOn: $document.spec.settings.verifySSL)
                Text(L("Use grpcs:// or https:// for TLS; host:port or grpc:// connects in plaintext (h2c).")).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        case .docs:
            if let node {
                MarkdownDescriptionEditor(text: Binding(get: { node.descriptionMD }, set: { node.descriptionMD = $0; try? context.save() }))
            } else {
                Text(L("Save the request to a collection to document it.")).foregroundStyle(.secondary)
            }
        }
    }

    private func loadSchema() {
        let requestContext = requestContext
        session.loadSchema(from: document.spec, resolver: requestContext.resolver, metadata: document.spec.headers)
    }

    private func invoke() {
        let requestContext = requestContext
        session.invoke(document.spec, resolver: requestContext.resolver, auth: requestContext.effectiveAuth(for: document.spec),
                       console: model.services.console, requestName: document.name)
    }
}

private struct GRPCResponseView: View {
    let session: GRPCSessionModel
    @State private var selection: GRPCSessionModel.Entry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(L("Response")).font(.headline)
                if session.isCalling { ProgressView().controlSize(.small) }
                if let status = session.status {
                    Text(verbatim: "\(status.code) \(status.name)")
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(status.isOK ? .green : .red)
                        .accessibilityIdentifier("grpc-status")
                    if !status.message.isEmpty { Text(status.message).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if let duration = session.duration { Text(ResponseStatusBar.duration(duration)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if session.entries.isEmpty && session.status == nil {
                ContentUnavailableView(L("No Response"), systemImage: "bolt.horizontal",
                                       description: Text(L("Load the service definition, choose a method and click Invoke.")))
            } else {
                ResizableHSplit(id: "grpc-response", initialFraction: 0.55, minLeft: 240, minRight: 200, showsRight: !session.entries.isEmpty) {
                    List(selection: $selection) {
                        ForEach(session.entries) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: icon(entry.kind)).foregroundStyle(color(entry.kind))
                                Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(2)
                                Spacer()
                                Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.tertiary)
                            }
                            .tag(entry.id)
                        }
                        if let status = session.status, !status.trailers.isEmpty {
                            Section(L("Trailers")) {
                                ForEach(status.trailers) { Text("\($0.key): \($0.value)").font(.system(.callout, design: .monospaced)) }
                            }
                        }
                    }
                    .frame(minWidth: 280)
                } right: {                    let selected = session.entries.first { $0.id == selection } ?? session.entries.last { $0.kind == .received }
                    if let selected {
                        CodeEditor(text: .constant(selected.text), language: selected.kind == .headers ? .plain : .json, isEditable: false)
                            .frame(minWidth: 240)
                    }
                }
            }
        }
    }

    private func icon(_ kind: GRPCSessionModel.Entry.Kind) -> String {
        switch kind {
        case .sent: "arrow.up"
        case .received: "arrow.down"
        case .headers: "list.bullet.rectangle"
        case .status: "flag"
        }
    }

    private func color(_ kind: GRPCSessionModel.Entry.Kind) -> Color {
        switch kind {
        case .sent: .orange
        case .received: .green
        default: .secondary
        }
    }
}
