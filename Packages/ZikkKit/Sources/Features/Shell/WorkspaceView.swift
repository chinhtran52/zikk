import SwiftUI
import SwiftData
import APICore
import APIStore
import DesignSystem

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let workspace: Workspace
    @AppStorage("showsCodeSnippet") private var showsCodeSnippet = false

    private var snippetDocument: RequestDocument? { model.snippetDocument }

    private var tabsAndContent: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            TabStrip(items: model.tabs.map(\.stripItem), selection: $model.selectedTabID, onClose: model.close, onNew: model.newRequestTab) {
                ForEach(RequestKind.allCases, id: \.self) { kind in
                    Button(kind.menuTitle) { model.newRequestTab(kind: kind) }
                }
            }
            Divider()
            if let tab = model.selectedTab {
                TabContentView(tab: tab, workspace: workspace)
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(L("No Open Tabs"), systemImage: "rectangle.stack")
                } description: {
                    Text(L("Open a request from the sidebar or create a new one."))
                } actions: {
                    Button(L("New Request"), action: model.newRequestTab)
                }
            }
        }
    }

    var body: some View {
        // The code panel is a plain SwiftUI split rather than `.inspector`: the inspector's extra AppKit split
        // column made the detail's safe-area insets oscillate while the sidebar was resized, which AppKit
        // aborted as an endless constraint-update loop.
        ResizableHSplit(id: "code-panel", initialFraction: 0.7, minLeft: 380, minRight: 240, showsRight: showsCodeSnippet && snippetDocument != nil) {
            tabsAndContent
        } right: {
            if let document = snippetDocument {
                HStack(spacing: 0) {
                    CodeSnippetPanel(spec: document.spec) {
                        RequestContext(spec: document.spec, node: document.nodeID.flatMap { CollectionQueries.node($0, in: context) },
                                       workspace: workspace, secrets: model.services.secrets)
                    }
                }
                .background(.background.secondary)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EnvironmentPicker(workspace: workspace)
            }
            ToolbarItem(placement: .primaryAction) {
                ConsoleButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsCodeSnippet.toggle()
                } label: {
                    Label(L("Code"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help(L("Show code snippet"))
                .disabled(snippetDocument == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isShowingCookies = true
                } label: {
                    Label(L("Cookies"), systemImage: "birthday.cake")
                }
                .help(L("Manage cookies"))
            }
        }
    }
}

extension WorkspaceTab {
    var stripItem: TabStripItem {
        guard let request else {
            return TabStripItem(id: id, title: title, leading: nil, isDirty: false)
        }
        let spec = request.spec
        return TabStripItem(id: id, title: title, leading: spec.kind.badge(method: spec.method), leadingColor: spec.kind == .http ? spec.method.tint : .pink, isDirty: isDirty)
    }
}

struct TabContentView: View {
    @Environment(\.modelContext) private var context
    let tab: WorkspaceTab
    let workspace: Workspace

    var body: some View {
        if let document = tab.request {
            switch document.spec.kind {
            case .webSocket, .sse:
                RealtimeEditorView(document: document, workspace: workspace)
            case .grpc:
                GRPCEditorView(document: document, workspace: workspace)
            case .http, .graphQL:
                RequestEditorView(document: document, workspace: workspace)
            }
        } else if let runner = tab.runner {
            RunnerView(runner: runner, workspace: workspace)
        } else {
            switch tab.content {
            case .globals:
                VariablesEditorView(title: L("Globals"), scope: workspace.id, load: { workspace.globals }, store: { workspace.globals = $0 })
            case .environment(let id):
                if let environment = CollectionQueries.environment(id, in: context) {
                    VariablesEditorView(title: environment.name, scope: environment.id, load: { environment.variables }, store: { environment.variables = $0 })
                } else {
                    missing
                }
            case .collection(let id):
                if let collection = CollectionQueries.collection(id, in: context) {
                    CollectionSettingsView(collection: collection, workspace: workspace)
                } else {
                    missing
                }
            case .folder(let id):
                if let folder = CollectionQueries.node(id, in: context) {
                    FolderSettingsView(folder: folder, workspace: workspace)
                } else {
                    missing
                }
            case .mock(let id):
                if let mock = workspace.mocks.first(where: { $0.id == id }) {
                    MockServerView(mock: mock, workspace: workspace)
                } else {
                    missing
                }
            case .docs(let id):
                if let collection = CollectionQueries.collection(id, in: context) {
                    DocumentationView(collection: collection, workspace: workspace)
                } else {
                    missing
                }
            case .spec(let id):
                if let spec = workspace.specs.first(where: { $0.id == id }) {
                    SpecEditorView(spec: spec, workspace: workspace)
                } else {
                    missing
                }
            case .dataset(let id):
                if let dataset = workspace.datasets.first(where: { $0.id == id }) {
                    DatasetEditorView(dataset: dataset)
                } else {
                    missing
                }
            case .example(let id):
                if let example = CollectionQueries.example(id, in: context) {
                    ExampleEditorView(example: example)
                } else {
                    missing
                }
            default:
                ContentUnavailableView(tab.title, systemImage: "hammer", description: Text(L("Coming soon")))
            }
        }
    }

    private var missing: some View {
        ContentUnavailableView(L("Not Found"), systemImage: "questionmark.folder", description: Text(L("This item no longer exists.")))
    }
}

private struct ConsoleButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "console")
        } label: {
            Label(L("Console"), systemImage: "terminal")
        }
        .help(L("Show Console (⌥⌘C)"))
    }
}
