import SwiftUI
import SwiftData
import APICore
import APIStore
import DesignSystem

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker(L("Section"), selection: $model.section) {
                ForEach(SidebarSection.allCases) { section in
                    Image(systemName: section.systemImage)
                        .help(section.title)
                        .accessibilityLabel(section.title)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            sectionContent
                .frame(maxHeight: .infinity)
        }
        .navigationTitle(model.section.title)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.section {
        case .collections:
            CollectionsSidebar(workspace: workspace)
        case .environments:
            EnvironmentsSidebar(workspace: workspace)
        case .history:
            HistorySidebar(workspace: workspace)
        case .datasets:
            DatasetsSidebar(workspace: workspace)
        case .specs:
            SpecsSidebar(workspace: workspace)
        case .mocks:
            MocksSidebar(workspace: workspace)
        }
    }
}

struct CollectionsSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let workspace: Workspace
    @State private var renamingCollection: APICollection?
    @State private var renamingNode: CollectionNode?
    @State private var search: String
    @State private var expansion = TreeExpansion()

    init(workspace: Workspace, search: String = "") {
        self.workspace = workspace
        _search = State(initialValue: search)
    }

    private var actions: CollectionActions { CollectionActions(context: context, model: model) }

    private var collections: [APICollection] {
        workspace.collections.filter { $0.deletedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    var body: some View {
        let searchResult = CollectionSearch(query: search, collections: collections)
        List {
            ForEach(collections.filter(searchResult.isVisible)) { collection in
                DisclosureGroup(isExpanded: expansionBinding(collection.id, searchResult)) {
                    NodeTreeRows(nodes: collection.rootNodes.filter(searchResult.isVisible), search: searchResult,
                                 isExpanded: { expansionBinding($0, searchResult) }) { node in
                        NodeRow(node: node, highlight: searchResult.isActive ? search : "")
                            .contextMenu { nodeMenu(node, collection: collection) }
                            .draggable(node.id.uuidString)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let dragged = draggedNode(ids) else { return false }
                                actions.move(dragged, onto: node)
                                return true
                            }
                    }
                } label: {
                    Label {
                        HighlightedText(collection.name, highlighting: searchResult.isActive ? search : "")
                    } icon: {
                        Image(systemName: "shippingbox")
                    }
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { model.open(.collection(collection.id), title: collection.name) }
                    .contextMenu { collectionMenu(collection) }
                    .dropDestination(for: String.self) { ids, _ in
                        guard let dragged = draggedNode(ids) else { return false }
                        actions.move(dragged, toRootOf: collection)
                        return true
                    }
                }
            }
        }
        .onChange(of: search) { expansion.searchChanged() }
        .overlay {
            if searchResult.isActive, searchResult.visibleCollections.isEmpty, !collections.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: L("Search requests"))
        .overlay {
            if collections.isEmpty {
                ContentUnavailableView {
                    Label(L("No Collections"), systemImage: "shippingbox")
                } description: {
                    Text(L("Create a collection to group and save your requests."))
                } actions: {
                    Button(L("New Collection")) { actions.addCollection(to: workspace) }
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            SidebarBottomBar(title: L("New Collection")) { actions.addCollection(to: workspace) } accessories: {
                SidebarIconButton(systemImage: "square.and.arrow.down", help: L("Import (⌘O)")) { model.isShowingImport = true }
            }
        }
        .renameAlert(item: $renamingCollection, name: \.name) { collection, name in
            collection.name = name
            collection.touch()
            try? context.save()
        }
        .renameAlert(item: $renamingNode, name: \.name) { node, name in
            actions.rename(node, to: name)
        }
    }

    private func draggedNode(_ ids: [String]) -> CollectionNode? {
        ids.first.flatMap(UUID.init(uuidString:)).flatMap { CollectionQueries.node($0, in: context) }
    }

    private func expansionBinding(_ id: UUID, _ search: CollectionSearch) -> Binding<Bool> {
        Binding {
            expansion.isExpanded(id, search: search)
        } set: { expanded in
            expansion.set(id, expanded: expanded, search: search)
        }
    }

    private func addRequestMenu(collection: APICollection, parent: CollectionNode?) -> some View {
        Menu(L("Add Request")) {
            ForEach(RequestKind.allCases, id: \.self) { kind in
                Button(kind.menuTitle) { actions.addNode(.request, to: collection, parent: parent, requestKind: kind) }
            }
        }
    }

    @ViewBuilder
    private func collectionMenu(_ collection: APICollection) -> some View {
        Button(L("Open")) { model.open(.collection(collection.id), title: collection.name) }
        Button(L("Run Collection…")) { model.openRunner(collection: collection) }
        Button(L("View Documentation")) { model.open(.docs(collection.id), title: collection.name + " – " + L("Docs")) }
        Button(L("Mock Collection…")) { MockActions.create(in: workspace, context: context, model: model, collection: collection) }
        addRequestMenu(collection: collection, parent: nil)
        Button(L("Add Folder")) { actions.addNode(.folder, to: collection, parent: nil) }
        Divider()
        Button(L("Rename…")) { renamingCollection = collection }
        Button(L("Duplicate")) { actions.duplicate(collection) }
        Button(L("Export…")) { model.export(collection) }
        Divider()
        Button(L("Delete"), role: .destructive) { actions.delete(collection) }
    }

    @ViewBuilder
    private func nodeMenu(_ node: CollectionNode, collection: APICollection) -> some View {
        if node.isFolder {
            Button(L("Run Folder…")) { model.openRunner(collection: collection, folder: node) }
            addRequestMenu(collection: collection, parent: node)
            Button(L("Add Folder")) { actions.addNode(.folder, to: collection, parent: node) }
            Divider()
        }
        Button(L("Rename…")) { renamingNode = node }
        Button(L("Duplicate")) { actions.duplicate(node) }
        Divider()
        Button(L("Delete"), role: .destructive) { actions.delete(node) }
    }
}

/// Recursive rows of the collections tree; folders use `DisclosureGroup` so search can expand them.
struct NodeTreeRows<Row: View>: View {
    let nodes: [CollectionNode]
    let search: CollectionSearch
    let isExpanded: (UUID) -> Binding<Bool>
    @ViewBuilder let row: (CollectionNode) -> Row

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                DisclosureGroup(isExpanded: isExpanded(node.id)) {
                    NodeTreeRows(nodes: (node.sortedChildren ?? []).filter(search.isVisible), search: search, isExpanded: isExpanded, row: row)
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
    }
}

struct NodeRow: View {
    @Environment(AppModel.self) private var model
    let node: CollectionNode
    /// Search text to emphasize in the name.
    var highlight = ""

    var body: some View {
        HStack(spacing: 6) {
            if node.isFolder {
                Image(systemName: "folder")
            } else if !node.examples.isEmpty {
                MethodBadge(node.request.method, kind: node.request.kind)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(.secondary).frame(width: 4, height: 4).offset(x: 3)
                    }
            } else {
                let request = node.request
                MethodBadge(request.method, kind: request.kind)
            }
            HighlightedText(node.name, highlighting: highlight)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture {
            if node.isFolder {
                model.open(.folder(node.id), title: node.name)
            } else {
                model.openRequest(node)
            }
        }
    }
}
