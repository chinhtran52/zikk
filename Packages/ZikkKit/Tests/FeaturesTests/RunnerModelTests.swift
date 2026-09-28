import Testing
import Foundation
import SwiftData
import APICore
import APIStore
import HTTPServer
@testable import Features

@MainActor
@Suite struct RunnerModelTests {
    static var containers: [ModelContainer] = []

    @Test func runsSelectedRequestsWithDataset() async throws {
        let server = HTTPServer { request in .json(["user": request.queryItems.first?.value ?? ""]) }
        let port = try await server.start()
        defer { server.stop() }

        let container = try StoreFactory.makeContainer(inMemory: true)
        Self.containers.append(container)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        let model = AppModel(services: AppServices(secrets: InMemorySecretStore()))
        model.attach(workspace: workspace, context: context)
        let actions = CollectionActions(context: context, model: model)
        let collection = actions.addCollection(to: workspace)
        collection.variables = [Variable(key: "base", value: "http://127.0.0.1:\(port)")]
        let folder = actions.addNode(.folder, to: collection, parent: nil)
        let getUser = actions.addNode(.request, to: collection, parent: folder)
        getUser.name = "Get user"
        getUser.request = RequestSpec(url: "{{base}}/users?name={{name}}", testScript: """
        pm.test("echo", () => pm.expect(pm.response.json().user).to.eql(pm.iterationData.get("name")));
        pm.collectionVariables.set("last", pm.response.json().user);
        """)
        let skipped = actions.addNode(.request, to: collection, parent: nil)
        skipped.name = "Unselected"
        let dataset = Dataset(name: "users", columns: ["name"], rows: [["name": "an"], ["name": "binh"]])
        dataset.workspace = workspace
        context.insert(dataset)
        try context.save()

        let runner = RunnerModel(collectionID: collection.id, folderID: nil)
        runner.load(context: context)
        #expect(runner.selections.map(\.name) == ["Get user", "Unselected"])
        #expect(runner.selections[0].path == "New Folder")
        runner.selections[1].isSelected = false
        runner.datasetID = dataset.id
        runner.run(workspace: workspace, context: context, services: model.services)
        for _ in 0..<300 where runner.isRunning { try await Task.sleep(for: .milliseconds(10)) }

        #expect(runner.state == .finished)
        #expect(runner.results.map(\.name) == ["Get user", "Get user"])
        let allPassed = runner.results.flatMap(\.tests).allSatisfy(\.passed)
        #expect(allPassed)
        #expect(collection.variables.first { $0.key == "last" }?.value == "binh")
        let report = try #require(runner.report(json: false, collectionName: collection.name))
        #expect(String(decoding: report, as: UTF8.self).contains(#"<testcase name="echo" classname="Get user"/>"#))

        model.openRunner(collection: collection, folder: folder)
        model.openRunner(collection: collection, folder: folder)
        let runnerTabs = model.tabs.filter { $0.runner != nil }.count
        #expect(runnerTabs == 1)
    }
}
