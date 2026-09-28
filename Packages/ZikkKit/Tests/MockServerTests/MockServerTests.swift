import Testing
import Foundation
import APICore
import HTTPServer
@testable import MockServer

@Suite struct MockServerTests {
    func example(_ name: String, _ status: Int, _ body: String, params: [KeyValue] = [], headers: [KeyValue] = [], requestBody: String = "") -> MockExample {
        MockExample(name: name, statusCode: status, headers: [KeyValue(key: "Content-Type", value: "application/json")], body: Data(body.utf8),
                    request: RequestSpec(params: params, headers: headers, body: requestBody.isEmpty ? RequestBody() : RequestBody(mode: .raw, raw: requestBody)))
    }

    var routes: [MockRoute] {
        [
            MockRoute(method: "GET", url: "{{baseUrl}}/pets", name: "List", examples: [
                example("All", 200, #"[{"id":1},{"id":2}]"#),
                example("Page 2", 200, #"[{"id":3}]"#, params: [KeyValue(key: "page", value: "2")]),
                example("Error", 500, #"{"error":"boom"}"#),
            ]),
            MockRoute(method: "GET", url: "https://api.test/pets/:id", name: "Get", examples: [
                example("Found", 200, #"{"id":"{{id}}","n":{{$randomInt}}}"#),
            ]),
            MockRoute(method: "GET", url: "{{baseUrl}}/pets/mine", name: "Mine", examples: [example("Mine", 200, #"{"mine":true}"#)]),
            MockRoute(method: "POST", url: "{{baseUrl}}/pets", name: "Create", examples: [
                example("Created", 201, #"{"ok":true}"#, requestBody: #"{"name":"Rex"}"#),
                example("Invalid", 400, #"{"ok":false}"#, requestBody: #"{"name":""}"#),
            ]),
        ]
    }

    func request(_ method: String, _ target: String, headers: [(String, String)] = [], body: String = "") -> ServerRequest {
        ServerRequest(method: method, target: target, version: "HTTP/1.1", headers: headers.map { (name: $0.0, value: $0.1) }, body: Data(body.utf8))
    }

    @Test func matchingRules() {
        let options = MockOptions(matchBody: true)
        func name(_ r: ServerRequest) -> String? { MockMatcher.match(r, routes: routes, options: options)?.example.name }
        #expect(name(request("GET", "/pets")) == "All")
        #expect(name(request("GET", "/pets?page=2")) == "Page 2")
        #expect(name(request("GET", "/pets", headers: [("x-mock-response-code", "500")])) == "Error")
        #expect(name(request("GET", "/pets", headers: [("x-mock-response-name", "Page 2")])) == "Page 2")
        #expect(name(request("GET", "/pets/mine")) == "Mine", "literal segments beat parameters")
        #expect(name(request("GET", "/pets/42")) == "Found")
        #expect(name(request("POST", "/pets", body: #"{ "name": "" }"#)) == "Invalid")
        #expect(name(request("POST", "/pets", body: #"{"name":"Rex"}"#)) == "Created")
        #expect(name(request("DELETE", "/pets/1")) == nil)
    }

    @Test func responderTemplatesAndNotFound() throws {
        let responder = MockResponder(routes: routes)
        let (response, match) = responder.respond(to: request("GET", "/pets/42"))
        #expect(match?.pathParameters == ["id": "42"])
        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(body["id"] as? String == "42")
        #expect(body["n"] is Int)
        #expect(response.headers.contains { $0.name == "Access-Control-Allow-Origin" })

        let (missing, _) = responder.respond(to: request("GET", "/nope"))
        #expect(missing.status == 404)
        let (preflight, _) = responder.respond(to: request("OPTIONS", "/pets", headers: [("Origin", "http://localhost:3000")]))
        #expect(preflight.status == 204)
        #expect(preflight.headers.contains { $0 == (name: "Access-Control-Allow-Origin", value: "http://localhost:3000") })
    }

    @Test func servesOverHTTPWithDelayAndLogs() async throws {
        let routes = routes
        let log = LogBox()
        let instance = MockServerInstance(provider: { MockResponder(routes: routes, options: MockOptions(delay: .milliseconds(50))) }) { entry in
            log.append(entry)
        }
        let port = try await instance.start(port: 0)
        defer { instance.stop() }
        let started = Date()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pets?page=2")!)
        request.setValue("x", forHTTPHeaderField: "X-Test")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect(Date().timeIntervalSince(started) >= 0.05)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Mock-Example") == "Page 2")
        #expect(String(decoding: data, as: UTF8.self) == #"[{"id":3}]"#)
        #expect(log.entries.map(\.exampleName) == ["Page 2"])
        #expect(log.entries.first?.path == "/pets?page=2")
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MockLogEntry] = []
    func append(_ entry: MockLogEntry) { lock.withLock { storage.append(entry) } }
    var entries: [MockLogEntry] { lock.withLock { storage } }
}
