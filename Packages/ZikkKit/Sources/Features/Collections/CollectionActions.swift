import Foundation
import SwiftData
import APICore
import APIStore

/// Create/rename/duplicate/delete operations on collections and their nodes.
@MainActor
struct CollectionActions {
    let context: ModelContext
    let model: AppModel

    @discardableResult
    func addCollection(to workspace: Workspace, name: String = L("New Collection")) -> APICollection {
        let index = (workspace.collections.map(\.sortIndex).max() ?? -1) + 1
        let collection = APICollection(name: name, sortIndex: index)
        collection.workspace = workspace
        context.insert(collection)
        save()
        return collection
    }

    @discardableResult
    func addNode(_ kind: NodeKind, to collection: APICollection, parent: CollectionNode?, requestKind: RequestKind = .http) -> CollectionNode {
        let siblings = parent?.sortedChildren ?? collection.rootNodes
        let name = kind == .folder ? L("New Folder") : (requestKind == .http ? L("New Request") : requestKind.defaultName)
        let node = CollectionNode(kind: kind, name: name, request: kind == .request ? RequestSpec.template(for: requestKind) : nil, sortIndex: (siblings.map(\.sortIndex).max() ?? -1) + 1)
        node.collection = collection
        node.parent = parent
        context.insert(node)
        save()
        if kind == .request { model.openRequest(node) }
        return node
    }

    func rename(_ node: CollectionNode, to name: String) {
        node.name = name
        node.touch()
        save()
        model.nodeRenamed(node)
    }

    func duplicate(_ node: CollectionNode) {
        guard let collection = node.collection else { return }
        let copy = deepCopy(node, into: collection, parent: node.parent)
        copy.name = node.name + " " + L("Copy")
        copy.sortIndex = node.sortIndex + 1
        for sibling in (node.parent?.sortedChildren ?? collection.rootNodes) where sibling.sortIndex > node.sortIndex && sibling !== copy {
            sibling.sortIndex += 1
        }
        save()
    }

    func duplicate(_ collection: APICollection) {
        guard let workspace = collection.workspace else { return }
        let copy = addCollection(to: workspace, name: collection.name + " " + L("Copy"))
        copy.descriptionMD = collection.descriptionMD
        copy.authData = collection.authData
        copy.preRequestScript = collection.preRequestScript
        copy.testScript = collection.testScript
        copy.variablesData = collection.variablesData
        for node in collection.rootNodes { _ = deepCopy(node, into: copy, parent: nil) }
        save()
    }

    func delete(_ node: CollectionNode) {
        let ids = Set(allDescendants(of: node).map(\.id) + [node.id])
        model.closeTabs { tab in tab.nodeID.map(ids.contains) ?? false }
        context.delete(node)
        save()
    }

    func delete(_ collection: APICollection) {
        let ids = Set(collection.nodes.map(\.id))
        model.closeTabs { tab in
            if case .collection(let id) = tab.content, id == collection.id { return true }
            return tab.nodeID.map(ids.contains) ?? false
        }
        context.delete(collection)
        save()
    }

    // MARK: Moving

    /// Moves `node` into `target` if it is a folder, otherwise just before `target` among its siblings.
    func move(_ node: CollectionNode, onto target: CollectionNode) {
        guard node !== target, !isAncestor(node, of: target), let collection = target.collection else { return }
        if target.isFolder {
            reparent(node, collection: collection, parent: target, index: target.sortedChildren?.count ?? 0)
        } else {
            let siblings = siblings(in: collection, parent: target.parent).filter { $0 !== node }
            reparent(node, collection: collection, parent: target.parent, index: siblings.firstIndex { $0 === target } ?? siblings.count)
        }
    }

    /// Moves `node` to the end of `collection`'s top level.
    func move(_ node: CollectionNode, toRootOf collection: APICollection) {
        reparent(node, collection: collection, parent: nil, index: collection.rootNodes.filter { $0 !== node }.count)
    }

    private func reparent(_ node: CollectionNode, collection: APICollection, parent: CollectionNode?, index: Int) {
        let oldCollection = node.collection
        let oldParent = node.parent
        node.parent = parent
        if node.collection !== collection {
            for moved in [node] + allDescendants(of: node) { moved.collection = collection }
        }
        var ordered = siblings(in: collection, parent: parent).filter { $0 !== node }
        ordered.insert(node, at: min(index, ordered.count))
        for (position, sibling) in ordered.enumerated() { sibling.sortIndex = position }
        if let oldCollection, oldCollection !== collection || oldParent !== parent {
            for (position, sibling) in siblings(in: oldCollection, parent: oldParent).filter({ $0 !== node }).enumerated() { sibling.sortIndex = position }
        }
        node.touch()
        save()
    }

    private func siblings(in collection: APICollection, parent: CollectionNode?) -> [CollectionNode] {
        parent?.sortedChildren ?? collection.rootNodes
    }

    private func isAncestor(_ node: CollectionNode, of other: CollectionNode) -> Bool {
        other.ancestors.contains { $0 === node }
    }

    private func deepCopy(_ node: CollectionNode, into collection: APICollection, parent: CollectionNode?) -> CollectionNode {
        let copy = CollectionNode(kind: node.kind, name: node.name, sortIndex: node.sortIndex)
        copy.requestData = node.requestData
        copy.descriptionMD = node.descriptionMD
        copy.authData = node.authData
        copy.preRequestScript = node.preRequestScript
        copy.testScript = node.testScript
        copy.variablesData = node.variablesData
        copy.collection = collection
        copy.parent = parent
        context.insert(copy)
        for example in node.examples {
            let exampleCopy = SavedExample(name: example.name, request: example.request, response: example.response)
            exampleCopy.node = copy
            context.insert(exampleCopy)
        }
        for child in node.sortedChildren ?? [] { _ = deepCopy(child, into: collection, parent: copy) }
        return copy
    }

    private func allDescendants(of node: CollectionNode) -> [CollectionNode] {
        node.children.flatMap { [$0] + allDescendants(of: $0) }
    }

    private func save() { try? context.save() }
}
