import SwiftUI
import SwiftData
import AppKit
import APIStore
import DesignSystem
import MockServer
import APICore

struct MocksSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let workspace: Workspace
    @State private var renaming: MockDefinition?

    private var mocks: [MockDefinition] {
        workspace.mocks.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            ForEach(mocks) { mock in
                Button {
                    model.open(.mock(mock.id), title: mock.name)
                } label: {
                    HStack {
                        Circle().fill(model.services.mocks.isRunning(mock.id) ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                        Label(mock.name, systemImage: "server.rack")
                        Spacer()
                        Text(verbatim: ":\(model.services.mocks.port(of: mock.id).map(String.init) ?? String(mock.port))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if model.services.mocks.isRunning(mock.id) {
                        Button(L("Stop")) { model.services.mocks.stop(mock.id) }
                    } else {
                        Button(L("Start")) { Task { await model.services.mocks.start(mock, workspace: workspace, context: context) } }
                    }
                    Button(L("Rename…")) { renaming = mock }
                    Divider()
                    Button(L("Delete"), role: .destructive) {
                        model.services.mocks.stop(mock.id)
                        model.closeTabs { $0.content == .mock(mock.id) }
                        context.delete(mock)
                        try? context.save()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if mocks.isEmpty {
                ContentUnavailableView(L("No Mock Servers"), systemImage: "server.rack",
                                       description: Text(L("Mock servers answer requests with the saved examples of a collection or the examples of an API spec.")))
            }
        }
        .safeAreaBar(edge: .bottom) {
            SidebarBottomBar(title: L("New Mock Server")) { MockActions.create(in: workspace, context: context, model: model) }
        }
        .renameAlert(item: $renaming, name: \.name) { mock, name in
            mock.name = name
            try? context.save()
        }
    }
}

@MainActor
enum MockActions {
    @discardableResult
    static func create(in workspace: Workspace, context: ModelContext, model: AppModel, collection: APICollection? = nil) -> MockDefinition {
        let usedPorts = Set(workspace.mocks.map(\.port))
        let port = (8787...8999).first { !usedPorts.contains($0) } ?? 8787
        let mock = MockDefinition(name: collection.map { $0.name + " " + L("Mock") } ?? L("New Mock Server"), port: port,
                                  collectionID: collection?.id ?? workspace.collections.first?.id)
        mock.workspace = workspace
        context.insert(mock)
        try? context.save()
        model.section = .mocks
        model.open(.mock(mock.id), title: mock.name)
        return mock
    }
}

struct MockServerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var mock: MockDefinition
    let workspace: Workspace
    @State private var selectedLog: MockLogEntry.ID?

    private var registry: MockRegistry { model.services.mocks }
    private var isRunning: Bool { registry.isRunning(mock.id) }

    private enum Source: Hashable { case collection(UUID), spec(UUID), none }

    private var source: Binding<Source> {
        Binding {
            if let id = mock.specID { return .spec(id) }
            if let id = mock.collectionID { return .collection(id) }
            return .none
        } set: { value in
            switch value {
            case .collection(let id): mock.collectionID = id; mock.specID = nil
            case .spec(let id): mock.specID = id; mock.collectionID = nil
            case .none: mock.collectionID = nil; mock.specID = nil
            }
            try? context.save()
        }
    }

    var body: some View {
        ResizableHSplit(id: "mock", initialFraction: 0.36, minLeft: 280, minRight: 300) {
            configuration.frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
        } right: {            logView.frame(minWidth: 360)
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField(L("Name"), text: $mock.name).textFieldStyle(.plain).font(.title3.bold())
                Spacer()
                Circle().fill(isRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 10, height: 10)
            }
            .padding(12)
            Form {
                Picker(L("Source"), selection: source) {
                    Text(L("None")).tag(Source.none)
                    Section(L("Collections")) {
                        ForEach(workspace.collections.filter { $0.deletedAt == nil }) { Text($0.name).tag(Source.collection($0.id)) }
                    }
                    Section(L("APIs")) {
                        ForEach(workspace.specs.filter { $0.deletedAt == nil }) { Text($0.name).tag(Source.spec($0.id)) }
                    }
                }
                TextField(L("Port"), value: $mock.port, format: .number.grouping(.never))
                Picker(L("Environment"), selection: $mock.environmentID) {
                    Text(L("No Environment")).tag(UUID?.none)
                    ForEach(workspace.environments.filter { $0.deletedAt == nil }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                TextField(L("Delay (ms)"), value: $mock.defaultDelayMilliseconds, format: .number)
                Toggle(L("Match request headers"), isOn: $mock.matchHeaders)
                Toggle(L("Match request body"), isOn: $mock.matchBody)
                Section {
                    let routes = MockRegistry.routes(for: mock, workspace: workspace)
                    LabeledContent(L("Endpoints with examples"), value: "\(routes.count)")
                    if routes.isEmpty {
                        Text(L("Save example responses on requests (Save as Example) so the mock can return them."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isRunning)
            .onChange(of: mock.port) { try? context.save() }
            if let url = registry.url(of: mock) {
                HStack {
                    Text(url).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(L("Copy URL"))
                    Button(L("Use in Environment")) { useInEnvironment(url) }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 12)
            }
            if let error = registry.errors[mock.id] {
                Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal, 12)
            }
            HStack {
                if isRunning {
                    Button(L("Stop"), role: .destructive) { registry.stop(mock.id) }.controlSize(.large)
                } else {
                    Button(L("Start")) { Task { await registry.start(mock, workspace: workspace, context: context) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("mock-start")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(12)
        }
    }

    private var logView: some View {
        let entries = registry.logs[mock.id] ?? []
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Request Log")).font(.headline)
                Spacer()
                Button(L("Clear"), systemImage: "trash") { registry.clearLog(mock.id) }.disabled(entries.isEmpty)
            }
            .padding(10)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(L("No Requests Yet"), systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text(isRunning ? L("Send requests to the mock URL to see them here.") : L("Start the mock server to receive requests.")))
            } else {
                Table(entries.reversed(), selection: $selectedLog) {
                    TableColumn(L("Time")) { Text($0.date.formatted(date: .omitted, time: .standard)).monospacedDigit() }.width(80)
                    TableColumn(L("Method")) { Text($0.method).foregroundStyle(HTTPMethod(rawValue: $0.method).tint).bold() }.width(60)
                    TableColumn(L("Path")) { Text($0.path).font(.system(.body, design: .monospaced)) }
                    TableColumn(L("Status")) { Text(verbatim: "\($0.statusCode)").foregroundStyle(StatusBadge.color(for: $0.statusCode)) }.width(50)
                    TableColumn(L("Example")) { Text($0.exampleName ?? L("No match")).foregroundStyle($0.exampleName == nil ? .red : .primary) }
                }
            }
        }
    }

    private func useInEnvironment(_ url: String) {
        let environment: APIEnvironment
        if let id = mock.environmentID, let existing = workspace.environments.first(where: { $0.id == id }) {
            environment = existing
        } else {
            environment = APIEnvironment(name: mock.name, sortIndex: workspace.environments.count)
            environment.workspace = workspace
            context.insert(environment)
        }
        var variables = environment.variables
        if let index = variables.firstIndex(where: { $0.key == "baseUrl" }) { variables[index].value = url } else { variables.append(Variable(key: "baseUrl", value: url)) }
        environment.variables = variables
        workspace.activeEnvironmentID = environment.id
        try? context.save()
    }
}
