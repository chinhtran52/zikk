import SwiftUI
import SwiftData
import APIStore

/// Chooses a collection (and optional folder) for saving a draft request.
struct SaveRequestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let document: RequestDocument
    let workspace: Workspace
    @State private var name = ""
    @State private var collectionID: UUID?
    @State private var folderID: UUID?
    @State private var newCollectionName = ""

    private var collections: [APICollection] {
        workspace.collections.filter { $0.deletedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    private var folders: [CollectionNode] {
        guard let collection = collections.first(where: { $0.id == collectionID }) else { return [] }
        return collection.nodes.filter { $0.isFolder && $0.deletedAt == nil }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField(L("Request name"), text: $name)
                Picker(L("Collection"), selection: $collectionID) {
                    Text(L("New collection…")).tag(UUID?.none)
                    ForEach(collections) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                if collectionID == nil {
                    TextField(L("Collection name"), text: $newCollectionName)
                } else {
                    Picker(L("Folder"), selection: $folderID) {
                        Text(L("Collection root")).tag(UUID?.none)
                        ForEach(folders) { folder in
                            Text((folder.ancestors.map(\.name) + [folder.name]).joined(separator: " / ")).tag(UUID?.some(folder.id))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || (collectionID == nil && newCollectionName.isEmpty))
            }
            .padding()
        }
        .frame(width: 440)
        .onAppear {
            name = document.name
            collectionID = collections.first?.id
            newCollectionName = L("New Collection")
        }
        .onChange(of: collectionID) { folderID = nil }
    }

    private func save() {
        let collection: APICollection
        if let existing = collections.first(where: { $0.id == collectionID }) {
            collection = existing
        } else {
            collection = APICollection(name: newCollectionName, sortIndex: collections.count)
            collection.workspace = workspace
            context.insert(collection)
        }
        let parent = folders.first { $0.id == folderID }
        let siblings = parent?.sortedChildren ?? collection.rootNodes
        let node = CollectionNode(kind: .request, name: name, request: document.spec, sortIndex: (siblings.map(\.sortIndex).max() ?? -1) + 1)
        node.collection = collection
        node.parent = parent
        context.insert(node)
        try? context.save()
        document.name = name
        document.didSaveAsNode(node)
        if let tab = model.tabs.first(where: { $0.request === document }) { tab.content = .request(nodeID: node.id) }
        dismiss()
    }
}
