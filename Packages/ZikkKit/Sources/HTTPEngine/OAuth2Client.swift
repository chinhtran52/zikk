import Foundation
import CryptoKit
import APICore

/// OAuth 2.0 token acquisition. The interactive authorization step (browser) is performed by the app.
public struct OAuth2Client: Sendable {
    public struct TokenResponse: Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?
        public var raw: [String: String]
    }

    public enum Failure: LocalizedError {
        case missingURL
        case server(status: Int, body: String)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .missingURL: "The OAuth 2.0 URL is missing or invalid."
            case .server(let status, let body): "Token request failed (\(status)): \(body)"
            case .invalidResponse: "The token response did not contain an access_token."
            }
        }
    }

    public var http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    // MARK: PKCE

    public static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    public static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    /// URL to open in the browser for authorization-code grants.
    public static func authorizationURL(config: OAuth2Auth, codeChallenge: String?) -> URL? {
        guard var components = URLComponents(string: config.authURL) else { return nil }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.callbackURL),
        ]
        if !config.scope.isEmpty { items.append(URLQueryItem(name: "scope", value: config.scope)) }
        if !config.state.isEmpty { items.append(URLQueryItem(name: "state", value: config.state)) }
        if let codeChallenge {
            items += [URLQueryItem(name: "code_challenge", value: codeChallenge), URLQueryItem(name: "code_challenge_method", value: "S256")]
        }
        components.queryItems = items
        return components.url
    }

    // MARK: Token requests

    public func clientCredentials(_ config: OAuth2Auth) async throws -> TokenResponse {
        var params = [("grant_type", "client_credentials")]
        if !config.scope.isEmpty { params.append(("scope", config.scope)) }
        return try await tokenRequest(config, params: params)
    }

    public func password(_ config: OAuth2Auth) async throws -> TokenResponse {
        var params = [("grant_type", "password"), ("username", config.username), ("password", config.password)]
        if !config.scope.isEmpty { params.append(("scope", config.scope)) }
        return try await tokenRequest(config, params: params)
    }

    public func exchangeCode(_ code: String, config: OAuth2Auth, codeVerifier: String?) async throws -> TokenResponse {
        var params = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", config.callbackURL)]
        if let codeVerifier { params.append(("code_verifier", codeVerifier)) }
        return try await tokenRequest(config, params: params)
    }

    public func refresh(_ config: OAuth2Auth) async throws -> TokenResponse {
        try await tokenRequest(config, params: [("grant_type", "refresh_token"), ("refresh_token", config.refreshToken)])
    }

    private func tokenRequest(_ config: OAuth2Auth, params: [(String, String)]) async throws -> TokenResponse {
        guard let url = URL(string: config.accessTokenURL), url.host != nil else { throw Failure.missingURL }
        var params = params
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch config.clientAuthentication {
        case .basicHeader:
            let credentials = "\(PercentEncoding.formComponent(config.clientID)):\(PercentEncoding.formComponent(config.clientSecret))"
            request.setValue("Basic " + Data(credentials.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        case .body:
            params.append(("client_id", config.clientID))
            if !config.clientSecret.isEmpty { params.append(("client_secret", config.clientSecret)) }
        }
        request.httpBody = Data(params.map { "\(PercentEncoding.formComponent($0.0))=\(PercentEncoding.formComponent($0.1))" }.joined(separator: "&").utf8)

        let response = try await http.send(PreparedRequest(urlRequest: request, auth: .none, settings: RequestSettings()))
        guard response.isSuccess else { throw Failure.server(status: response.statusCode, body: response.bodyText ?? "") }
        return try Self.parseToken(response.body)
    }

    static func parseToken(_ data: Data) throws -> TokenResponse {
        var raw: [String: String] = [:]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object { raw[key] = "\(value)" }
        } else if let text = String(data: data, encoding: .utf8) {
            // Some providers (e.g. GitHub) reply form-encoded.
            for pair in text.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if parts.count == 2 { raw[parts[0]] = parts[1] }
            }
        }
        guard let token = raw["access_token"], !token.isEmpty else { throw Failure.invalidResponse }
        let expiresAt = raw["expires_in"].flatMap(Double.init).map { Date().addingTimeInterval($0) }
        return TokenResponse(accessToken: token, refreshToken: raw["refresh_token"], expiresAt: expiresAt, raw: raw)
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
