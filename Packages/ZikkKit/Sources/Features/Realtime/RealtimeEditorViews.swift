import SwiftUI
import SwiftData
import AppKit
import APICore
import APIStore
import DesignSystem
import RealtimeEngine

enum RealtimeTab: String, CaseIterable, Hashable {
    case message, params, headers, auth, settings, docs

    var title: String {
        switch self {
        case .message: L("Message")
        case .params: L("Params")
        case .headers: L("Headers")
        case .auth: L("Authorization")
        case .settings: L("Settings")
        case .docs: L("Docs")
        }
    }
}

/// Editor for WebSocket and Server-Sent Events requests.
struct RealtimeEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var document: RequestDocument
    let workspace: Workspace
    @State private var tab: RealtimeTab = .message
    @State private var format: SavedMessage.Format = .text

    private var isWebSocket: Bool { document.spec.kind == .webSocket }
    private var session: RealtimeSessionModel { document.realtime }
    private var node: CollectionNode? { document.nodeID.flatMap { CollectionQueries.node($0, in: context) } }

    private var tabs: [RealtimeTab] {
        isWebSocket ? RealtimeTab.allCases : [.params, .headers, .auth, .settings, .docs]
    }

    var body: some View {
        ResizableVSplit(id: "realtime") {
            VStack(alignment: .leading, spacing: 10) {
                RequestTitleBar(document: document)
                connectionBar
                UnderlineTabs(tabs, selection: $tab, title: \.title)
                Divider()
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding([.horizontal, .top], 14)
            .frame(maxWidth: .infinity, minHeight: 220, idealHeight: 320)
        } bottom: {
            RealtimeLogView(session: session)
                .frame(minHeight: 160)
        }
        .onAppear { if !isWebSocket, tab == .message { tab = .params } }
    }

    private var connectionBar: some View {
        HStack(spacing: 8) {
            Text(isWebSocket ? "WS" : "SSE")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.pink)
                .frame(minWidth: 44)
            VariableTextField(isWebSocket ? L("Enter a WebSocket URL (ws:// or wss://)") : L("Enter an event stream URL"),
                              text: Binding(get: { document.spec.url }, set: document.setURL), identifier: "url-field",
                              lookup: VariableLookup(workspace: workspace, node: node).info, onSubmit: toggleConnection)
            statusIndicator
            Button(session.isActive ? L("Disconnect") : L("Connect"), action: toggleConnection)
                .buttonStyle(.borderedProminent)
                .tint(session.isActive ? .red : .accentColor)
                .controlSize(.large)
                .accessibilityIdentifier("connect-button")
        }
    }

    private var statusIndicator: some View {
        let (color, label): (Color, String) = switch session.status {
        case .connected: (.green, L("Connected"))
        case .connecting: (.orange, L("Connecting…"))
        case .reconnecting: (.orange, L("Reconnecting…"))
        case .disconnected: (.secondary, L("Disconnected"))
        }
        return Label(label, systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .font(.caption)
            .fixedSize()
    }

    private func toggleConnection() {
        if session.isActive {
            session.disconnect()
            return
        }
        let requestContext = RequestContext(spec: document.spec, node: node, workspace: workspace, secrets: model.services.secrets)
        let builder = requestContext.builder(for: document.spec)
        if isWebSocket {
            session.connectWebSocket(document.spec, builder: builder)
        } else {
            session.connectSSE(document.spec, builder: builder)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .message:
            MessageComposer(document: document, session: session, format: $format) { text in
                RequestContext(spec: document.spec, node: node, workspace: workspace, secrets: model.services.secrets).resolver.resolve(text)
            }
        case .params:
            ScrollView {
                KeyValueTable(rows: Binding(get: { document.spec.params }, set: document.setParams))
            }
        case .headers:
            ScrollView { KeyValueTable(rows: $document.spec.headers) }
        case .auth:
            ScrollView {
                AuthEditor(auth: $document.spec.auth, allowsInherit: true, resolver: {
                    RequestContext(spec: document.spec, node: node, workspace: workspace, secrets: model.services.secrets).resolver
                })
            }
        case .settings:
            Form {
                if isWebSocket {
                    TextField(L("Subprotocols (comma separated)"), text: Binding(
                        get: { document.spec.realtime.subprotocols.joined(separator: ", ") },
                        set: { document.spec.realtime.subprotocols = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    TextField(L("Ping interval (seconds, 0 = off)"), value: $document.spec.realtime.pingInterval, format: .number)
                } else {
                    Toggle(L("Reconnect automatically"), isOn: $document.spec.realtime.autoReconnect)
                }
                Toggle(L("Verify SSL certificates"), isOn: $document.spec.settings.verifySSL)
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
}

private struct MessageComposer: View {
    @Bindable var document: RequestDocument
    let session: RealtimeSessionModel
    @Binding var format: SavedMessage.Format
    /// Resolves `{{variables}}` in the message before sending.
    let resolve: (String) -> String
    @State private var savingName = ""
    @State private var isNaming = false

    var body: some View {
        ResizableHSplit(id: "ws-composer", initialFraction: 0.7, minLeft: 240, minRight: 140) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("", selection: $format) {
                        Text(L("Text")).tag(SavedMessage.Format.text)
                        Text("JSON").tag(SavedMessage.Format.json)
                        Text(L("Binary (Base64)")).tag(SavedMessage.Format.binaryBase64)
                    }
                    .labelsHidden()
                    .fixedSize()
                    if format == .json {
                        Button(L("Beautify")) {
                            if let pretty = JSONFormatter.prettyPrinted(document.spec.draftMessage) { document.spec.draftMessage = pretty }
                        }
                        .buttonStyle(.link)
                    }
                    Spacer()
                    Button(L("Save Message")) { isNaming = true }
                        .disabled(document.spec.draftMessage.isEmpty)
                    Button(L("Send")) {
                        session.send(resolve(document.spec.draftMessage), format: format)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!session.isConnected || document.spec.draftMessage.isEmpty)
                    .accessibilityIdentifier("send-message")
                }
                CodeEditor(text: $document.spec.draftMessage, language: format == .json ? .json : .plain, identifier: "message-editor")
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
            .frame(minWidth: 280)
        } right: {            List {
                Section(L("Saved Messages")) {
                    ForEach(document.spec.messages) { message in
                        Button {
                            document.spec.draftMessage = message.body
                            format = message.format
                        } label: {
                            VStack(alignment: .leading) {
                                Text(message.name)
                                Text(message.body).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L("Delete"), role: .destructive) { document.spec.messages.removeAll { $0.id == message.id } }
                        }
                    }
                }
            }
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)
        }
        .alert(L("Save Message"), isPresented: $isNaming) {
            TextField(L("Name"), text: $savingName)
            Button(L("Save")) {
                document.spec.messages.append(SavedMessage(name: savingName.isEmpty ? L("Message") : savingName, body: document.spec.draftMessage, format: format))
                savingName = ""
            }
            Button(L("Cancel"), role: .cancel) {}
        }
    }
}

struct RealtimeLogView: View {
    let session: RealtimeSessionModel
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var selection: RealtimeSessionModel.LogItem.ID?

    enum Filter: Hashable { case all, sent, received }

    private var items: [RealtimeSessionModel.LogItem] {
        session.log.filter { item in
            switch filter {
            case .all: true
            case .sent: item.kind == .sent
            case .received: item.kind == .received
            }
        }
        .filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Messages")).font(.headline)
                Picker("", selection: $filter) {
                    Text(L("All")).tag(Filter.all)
                    Text(L("Sent")).tag(Filter.sent)
                    Text(L("Received")).tag(Filter.received)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField(L("Search"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Spacer()
                Button(L("Clear"), systemImage: "trash") { session.clear() }
                    .disabled(session.log.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider()
            ResizableHSplit(id: "realtime-log", initialFraction: 0.6, minLeft: 260, minRight: 200, showsRight: session.log.contains(where: { $0.id == selection })) {
                ScrollViewReader { proxy in
                    List(items, selection: $selection) { item in
                        LogRow(item: item).tag(item.id).id(item.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: session.log.count) {
                        if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .frame(minWidth: 300)
            } right: {                if let item = session.log.first(where: { $0.id == selection }) {
                    CodeEditor(text: .constant(JSONFormatter.prettyPrinted(item.text) ?? item.text),
                               language: JSONFormatter.prettyPrinted(item.text) == nil ? .plain : .json, isEditable: false)
                        .frame(minWidth: 240)
                }
            }
        }
    }
}

private struct LogRow: View {
    let item: RealtimeSessionModel.LogItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 14)
            if let title = item.title {
                Text(title).font(.caption.bold()).foregroundStyle(.purple)
            }
            Text(item.text)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .foregroundStyle(item.kind == .error ? .red : (item.kind == .info ? .secondary : .primary))
            Spacer()
            if item.kind == .sent || item.kind == .received {
                Text(item.size.formatted(.byteCount(style: .memory))).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.date.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .accessibilityIdentifier("realtime-log-\(item.kind)")
    }

    private var icon: String {
        switch item.kind {
        case .sent: "arrow.up"
        case .received: "arrow.down"
        case .info: "info.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch item.kind {
        case .sent: .orange
        case .received: .green
        case .info: .secondary
        case .error: .red
        }
    }
}
