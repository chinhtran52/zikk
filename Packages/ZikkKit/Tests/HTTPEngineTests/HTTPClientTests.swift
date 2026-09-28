import Testing
import Foundation
import APICore
import HTTPServer
@testable import HTTPEngine

/// Integration tests against a local `HTTPServer`.
@Suite struct HTTPClientTests {
    static func echoServer() async throws -> (HTTPServer, String) {
        let server = HTTPServer { request in
            switch request.path {
            case "/redirect":
                return ServerResponse(status: 302, headers: [("Location", "/echo"), ("Set-Cookie", "session=abc; Path=/")])
            case "/loop":
                return ServerResponse(status: 302, headers: [("Location", "/loop")])
            case "/digest":
                if let auth = request.header("Authorization"), auth.hasPrefix("Digest"), auth.contains("username=\"u\"") {
                    return ServerResponse(text: "ok")
                }
                return ServerResponse(status: 401, headers: [("WWW-Authenticate", #"Digest realm="r", qop="auth", nonce="n1""#)])
            default:
                let headers = Dictionary(request.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
                return .json(["method": request.method, "path": request.path, "query": request.query ?? "", "headers": headers,
                              "body": String(data: request.body, encoding: .utf8) ?? ""])
            }
        }
        let port = try await server.start()
        return (server, "http://127.0.0.1:\(port)")
    }

    func json(_ snapshot: ResponseSnapshot) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: snapshot.body) as? [String: Any])
    }

    @Test func sendsRawJSONBody() async throws {
        let (server, base) = try await Self.echoServer()
        defer { server.stop() }
        let spec = RequestSpec(method: .post, url: "{{base}}/echo?x=1", body: RequestBody(mode: .raw, raw: #"{"id": {{id}}}"#, rawLanguage: .json))
        let prepared = try RequestBuilder(resolver: VariableResolver(scopes: [["base": base, "id": "7"]]), auth: .none).build(spec)
        let response = try await HTTPClient().send(prepared)
        let echo = try json(response)
        #expect(response.statusCode == 200)
        #expect(echo["method"] as? String == "POST")
        #expect(echo["query"] as? String == "x=1")
        #expect(echo["body"] as? String == #"{"id": 7}"#)
        #expect((echo["headers"] as? [String: String])?["content-type"] == "application/json")
        #expect(response.timings.total > 0)
    }

    @Test func multipartFormData() async throws {
        let (server, base) = try await Self.echoServer()
        defer { server.stop() }
        let file = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID()).txt")
        try Data("file-content".utf8).write(to: file)
        let body = RequestBody(mode: .formData, formData: [
            FormDataField(key: "name", value: "Linh"),
            FormDataField(key: "doc", kind: .file, file: FileReference(path: file.path)),
        ])
        let prepared = try RequestBuilder(resolver: VariableResolver(), auth: .none).build(RequestSpec(method: .post, url: base + "/echo", body: body))
        let echo = try json(try await HTTPClient().send(prepared))
        let text = try #require(echo["body"] as? String)
        #expect(text.contains("name=\"name\"\r\n\r\nLinh"))
        #expect(text.contains("filename=\"\(file.lastPathComponent)\"\r\nContent-Type: text/plain\r\n\r\nfile-content"))
        #expect((echo["headers"] as? [String: String])?["content-type"]?.hasPrefix("multipart/form-data; boundary=") == true)
    }

    @Test func followsRedirectAndStoresCookies() async throws {
        let (server, base) = try await Self.echoServer()
        defer { server.stop() }
        let jar = CookieJar()
        let prepared = try RequestBuilder(resolver: VariableResolver(), auth: .none).build(RequestSpec(url: base + "/redirect"))
        let response = try await HTTPClient(cookieJar: jar).send(prepared)
        #expect(response.statusCode == 200)
        #expect(response.url.hasSuffix("/echo"))
        #expect(jar.all.map(\.name) == ["session"])
        // Cookie from the redirect response is sent on the follow-up request.
        #expect((try json(response)["headers"] as? [String: String])?["cookie"] == "session=abc")
    }

    @Test func doesNotFollowRedirectWhenDisabled() async throws {
        let (server, base) = try await Self.echoServer()
        defer { server.stop() }
        var spec = RequestSpec(url: base + "/redirect")
        spec.settings.followRedirects = false
        let response = try await HTTPClient().send(try RequestBuilder(resolver: VariableResolver(), auth: .none).build(spec))
        #expect(response.statusCode == 302)
        #expect(response.header("location") == "/echo")
    }

    @Test func stopsRedirectLoops() async throws {
        let (server, base) = try await Self.echoServer()
        defer { server.stop() }
        var spec = RequestSpec(url: base + "/loop")
        spec.settings.maxRedirects = 3
        await #expect(throws: HTTPClientError.self) {
            try await HTTPClient().send(try RequestBuilder(resolver: VariableResolver(), auth: .none).build(spec))
        }
    }

    @Test func digestChallengeRoundTrip() async throws {
        let (server, base) = try await Self.echoServer()
        defer { server.stop() }
        var auth = AuthConfig(type: .digest)
        auth.digest = DigestAuth(username: "u", password: "p")
        let response = try await HTTPClient().send(try RequestBuilder(resolver: VariableResolver(), auth: auth).build(RequestSpec(url: base + "/digest")))
        #expect(response.statusCode == 200)
        #expect(response.bodyText == "ok")
    }

    @Test func graphQLBody() async throws {
        let (server, base) = try await Self.echoServer()
        defer { server.stop() }
        let body = RequestBody(mode: .graphQL, graphQL: GraphQLBody(query: "{ user(id: $id) { name } }", variables: #"{"id": 1}"#))
        let echo = try json(try await HTTPClient().send(try RequestBuilder(resolver: VariableResolver(), auth: .none).build(RequestSpec(method: .post, url: base, body: body))))
        let sent = try #require(try JSONSerialization.jsonObject(with: Data((echo["body"] as! String).utf8)) as? [String: Any])
        #expect(sent["query"] as? String == "{ user(id: $id) { name } }")
        #expect((sent["variables"] as? [String: Any])?["id"] as? Int == 1)
    }
}
