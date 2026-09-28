import Testing
import Foundation
import SwiftData
import APICore
import APIStore
import HTTPServer
import SpecKit
@testable import Features

@MainActor
@Suite struct SpecFeatureTests {
    static var containers: [ModelContainer] = []

    let specText = """
    openapi: 3.0.3
    info: { title: Items, version: '1' }
    servers: [{ url: 'http://127.0.0.1:PORT' }]
    tags: [{ name: items }]
    paths:
      /items:
        get:
          tags: [items]
          summary: List items
          responses:
            '200':
              description: ok
              content:
                application/json:
                  schema:
                    type: array
                    items: { type: object, required: [id], properties: { id: { type: integer } } }
      /health:
        get:
          summary: Health
          responses: { '200': { description: ok } }
    """

    @Test func importGeneratesLinkedCollectionAndContractTests() async throws {
        let server = HTTPServer { request in
            request.path == "/items" ? .json([["id": "not-a-number"]]) : ServerResponse(text: "ok")
        }
        let port = try await server.start()
        defer { server.stop() }
        let container = try StoreFactory.makeContainer(inMemory: true)
        Self.containers.append(container)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        let model = AppModel(services: AppServices(secrets: InMemorySecretStore()))
        model.attach(workspace: workspace, context: context)

        let text = specText.replacingOccurrences(of: "PORT", with: "\(port)")
        guard case .openAPI(let payloadText, let format, let title) = try ImportPayload.detect(Data(text.utf8)) else {
            Issue.record("expected OpenAPI payload"); return
        }
        #expect(format == .yaml && title == "Items")
        let spec = APISpec(name: title, format: format, content: payloadText)
        spec.workspace = workspace
        context.insert(spec)
        let collection = try SpecServices.generateCollection(from: spec, workspace: workspace, context: context, secrets: model.services.secrets)
        #expect(spec.linkedCollectionID == collection.id)
        #expect(collection.rootNodes.map(\.name) == ["items", "Health"])

        // Sending a request from the linked collection runs contract checks.
        let list = try #require(collection.rootNodes.first?.sortedChildren?.first)
        model.openRequest(list)
        let document = try #require(model.selectedTab?.request)
        model.send(document)
        for _ in 0..<300 where document.isSending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(document.response?.statusCode == 200)
        #expect(document.testResults.map(\.passed) == [false])
        #expect(document.testResults.first?.error == "$[0].id: expected integer but found string")

        // Sync: remove /health from the spec, add a new endpoint.
        spec.content = text.replacingOccurrences(of: "  /health:\n    get:\n      summary: Health\n      responses: { '200': { description: ok } }", with: "  /status:\n    get:\n      summary: Status\n      responses: { '200': { description: ok } }")
        let generated = OpenAPIImporter.collection(from: try SpecDocument(text: spec.content))
        let changes = SpecSync.diff(spec: generated, collection: InteropMapper.export(collection, secrets: model.services.secrets))
        #expect(Set(changes.map(\.key)) == ["GET /status", "GET /health"])
        SpecServices.apply(changes, to: collection, basePath: SpecSync.basePath(of: generated), context: context)
        #expect(collection.rootNodes.map(\.name).sorted() == ["Status", "items"])
    }
}
