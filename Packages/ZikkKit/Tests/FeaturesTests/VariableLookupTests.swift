import Testing
import Foundation
import SwiftData
import APICore
import APIStore
import DesignSystem
@testable import Features

@MainActor
@Suite struct VariableLookupTests {
    static var containers: [ModelContainer] = []

    func makeWorkspace() throws -> (Workspace, CollectionNode) {
        let container = try StoreFactory.makeContainer(inMemory: true)
        Self.containers.append(container)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        workspace.globals = [Variable(key: "BASE_URL", value: "https://global.example.com"), Variable(key: "HOST", value: "global.example.com")]
        let environment = APIEnvironment(name: "Dev")
        environment.variables = [Variable(key: "BASE_URL", value: "https://{{HOST}}/v1"), Variable(key: "TOKEN", value: "", isSecret: true),
                                 Variable(key: "OFF", value: "x", isEnabled: false)]
        environment.workspace = workspace
        context.insert(environment)
        workspace.activeEnvironmentID = environment.id
        let collection = APICollection(name: "Bot")
        collection.variables = [Variable(key: "HOST", value: "collection.example.com")]
        collection.workspace = workspace
        context.insert(collection)
        let node = CollectionNode(kind: .request, name: "Upload utters", request: RequestSpec(url: "{{BASE_URL}}/olivo/utters/upload"), sortIndex: 0)
        node.collection = collection
        context.insert(node)
        try context.save()
        return (workspace, node)
    }

    @Test func environmentWinsAndNestedValuesResolve() throws {
        let (workspace, node) = try makeWorkspace()
        let info = VariableLookup(workspace: workspace, node: node).info(for: "BASE_URL")
        #expect(info.value == "https://{{HOST}}/v1")
        #expect(info.scope.hasSuffix("Dev"))
        #expect(info.resolvedValue == "https://collection.example.com/v1", "collection beats globals for the nested HOST")
    }

    @Test func scopesSecretsDisabledAndUnknown() throws {
        let (workspace, node) = try makeWorkspace()
        let lookup = VariableLookup(workspace: workspace, node: node)
        #expect(lookup.info(for: "HOST").value == "collection.example.com")
        #expect(lookup.info(for: "HOST").resolvedValue == nil)
        #expect(lookup.info(for: "TOKEN").isSecret && lookup.info(for: "TOKEN").isResolved)
        #expect(!lookup.info(for: "OFF").isResolved)
        #expect(!lookup.info(for: "MISSING").isResolved)
        #expect(lookup.info(for: "$guid").isResolved)
        // Without a collection (unsaved tab) globals apply.
        #expect(VariableLookup(workspace: workspace, node: nil).info(for: "HOST").value == "global.example.com")
        workspace.activeEnvironmentID = nil
        #expect(VariableLookup(workspace: workspace, node: nil).info(for: "BASE_URL").value == "https://global.example.com")
    }

    @Test func tokens() {
        let text = "{{BASE_URL}}/olivo/{{ id }}/upload?x={{"
        let tokens = VariableTextField.tokens(in: text)
        #expect(tokens.map(\.name) == ["BASE_URL", "id"])
        #expect(tokens.map { (text as NSString).substring(with: $0.range) } == ["{{BASE_URL}}", "{{ id }}"])
        #expect(VariableTextField.tokens(in: "Hóa {{đơn}}").map { ("Hóa {{đơn}}" as NSString).substring(with: $0.range) } == ["{{đơn}}"])
    }
}
