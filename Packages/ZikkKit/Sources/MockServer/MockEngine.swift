import Foundation
import APICore
import HTTPServer

/// A saved example that the mock can return.
public struct MockExample: Sendable, Hashable {
    public var name: String
    public var statusCode: Int
    public var headers: [KeyValue]
    public var body: Data
    /// The request the example was saved with; used to score query/header/body matches.
    public var request: RequestSpec

    public init(name: String, statusCode: Int, headers: [KeyValue], body: Data, request: RequestSpec) {
        self.name = name
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.request = request
    }
}

/// One endpoint (method + path template) with its examples.
public struct MockRoute: Sendable, Hashable {
    public var method: String
    /// Path segments; `:name`, `{name}` and `{{var}}` segments match anything.
    public var segments: [String]
    public var name: String
    public var examples: [MockExample]

    public init(method: String, path: String, name: String, examples: [MockExample]) {
        self.method = method.uppercased()
        self.segments = MockRoute.segments(of: path)
        self.name = name
        self.examples = examples
    }

    /// Builds a route from a request URL such as `{{baseUrl}}/pets/:id?x=1`.
    public init(method: String, url: String, name: String, examples: [MockExample]) {
        self.init(method: method, path: MockRoute.path(fromURL: url), name: name, examples: examples)
    }

