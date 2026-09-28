import Testing
import Foundation
import SwiftData
import APICore
import APIStore
import HTTPServer
@testable import Features

@MainActor
@Suite struct RequestDocumentTests {
    @Test func urlDrivesParamsAndPathVariables() {
        let document = RequestDocument(name: "r")
        document.setURL("{{base}}/users/:id?page=1&sort=name")
        #expect(document.spec.params.map(\.key) == ["page", "sort"])
        #expect(document.spec.pathVariables.map(\.key) == ["id"])

        // Disabled params survive URL edits.
        var params = document.spec.params
        params[1].isEnabled = false
        document.setParams(params)
        #expect(document.spec.url == "{{base}}/users/:id?page=1")
        document.setURL("{{base}}/users/:id?page=2")
        #expect(document.spec.params.map(\.key) == ["page", "sort"])
        #expect(document.spec.params.map(\.isEnabled) == [true, false])
        #expect(document.spec.params[0].value == "2")
    }

    @Test func dirtyTracking() {
        let document = RequestDocument(name: "r", spec: RequestSpec(url: "http://x"), nodeID: UUID())
        #expect(!document.isDirty)
        document.spec.method = .post
        #expect(document.isDirty)
    }

    @Test func secretVariablesRoundTrip() {
        let store = InMemorySecretStore()
        let scope = UUID()
        let secret = Variable(key: "token", value: "s3cret", isSecret: true)
        let plain = Variable(key: "host", value: "h")
        let persisted = SecretVariables.save([secret, plain], previous: [], scope: scope, store: store)
        #expect(persisted[0].value == "")
        #expect(persisted[1].value == "h")
        #expect(SecretVariables.load(persisted, scope: scope, store: store)[0].value == "s3cret")
        // Un-marking as secret removes it from the store.
        var unmarked = secret
        unmarked.isSecret = false
        _ = SecretVariables.save([unmarked], previous: persisted, scope: scope, store: store)
        #expect(store.value(for: SecretVariables.storeKey(scope: scope, variable: secret.id)) == nil)
    }

    @Test func contextResolvesScopesAndInheritedAuth() throws {
        let container = try StoreFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        workspace.globals = [Variable(key: "host", value: "global"), Variable(key: "g", value: "1")]
        let environment = APIEnvironment(name: "dev", variables: [Variable(key: "host", value: "env")])
        environment.workspace = workspace
        workspace.activeEnvironmentID = environment.id
        let collection = APICollection(name: "c")
        collection.workspace = workspace
        var bearer = AuthConfig(type: .bearer)
        bearer.bearer.token = "{{g}}"
        collection.auth = bearer
        let folder = CollectionNode(kind: .folder, name: "f")
        folder.collection = collection
        folder.preRequestScript = "folder()"
        let node = CollectionNode(kind: .request, name: "r", request: RequestSpec(url: "{{host}}/x"))
        node.collection = collection
        node.parent = folder
        context.insert(workspace)
        try context.save()

        let requestContext = RequestContext(spec: node.request, node: node, workspace: workspace, secrets: InMemorySecretStore())
        #expect(requestContext.resolver.resolve("{{host}}-{{g}}") == "env-1")
        #expect(requestContext.effectiveAuth(for: node.request).type == .bearer)
        #expect(requestContext.parentPreRequestScripts == ["", "folder()"])
        let prepared = try requestContext.builder(for: node.request).build(node.request)
        #expect(prepared.urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer 1")
    }

    @Test func sendRecordsHistoryAndResponse() async throws {
        let server = HTTPServer { _ in ServerResponse(status: 201, headers: [("Set-Cookie", "a=b; Path=/")], body: Data("{}".utf8)) }
        let port = try await server.start()
        defer { server.stop() }
        let container = try StoreFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        let model = AppModel(services: AppServices(secrets: InMemorySecretStore()))
        model.attach(workspace: workspace, context: context)
        model.openDraft(spec: RequestSpec(url: "http://127.0.0.1:\(port)/items"))
        let document = try #require(model.selectedTab?.request)
        model.send(document)
        for _ in 0..<200 where document.isSending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(document.response?.statusCode == 201)
        #expect(workspace.history.count == 1)
        #expect(workspace.history.first?.statusCode == 201)
        #expect(model.services.cookieJar.all.map(\.name) == ["a"])
        #expect(try context.fetch(FetchDescriptor<CookieRecord>()).count == 1)
        #expect(model.services.console.entries.count == 1)
    }

    @Test func scriptsRunAndPersistVariables() async throws {
        let server = HTTPServer { _ in .json(["token": "fresh"]) }
        let port = try await server.start()
        defer { server.stop() }
        let container = try StoreFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        let secrets = InMemorySecretStore()
        let environment = APIEnvironment(name: "dev")
        environment.variables = SecretVariables.save([Variable(key: "token", value: "old", isSecret: true)], previous: [], scope: environment.id, store: secrets)
        environment.workspace = workspace
        workspace.activeEnvironmentID = environment.id
        try context.save()

        let model = AppModel(services: AppServices(secrets: secrets))
        model.attach(workspace: workspace, context: context)
        model.openDraft(spec: RequestSpec(url: "http://127.0.0.1:\(port)/login", testScript: """
        pm.test("has token", () => pm.expect(pm.response.json()).to.have.property("token"));
        pm.environment.set("token", pm.response.json().token);
        console.log("saved");
        """))
        let document = try #require(model.selectedTab?.request)
        model.send(document)
        for _ in 0..<300 where document.isSending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(document.testResults.map(\.passed) == [true])
        #expect(environment.variables.first?.value == "", "secret stays out of the database")
        #expect(SecretVariables.load(environment.variables, scope: environment.id, store: secrets).first?.value == "fresh")
        #expect(model.services.console.entries.count == 2)
    }
}
