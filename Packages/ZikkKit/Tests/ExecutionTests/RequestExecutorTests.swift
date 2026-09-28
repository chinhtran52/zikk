import Testing
import Foundation
import APICore
import HTTPEngine
import HTTPServer
import ScriptEngine
@testable import Execution

@Suite struct RequestExecutorTests {
    @Test func fullPipelineWithInheritedScriptsAndAuth() async throws {
        let server = HTTPServer { request in
            .json(["auth": request.header("Authorization") ?? "", "trace": request.header("X-Trace") ?? "", "path": request.path])
        }
        let port = try await server.start()
        defer { server.stop() }

        var bearer = AuthConfig(type: .bearer)
        bearer.bearer.token = "{{token}}"
        let request = ExecutionRequest(
            spec: RequestSpec(url: "http://127.0.0.1:\(port)/items/{{id}}", headers: [KeyValue(key: "X-Trace", value: "{{trace}}")],
                              preRequestScript: "pm.variables.set('trace', 'req-' + pm.collectionVariables.get('prefix'));",
                              testScript: "pm.test('echo', () => pm.expect(pm.response.json().trace).to.eql('req-p'));"),
            name: "Get item",
            parentAuth: [bearer, .inherit],
            parentPreRequestScripts: ["pm.environment.set('id', '42');"],
            parentTestScripts: ["pm.test('status', () => pm.response.to.have.status(200)); pm.globals.set('lastPath', pm.response.json().path);"]
        )
        let scopes = VariableScopes(globals: [Variable(key: "token", value: "g-token")], collection: [Variable(key: "prefix", value: "p")])
        let result = await RequestExecutor(client: HTTPClient()).execute(request, scopes: scopes)

        #expect(result.errorMessage == nil)
        #expect(result.scriptErrors.isEmpty)
        #expect(result.response?.statusCode == 200)
        #expect(result.resolvedURL.hasSuffix("/items/42"))
        #expect(result.tests.map(\.name) == ["status", "echo"])
        #expect(result.failedCount == 0)
        #expect(result.scopes.environment.first { $0.key == "id" }?.value == "42")
        #expect(result.scopes.globals.first { $0.key == "lastPath" }?.value == "/items/42")
        let body = try #require(result.response?.bodyText)
        #expect(body.contains("Bearer g-token"))
    }

    @Test func skipRequestStopsBeforeSending() async {
        let request = ExecutionRequest(spec: RequestSpec(url: "http://127.0.0.1:1/never", preRequestScript: "pm.execution.skipRequest()"))
        let result = await RequestExecutor(client: HTTPClient()).execute(request, scopes: VariableScopes())
        #expect(result.skipped)
        #expect(result.response == nil)
        #expect(result.errorMessage == nil)
    }

    @Test func networkErrorsAreReported() async {
        let result = await RequestExecutor(client: HTTPClient()).execute(ExecutionRequest(spec: RequestSpec(url: "http://127.0.0.1:1/")), scopes: VariableScopes())
        #expect(result.errorMessage != nil)
    }

    @Test func mergeKeepsMetadata() {
        let secret = Variable(key: "token", value: "old", isSecret: true)
        let disabled = Variable(key: "off", value: "x", isEnabled: false)
        let removed = Variable(key: "gone", value: "1")
        let merged = VariableMerge.merge([secret, disabled, removed], with: [("token", "new"), ("added", "2")])
        #expect(merged.map(\.key) == ["token", "off", "added"])
        #expect(merged[0].isSecret && merged[0].value == "new" && merged[0].id == secret.id)
        #expect(merged[1] == disabled)
    }
}

@Suite struct ResponseValidatorTests {
    @Test func validatorResultsAreAppended() async throws {
        let server = HTTPServer { _ in ServerResponse(status: 418, text: "teapot") }
        let port = try await server.start()
        defer { server.stop() }
        let executor = RequestExecutor(client: HTTPClient()) { _, url, response in
            [TestResult(name: "Contract \(URL(string: url)?.path ?? "")", passed: response.statusCode == 200, error: "status \(response.statusCode)")]
        }
        let result = await executor.execute(ExecutionRequest(spec: RequestSpec(url: "http://127.0.0.1:\(port)/tea")), scopes: VariableScopes())
        #expect(result.tests.map(\.name) == ["Contract /tea"])
        #expect(result.failedCount == 1)
    }
}
