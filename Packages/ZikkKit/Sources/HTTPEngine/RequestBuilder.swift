import Foundation
import APICore

public enum RequestBuildError: LocalizedError, Equatable {
    case emptyURL
    case invalidURL(String)
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .emptyURL: "Enter a request URL."
        case .invalidURL(let url): "Invalid URL: \(url)"
        case .unreadableFile(let path): "Cannot read file: \(path)"
        }
    }
}

/// A fully resolved request ready to send.
public struct PreparedRequest: Sendable {
    public var urlRequest: URLRequest
    /// Effective auth with variables resolved (used for challenge-based schemes like Digest).
    public var auth: AuthConfig
    public var settings: RequestSettings

    public var url: URL { urlRequest.url! }
}

/// Builds a `URLRequest` from a `RequestSpec`: variable substitution, body encoding, and auth.
public struct RequestBuilder: Sendable {
    public var resolver: VariableResolver
    /// Effective auth (inheritance already applied), with unresolved variables.
    public var auth: AuthConfig
    public var userAgent = Branding.userAgent
    public var defaultTimeout: TimeInterval = 30
    /// Injected for deterministic tests.
    public var now: @Sendable () -> Date = { Date() }
    public var nonce: @Sendable () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    public init(resolver: VariableResolver, auth: AuthConfig) {
        self.resolver = resolver
        self.auth = auth
    }

    public func resolvedURLString(for spec: RequestSpec) -> String {
        let resolvedPathVars = spec.pathVariables.map { KeyValue(id: $0.id, key: $0.key, value: resolver.resolve($0.value)) }
        var url = resolver.resolve(RawURL.substitutingPathVariables(in: spec.url, with: resolvedPathVars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty, !url.contains("://") { url = "http://" + url }
        return spec.settings.encodeURL ? PercentEncoding.encodeURL(url) : url
    }

    public func build(_ spec: RequestSpec) throws -> PreparedRequest {
        guard !spec.url.trimmingCharacters(in: .whitespaces).isEmpty else { throw RequestBuildError.emptyURL }
        let urlString = resolvedURLString(for: spec)
        guard var components = URLComponents(string: urlString), components.host?.isEmpty == false else {
            throw RequestBuildError.invalidURL(urlString)
        }
        let auth = resolver.resolveStrings(in: auth)

        if auth.type == .apiKey, auth.apiKey.location == .query, !auth.apiKey.key.isEmpty {
            var items = components.percentEncodedQueryItems ?? []
            items.append(URLQueryItem(name: PercentEncoding.rfc3986(auth.apiKey.key), value: PercentEncoding.rfc3986(auth.apiKey.value)))
            components.percentEncodedQueryItems = items
        }
        guard let url = components.url else { throw RequestBuildError.invalidURL(urlString) }

        var request = URLRequest(url: url)
        request.httpMethod = spec.method.rawValue
        let timeout = spec.settings.timeoutMilliseconds > 0 ? TimeInterval(spec.settings.timeoutMilliseconds) / 1000 : defaultTimeout
        request.timeoutInterval = timeout

        for header in spec.headers.active {
            request.addValue(resolver.resolve(header.value), forHTTPHeaderField: resolver.resolve(header.key))
        }

        let (body, contentType) = try encodeBody(spec.body)
        if let body {
            request.httpBody = body
            if let contentType, request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if request.value(forHTTPHeaderField: "Accept") == nil { request.setValue("*/*", forHTTPHeaderField: "Accept") }

        try applyAuth(auth, to: &request, formParams: spec.body.mode == .urlEncoded ? resolvedPairs(spec.body.urlEncoded) : [])
        return PreparedRequest(urlRequest: request, auth: auth, settings: spec.settings)
    }

    private func resolvedPairs(_ rows: [KeyValue]) -> [(String, String)] {
        rows.active.map { (resolver.resolve($0.key), resolver.resolve($0.value)) }
    }

    package func encodeBody(_ body: RequestBody) throws -> (Data?, String?) {
        switch body.mode {
        case .none:
            return (nil, nil)
        case .raw:
            return (Data(resolver.resolve(body.raw).utf8), body.rawLanguage.contentType)
        case .urlEncoded:
            let encoded = resolvedPairs(body.urlEncoded)
                .map { "\(PercentEncoding.formComponent($0.0))=\(PercentEncoding.formComponent($0.1))" }
                .joined(separator: "&")
            return (Data(encoded.utf8), "application/x-www-form-urlencoded")
        case .formData:
            var multipart = MultipartBody()
            for field in body.formData where field.isEnabled && !field.key.isEmpty {
                let name = resolver.resolve(field.key)
                switch field.kind {
                case .text:
                    multipart.addField(name: name, value: resolver.resolve(field.value), contentType: field.contentType.isEmpty ? nil : field.contentType)
                case .file:
                    guard let file = field.file else { continue }
                    let data: Data
                    do { data = try FileAccess.read(file) } catch { throw RequestBuildError.unreadableFile(file.path) }
                    let type = field.contentType.isEmpty ? FileAccess.mimeType(forPath: file.path) : field.contentType
                    multipart.addFile(name: name, fileName: file.fileName, data: data, contentType: type)
                }
            }
            return (multipart.finalize(), multipart.contentType)
        case .binary:
            guard let file = body.binary else { return (nil, nil) }
            do { return (try FileAccess.read(file), FileAccess.mimeType(forPath: file.path)) } catch { throw RequestBuildError.unreadableFile(file.path) }
        case .graphQL:
            var payload: [String: Any] = ["query": resolver.resolve(body.graphQL.query)]
            let variablesText = resolver.resolve(body.graphQL.variables).trimmingCharacters(in: .whitespacesAndNewlines)
            if !variablesText.isEmpty, let variables = try? JSONSerialization.jsonObject(with: Data(variablesText.utf8)) {
                payload["variables"] = variables
            }
            if !body.graphQL.operationName.isEmpty { payload["operationName"] = body.graphQL.operationName }
            return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), "application/json")
        }
    }

    func applyAuth(_ auth: AuthConfig, to request: inout URLRequest, formParams: [(String, String)]) throws {
        switch auth.type {
        case .inherit, .none, .digest:
            // Digest needs the server challenge; it is handled by `HTTPClient`.
            break
        case .basic:
            let credentials = Data("\(auth.basic.username):\(auth.basic.password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        case .bearer:
            guard !auth.bearer.token.isEmpty else { break }
            let prefix = auth.bearer.prefix.isEmpty ? "" : auth.bearer.prefix + " "
            request.setValue(prefix + auth.bearer.token, forHTTPHeaderField: "Authorization")
        case .apiKey:
            if auth.apiKey.location == .header, !auth.apiKey.key.isEmpty {
                request.setValue(auth.apiKey.value, forHTTPHeaderField: auth.apiKey.key)
            }
        case .oauth1:
            OAuth1Signer(config: auth.oauth1, timestamp: String(Int(now().timeIntervalSince1970)), nonce: nonce())
                .sign(&request, formParams: formParams)
        case .oauth2:
            guard !auth.oauth2.accessToken.isEmpty else { break }
            let prefix = auth.oauth2.headerPrefix.isEmpty ? "" : auth.oauth2.headerPrefix + " "
            request.setValue(prefix + auth.oauth2.accessToken, forHTTPHeaderField: "Authorization")
        case .awsSigV4:
            AWSSigV4Signer(config: auth.awsSigV4, date: now()).sign(&request)
        }
    }
}
