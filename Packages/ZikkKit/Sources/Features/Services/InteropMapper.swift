import Foundation
import SwiftData
import APICore
import APIStore
import Interop

/// Converts between SwiftData models and the storage-independent interop tree.
@MainActor
enum InteropMapper {
    // MARK: Import

    @discardableResult
    static func insert(_ source: InteropCollection, into workspace: Workspace, context: ModelContext, secrets: any SecretStore) -> APICollection {
        let collection = APICollection(name: source.name, descriptionMD: source.description, sortIndex: (workspace.collections.map(\.sortIndex).max() ?? -1) + 1)
        collection.auth = source.auth
        collection.preRequestScript = source.preRequestScript
        collection.testScript = source.testScript
        collection.variables = SecretVariables.save(source.variables, previous: [], scope: collection.id, store: secrets)
        collection.workspace = workspace
        context.insert(collection)
        insert(source.items, collection: collection, parent: nil, context: context)
        try? context.save()
        return collection
    }

    private static func insert(_ items: [InteropItem], collection: APICollection, parent: CollectionNode?, context: ModelContext) {
        for (index, item) in items.enumerated() {
            switch item {
            case .folder(let folder):
                let node = CollectionNode(kind: .folder, name: folder.name, sortIndex: index)
                node.descriptionMD = folder.description
                node.auth = folder.auth
                node.preRequestScript = folder.preRequestScript
                node.testScript = folder.testScript
                node.collection = collection
                node.parent = parent
                context.insert(node)
                insert(folder.items, collection: collection, parent: node, context: context)
            case .request(let request):
                let node = CollectionNode(kind: .request, name: request.name, request: request.spec, sortIndex: index)
                node.descriptionMD = request.description
                node.collection = collection
                node.parent = parent
                context.insert(node)
                for example in request.examples {
                    let saved = SavedExample(name: example.name, request: example.request, response: example.response)
                    saved.node = node
                    context.insert(saved)
                }
            }
        }
    }

    @discardableResult
    static func insert(_ source: InteropEnvironment, into workspace: Workspace, context: ModelContext, secrets: any SecretStore) -> APIEnvironment {
        let environment = APIEnvironment(name: source.name, sortIndex: workspace.environments.count)
        environment.variables = SecretVariables.save(source.variables, previous: [], scope: environment.id, store: secrets)
        environment.workspace = workspace
        context.insert(environment)
        try? context.save()
        return environment
    }

    // MARK: Export

    static func export(_ collection: APICollection, secrets: any SecretStore, includeSecrets: Bool = false) -> InteropCollection {
        let variables = includeSecrets ? SecretVariables.load(collection.variables, scope: collection.id, store: secrets) : collection.variables
        return InteropCollection(name: collection.name, description: collection.descriptionMD, auth: collection.auth,
                                 preRequestScript: collection.preRequestScript, testScript: collection.testScript,
                                 variables: variables, items: collection.rootNodes.map(export))
    }

    static func export(_ node: CollectionNode) -> InteropItem {
        if node.isFolder {
            return .folder(InteropFolder(name: node.name, description: node.descriptionMD, auth: node.auth, preRequestScript: node.preRequestScript,
                                         testScript: node.testScript, items: (node.sortedChildren ?? []).map(export)))
        }
        let examples = node.examples.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
            .map { InteropExample(name: $0.name, request: $0.request, response: $0.response) }
        return .request(InteropRequest(name: node.name, description: node.descriptionMD, spec: node.request, examples: examples))
    }

    static func export(_ environment: APIEnvironment, secrets: any SecretStore, includeSecrets: Bool = false) -> InteropEnvironment {
        let variables = includeSecrets ? SecretVariables.load(environment.variables, scope: environment.id, store: secrets) : environment.variables
        return InteropEnvironment(name: environment.name, variables: variables)
    }
}
