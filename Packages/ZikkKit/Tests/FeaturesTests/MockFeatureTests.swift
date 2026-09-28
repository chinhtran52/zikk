import Testing
import Foundation
import SwiftData
import APICore
import APIStore
@testable import Features

@MainActor
@Suite struct MockFeatureTests {
    static var containers: [ModelContainer] = []

    @Test func servesSavedExamplesAndReflectsEdits() async throws {
        let container = try StoreFactory.makeContainer(inMemory: true)
        Self.containers.append(container)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        let model = AppModel(services: AppServices(secrets: InMemorySecretStore()))
        model.attach(workspace: workspace, context: context)
        let actions = CollectionActions(context: context, model: model)
        let collection = actions.addCollection(to: workspace)
        let node = actions.addNode(.request, to: collection, parent: nil)
        node.request = RequestSpec(url: "{{baseUrl}}/users/:id")
        let example = SavedExample(name: "User", request: node.request,
                                   response: ResponseSnapshot(statusCode: 200, headers: [KeyValue(key: "Content-Type", value: "application/json")], body: Data(#"{"id":"{{id}}"}"#.utf8)))
        example.node = node
        context.insert(example)
        let environment = APIEnvironment(name: "mock")
        environment.workspace = workspace

        let mock = MockActions.create(in: workspace, context: context, model: model, collection: collection)
        mock.port = 0
        #expect(mock.collectionID == collection.id)
        let registry = model.services.mocks
        await registry.start(mock, workspace: workspace, context: context)
        let url = try #require(registry.url(of: mock))
        defer { registry.stop(mock.id) }

        let (data, response) = try await URLSession.shared.data(from: URL(string: url + "/users/42")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"id":"42"}"#)

        // Edits to examples are picked up without restarting.
        var updated = example.response
        updated.statusCode = 202
        example.response = updated
        let (_, second) = try await URLSession.shared.data(from: URL(string: url + "/users/7")!)
        #expect((second as? HTTPURLResponse)?.statusCode == 202)
        #expect(registry.logs[mock.id]?.map(\.statusCode) == [200, 202])

        let (_, missing) = try await URLSession.shared.data(from: URL(string: url + "/nothing")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }
}
