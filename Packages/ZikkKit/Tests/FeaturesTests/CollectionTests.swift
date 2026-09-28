import Testing
import Foundation
import SwiftData
import APICore
import APIStore
import Interop
@testable import Features

@MainActor
@Suite struct CollectionTests {
    @MainActor struct Fixture {
        let context: ModelContext
        let workspace: Workspace
        let model: AppModel
        var actions: CollectionActions { CollectionActions(context: context, model: model) }
    }

    func makeFixture() throws -> Fixture {
        let container = try StoreFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        let model = AppModel(services: AppServices(secrets: InMemorySecretStore()))
        model.attach(workspace: workspace, context: context)
        // Keep the container alive for the test's duration.
        Self.containers.append(container)
        return Fixture(context: context, workspace: workspace, model: model)
    }

    static var containers: [ModelContainer] = []

    @Test func importExportRoundTrip() throws {
        let f = try makeFixture()
        let source = InteropCollection(
            name: "API", description: "d", auth: .none, variables: [Variable(key: "k", value: "secret", isSecret: true)],
            items: [
                .folder(InteropFolder(name: "F", items: [
                    .request(InteropRequest(name: "A", spec: RequestSpec(url: "http://a"), examples: [
                        InteropExample(name: "ok", request: RequestSpec(url: "http://a"), response: ResponseSnapshot(statusCode: 200, body: Data("{}".utf8))),
                    ])),
                ])),
                .request(InteropRequest(name: "B", spec: RequestSpec(method: .post, url: "http://b"))),
            ]
        )
        let collection = InteropMapper.insert(source, into: f.workspace, context: f.context, secrets: f.model.services.secrets)
        #expect(collection.rootNodes.map(\.name) == ["F", "B"])
        #expect(collection.variables.first?.value == "", "secret must not be stored in the database")
        let exported = InteropMapper.export(collection, secrets: f.model.services.secrets, includeSecrets: true)
        #expect(exported.variables.first?.value == "secret")
        #expect(exported.items.map(\.name) == ["F", "B"])
        #expect(exported.allRequests.first?.examples.first?.response.statusCode == 200)
    }

    @Test func moveNodes() throws {
        let f = try makeFixture()
        let collection = f.actions.addCollection(to: f.workspace)
        let folder = f.actions.addNode(.folder, to: collection, parent: nil)
        let first = f.actions.addNode(.request, to: collection, parent: nil)
        let second = f.actions.addNode(.request, to: collection, parent: nil)
        first.name = "first"
        second.name = "second"

        // Drop `second` onto `first`: it is placed before it.
        f.actions.move(second, onto: first)
        #expect(collection.rootNodes.map(\.name) == ["New Folder", "second", "first"])

        // Drop onto a folder: moved inside.
        f.actions.move(first, onto: folder)
        #expect(folder.sortedChildren?.map(\.name) == ["first"])
        #expect(collection.rootNodes.map(\.name) == ["New Folder", "second"])

        // A folder cannot be moved into its own descendant.
        let inner = f.actions.addNode(.folder, to: collection, parent: folder)
        f.actions.move(folder, onto: inner)
        #expect(folder.parent == nil)

        // Move to another collection's root.
        let other = f.actions.addCollection(to: f.workspace)
        f.actions.move(folder, toRootOf: other)
        #expect(other.rootNodes.map(\.id) == [folder.id])
        #expect(first.collection === other)
        #expect(collection.rootNodes.map(\.name) == ["second"])
    }

    @Test func duplicateAndDeleteClosesTabs() throws {
        let f = try makeFixture()
        let collection = f.actions.addCollection(to: f.workspace)
        let folder = f.actions.addNode(.folder, to: collection, parent: nil)
        let request = f.actions.addNode(.request, to: collection, parent: folder)
        #expect(f.model.tabs.count == 1)
        f.actions.duplicate(folder)
        #expect(collection.rootNodes.count == 2)
        #expect(collection.rootNodes[1].sortedChildren?.count == 1)
        f.actions.delete(folder)
        #expect(f.model.tabs.isEmpty, "tab of deleted request \(request.name) should close")
        #expect(collection.rootNodes.count == 1)
    }

    @Test func pastingCurlReplacesRequest() {
        let document = RequestDocument(name: "r", spec: RequestSpec(testScript: "keep()"))
        document.setURL("curl -X POST https://x.test/a -H 'X: 1' -d '{\"a\":1}'")
        #expect(document.spec.method == .post)
        #expect(document.spec.url == "https://x.test/a")
        #expect(document.spec.body.rawLanguage == .json)
        #expect(document.spec.testScript == "keep()")
    }

    @Test func importPayloadDetection() throws {
        if case .curl = try ImportPayload.detect(Data("curl http://x".utf8)) {} else { Issue.record("expected curl") }
        if case .environment = try ImportPayload.detect(Data(#"{"name":"e","values":[]}"#.utf8)) {} else { Issue.record("expected environment") }
        #expect(throws: ImportError.self) { try ImportPayload.detect(Data("hello".utf8)) }
    }
}
