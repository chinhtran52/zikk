import Foundation
import APICore
import HTTPEngine

/// Language-neutral request description consumed by snippet generators.
public struct SnippetRequest: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        case none
        case text(String)
        case urlEncoded([Pair])
        case formData([Part])
        case file(path: String)
    }

    public struct Pair: Sendable, Equatable {
        public var name: String
        public var value: String
        public init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }

    public struct Part: Sendable, Equatable {
        public var name: String
        public var value: String?
        public var filePath: String?
        public var contentType: String?
    }

    public var method: String
    public var url: String
    public var headers: [Pair]
    public var body: Body

    public init(method: String, url: String, headers: [Pair], body: Body) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Resolves variables and auth for `spec` (without reading any files).
    public init(spec: RequestSpec, resolver: VariableResolver, auth: AuthConfig) throws {
        var headerOnly = spec
        headerOnly.body = RequestBody()
        var builder = RequestBuilder(resolver: resolver, auth: auth)
        builder.userAgent = ""
        let prepared = try builder.build(headerOnly)
        var headers = (prepared.urlRequest.allHTTPHeaderFields ?? [:])
            .filter { !($0.key == "Accept" && $0.value == "*/*") && !($0.key == "User-Agent" && $0.value.isEmpty) }
        // Keep user header order, then generated ones (auth etc.).
        var ordered: [Pair] = []
        for header in spec.headers.active {
            let name = resolver.resolve(header.key)
            if let value = headers.removeValue(forKey: name) { ordered.append(Pair(name, value)) }
        }
        ordered += headers.sorted { $0.key < $1.key }.map { Pair($0.key, $0.value) }

        let hasContentType = ordered.contains { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
        func addContentType(_ value: String) { if !hasContentType { ordered.append(Pair("Content-Type", value)) } }

        let body: Body
        switch spec.body.mode {
        case .none:
            body = .none
        case .raw:
            body = .text(resolver.resolve(spec.body.raw))
            addContentType(spec.body.rawLanguage.contentType)
        case .graphQL:
            let (data, _) = try builder.encodeBodyForSnippet(spec.body)
            body = .text(String(decoding: data ?? Data(), as: UTF8.self))
            addContentType("application/json")
        case .urlEncoded:
            body = .urlEncoded(spec.body.urlEncoded.active.map { Pair(resolver.resolve($0.key), resolver.resolve($0.value)) })
            addContentType("application/x-www-form-urlencoded")
        case .formData:
            body = .formData(spec.body.formData.filter { $0.isEnabled && !$0.key.isEmpty }.map { field in
                Part(name: resolver.resolve(field.key),
                     value: field.kind == .text ? resolver.resolve(field.value) : nil,
                     filePath: field.kind == .file ? (field.file?.path ?? "") : nil,
                     contentType: field.contentType.isEmpty ? nil : field.contentType)
            })
        case .binary:
            body = spec.body.binary.map { .file(path: $0.path) } ?? .none
        }
        self.init(method: spec.method.rawValue, url: prepared.url.absoluteString, headers: ordered, body: body)
    }
}

extension RequestBuilder {
    package func encodeBodyForSnippet(_ body: RequestBody) throws -> (Data?, String?) {
        try encodeBody(body)
    }
}
