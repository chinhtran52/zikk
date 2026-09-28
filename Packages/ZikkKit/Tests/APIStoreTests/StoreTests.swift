import Testing
import Foundation
import SwiftData
import APICore
@testable import APIStore

@MainActor
@Suite struct StoreTests {
    @Test func collectionTreeRoundTrip() throws {
        let container = try StoreFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)

        let collection = APICollection(name: "Demo")
        collection.workspace = workspace
        let folder = CollectionNode(kind: .folder, name: "Users")
        folder.collection = collection
        let request = CollectionNode(kind: .request, name: "List", request: RequestSpec(method: .post, url: "{{base}}/users"), sortIndex: 1)
        request.collection = collection
        request.parent = folder
        context.insert(collection)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<APICollection>())
        #expect(fetched.count == 1)
        #expect(fetched[0].rootNodes.map(\.name) == ["Users"])
        #expect(fetched[0].rootNodes[0].sortedChildren?.first?.request.method == .post)
        #expect(request.ancestors.map(\.name) == ["Users"])

        // Default workspace is reused rather than duplicated.
        #expect(try StoreFactory.defaultWorkspace(in: context).id == workspace.id)
    }

    @Test func codableColumnsPersist() throws {
        let container = try StoreFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let environment = APIEnvironment(name: "Dev", variables: [Variable(key: "base", value: "http://localhost")])
        context.insert(environment)
        try context.save()
        var auth = AuthConfig(type: .bearer)
        auth.bearer.token = "abc"
        let collection = APICollection(name: "C")
        collection.auth = auth
        context.insert(collection)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<APIEnvironment>()).first?.variables.first?.value == "http://localhost")
        #expect(try context.fetch(FetchDescriptor<APICollection>()).first?.auth.bearer.token == "abc")
    }

    @Test func inMemorySecretStore() {
        let store = InMemorySecretStore()
        let key = InMemorySecretStore.key(scope: UUID(), variable: UUID())
        store.setValue("s3cret", for: key)
        #expect(store.value(for: key) == "s3cret")
        store.setValue(nil, for: key)
        #expect(store.value(for: key) == nil)
    }
}