    static func path(fromURL url: String) -> String {
        var base = RawURL.split(url).base
        if base.hasPrefix("{{"), let end = base.range(of: "}}") {
            base = String(base[end.upperBound...])
        } else if let scheme = base.range(of: "://") {
            let rest = base[scheme.upperBound...]
            base = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        return base.isEmpty ? "/" : base
    }

    static func segments(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func isWildcard(_ segment: String) -> Bool {
        segment.hasPrefix(":") || (segment.hasPrefix("{") && segment.hasSuffix("}"))
    }

    static func parameterName(_ segment: String) -> String {
        segment.trimmingCharacters(in: CharacterSet(charactersIn: ":{}"))
    }
}

public struct MockOptions: Sendable, Hashable {
    public var delay: Duration
    public var matchHeaders: Bool
    public var matchBody: Bool
    /// Adds permissive CORS headers and answers preflight requests.
    public var enableCORS: Bool

    public init(delay: Duration = .zero, matchHeaders: Bool = false, matchBody: Bool = false, enableCORS: Bool = true) {
        self.delay = delay
        self.matchHeaders = matchHeaders
        self.matchBody = matchBody
        self.enableCORS = enableCORS
    }
}

public struct MockMatch: Sendable {
    public var route: MockRoute
    public var example: MockExample
    public var pathParameters: [String: String]
}

/// Chooses which example answers a request.
public enum MockMatcher {
    public static func match(_ request: ServerRequest, routes: [MockRoute], options: MockOptions) -> MockMatch? {
        let method = request.method.uppercased()
        let pathSegments = MockRoute.segments(of: request.path.removingPercentEncoding ?? request.path)
        let wantedName = request.header("x-mock-response-name")
        let wantedCode = request.header("x-mock-response-code").flatMap(Int.init)

        var best: (score: Int, match: MockMatch)?
        for route in routes where route.method == method && route.segments.count == pathSegments.count {
            var score = 0
            var parameters: [String: String] = [:]
            var matches = true
            for (template, actual) in zip(route.segments, pathSegments) {
                if MockRoute.isWildcard(template) {
                    parameters[MockRoute.parameterName(template)] = actual
                    score += 1
                } else if template.caseInsensitiveCompare(actual) == .orderedSame {
                    score += 10
                } else {
                    matches = false
                    break
                }
            }
            guard matches else { continue }
            for example in route.examples {
                if let wantedName, example.name != wantedName { continue }
                if let wantedCode, example.statusCode != wantedCode { continue }
                let total = score * 1000 + exampleScore(example, request: request, options: options)
                if best == nil || total > best!.score {
                    best = (total, MockMatch(route: route, example: example, pathParameters: parameters))
                }
            }
        }
        return best?.match
    }

    /// Higher is better: query/header/body agreement, then 2xx preference.
    static func exampleScore(_ example: MockExample, request: ServerRequest, options: MockOptions) -> Int {
        var score = 0
        let query = Dictionary(request.queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        for param in example.request.params where param.isEnabled && !param.key.isEmpty {
            if let value = query[param.key] {
                score += value == param.value ? 20 : 5
            } else {
                score -= 5
            }
        }
        if options.matchHeaders {
            for header in example.request.headers where header.isEnabled && !header.key.isEmpty && !header.value.contains("{{") {
                if request.header(header.key) == header.value { score += 15 } else { score -= 10 }
            }
        }
        if options.matchBody, example.request.body.mode == .raw, !example.request.body.raw.isEmpty {
            let expected = JSONFormatter.minified(example.request.body.raw) ?? example.request.body.raw
            let actual = JSONFormatter.minified(String(decoding: request.body, as: UTF8.self)) ?? String(decoding: request.body, as: UTF8.self)
            score += expected == actual ? 50 : -20
        }
        if (200..<300).contains(example.statusCode) { score += 3 }
        return score
    }
}

/// Log entry for a request handled by a mock server.
public struct MockLogEntry: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let date: Date
    public let method: String
    public let path: String
    public let statusCode: Int
    public let exampleName: String?
    public let requestHeaders: [KeyValue]
    public let requestBody: String
}

/// Builds responses for incoming requests from mock routes.
public struct MockResponder: Sendable {
    public var routes: [MockRoute]
    public var options: MockOptions
    /// Variables for `{{name}}` in example bodies/headers (e.g. an environment).
    public var variables: [String: String]

    public init(routes: [MockRoute], options: MockOptions = MockOptions(), variables: [String: String] = [:]) {
        self.routes = routes
        self.options = options
        self.variables = variables
    }

    public func respond(to request: ServerRequest) -> (ServerResponse, MockMatch?) {
        if options.enableCORS, request.method == "OPTIONS" {
            return (ServerResponse(status: 204, headers: corsHeaders(for: request)), nil)
        }
        guard let match = MockMatcher.match(request, routes: routes, options: options) else {
            let body: [String: Any] = [
                "error": ["name": "mockRequestNotFoundError",
                          "message": "No matching example found for \(request.method) \(request.path). Save an example response for this request in the collection."],
            ]
            var response = ServerResponse.json(body, status: 404)
            if options.enableCORS { response.headers += corsHeaders(for: request) }
            return (response, nil)
        }
        let resolver = VariableResolver(scopes: [variables, match.pathParameters])
        var headers = match.example.headers
            .filter { $0.isEnabled && !["content-length", "transfer-encoding", "connection", "content-encoding"].contains($0.key.lowercased()) }
            .map { (name: resolver.resolve($0.key), value: resolver.resolve($0.value)) }
        let bodyText = String(data: match.example.body, encoding: .utf8)
        let body = bodyText.map { Data(resolver.resolve($0).utf8) } ?? match.example.body
        if options.enableCORS { headers += corsHeaders(for: request) }
        headers.append((name: "X-Mock-Example", value: match.example.name))
        return (ServerResponse(status: match.example.statusCode, headers: headers, body: body), match)
    }

    private func corsHeaders(for request: ServerRequest) -> [(name: String, value: String)] {
        [
            ("Access-Control-Allow-Origin", request.header("Origin") ?? "*"),
            ("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS"),
            ("Access-Control-Allow-Headers", request.header("Access-Control-Request-Headers") ?? "*"),
        ]
    }
}

/// A running mock server: an `HTTPServer` answering from a `MockResponder`.
public final class MockServerInstance: @unchecked Sendable {
    public typealias ResponderProvider = @Sendable () async -> MockResponder
    public typealias LogHandler = @Sendable (MockLogEntry) async -> Void

    private let server: HTTPServer
    public private(set) var port: UInt16 = 0

    public init(provider: @escaping ResponderProvider, onLog: @escaping LogHandler) {
        server = HTTPServer { request in
            let responder = await provider()
            let (response, match) = responder.respond(to: request)
            if responder.options.delay > .zero { try? await Task.sleep(for: responder.options.delay) }
            await onLog(MockLogEntry(date: Date(), method: request.method, path: request.target, statusCode: response.status,
                                     exampleName: match?.example.name,
                                     requestHeaders: request.headers.map { KeyValue(key: $0.name, value: $0.value) },
                                     requestBody: String(decoding: request.body.prefix(64 * 1024), as: UTF8.self)))
            return response
        }
    }

    @discardableResult
    public func start(port: UInt16, loopbackOnly: Bool = true) async throws -> UInt16 {
        self.port = try await server.start(port: port, loopbackOnly: loopbackOnly)
        return self.port
    }

    public func stop() {
        server.stop()
    }

    public var state: HTTPServer.State { server.state }
}
