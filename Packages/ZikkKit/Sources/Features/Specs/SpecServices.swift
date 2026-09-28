import Foundation
import SwiftData
import APICore
import APIStore
import Execution
import Interop
import ScriptEngine
import SpecKit

@MainActor
enum SpecServices {
    static let template = """
    openapi: 3.0.3
    info:
      title: New API
      version: 1.0.0
    servers:
      - url: https://api.example.com/v1
    paths:
      /items:
        get:
          summary: List items
          operationId: listItems
          responses:
            '200':
              description: A list of items
              content:
                application/json:
                  schema:
                    type: array
                    items:
                      $ref: '#/components/schemas/Item'
    components:
      schemas:
        Item:
          type: object
          required: [id]
          properties:
            id:
              type: integer
            name:
              type: string
    """

    /// The spec linked to a collection, if any.
    static func linkedSpec(for collection: APICollection?, in workspace: Workspace) -> APISpec? {
        guard let collection else { return nil }
        return workspace.specs.first { $0.linkedCollectionID == collection.id && $0.deletedAt == nil }
    }

    /// Contract validator for requests in `collection`, based on its linked spec.
    static func responseValidator(for collection: APICollection?, in workspace: Workspace) -> RequestExecutor.ResponseValidator? {
        guard let spec = linkedSpec(for: collection, in: workspace), let document = try? SpecDocument(text: spec.content) else { return nil }
        let specName = spec.name
        return { request, url, response in
            let result = ContractValidator(document: document).validate(method: request.method.rawValue, url: url, response: response)
            guard let operation = result.operation else {
                return [TestResult(name: "Contract (\(specName))", passed: false, error: result.issues.first)]
            }
            if result.issues.isEmpty {
                return [TestResult(name: "Contract: response matches \(operation)", passed: true)]
            }
            return result.issues.map { TestResult(name: "Contract: \(operation)", passed: false, error: $0) }
        }
    }

    /// Creates a collection from the spec and links them.
    @discardableResult
    static func generateCollection(from spec: APISpec, workspace: Workspace, context: ModelContext, secrets: any SecretStore) throws -> APICollection {
        let document = try SpecDocument(text: spec.content)
        let collection = InteropMapper.insert(OpenAPIImporter.collection(from: document), into: workspace, context: context, secrets: secrets)
        spec.linkedCollectionID = collection.id
        spec.lastSyncHash = String(spec.content.hashValue)
        try? context.save()
        return collection
    }

    /// Applies selected sync changes to the linked collection.
    static func apply(_ changes: [SpecSync.Change], to collection: APICollection, basePath: String, context: ModelContext) {
        var nodesByKey: [String: CollectionNode] = [:]
        for node in collection.nodes where !node.isFolder && node.deletedAt == nil {
            let request = node.request
            nodesByKey[SpecSync.key(method: request.method, url: request.url, basePath: basePath)] = node
        }
        for change in changes {
            switch change.kind {
            case .added:
                guard let request = change.request else { continue }
                var parent: CollectionNode?
                if let folderName = change.folder {
                    parent = collection.rootNodes.first { $0.isFolder && $0.name == folderName }
                    if parent == nil {
                        let folder = CollectionNode(kind: .folder, name: folderName, sortIndex: collection.rootNodes.count)
                        folder.collection = collection
                        context.insert(folder)
                        parent = folder
                    }
                }
                let siblings = parent?.sortedChildren ?? collection.rootNodes
                let node = CollectionNode(kind: .request, name: request.name, request: request.spec, sortIndex: siblings.count)
                node.descriptionMD = request.description
                node.collection = collection
                node.parent = parent
                context.insert(node)
                for example in request.examples {
                    let saved = SavedExample(name: example.name, request: example.request, response: example.response)
                    saved.node = node
                    context.insert(saved)
                }
            case .removed:
                if let node = nodesByKey[change.key] { context.delete(node) }
            case .modified:
                guard let node = nodesByKey[change.key], let request = change.request else { continue }
                node.request = SpecSync.merge(node.request, with: request.spec, basePath: basePath)
                if !request.description.isEmpty { node.descriptionMD = request.description }
            }
        }
        collection.touch()
        try? context.save()
    }
}
