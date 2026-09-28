import Foundation
import CryptoKit
import APICore

/// OAuth 1.0a request signing (RFC 5849).
struct OAuth1Signer {
    let config: OAuth1Auth
    let timestamp: String
    let nonce: String

    func sign(_ request: inout URLRequest, formParams: [(String, String)]) {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var oauthParams: [(String, String)] = [
            ("oauth_consumer_key", config.consumerKey),
            ("oauth_nonce", nonce),
            ("oauth_signature_method", config.signatureMethod.rawValue),
            ("oauth_timestamp", timestamp),
            ("oauth_version", "1.0"),
        ]
        if !config.token.isEmpty { oauthParams.append(("oauth_token", config.token)) }

        let signature = Self.signature(
            method: request.httpMethod ?? "GET",
            baseURL: Self.baseURL(components),
            params: oauthParams + (components.queryItems ?? []).map { ($0.name, $0.value ?? "") } + formParams,
            consumerSecret: config.consumerSecret,
            tokenSecret: config.tokenSecret,
            method: config.signatureMethod
        )
        oauthParams.append(("oauth_signature", signature))

        if config.addToQuery {
            var updated = components
            var items = updated.percentEncodedQueryItems ?? []
            items += oauthParams.map { URLQueryItem(name: $0.0, value: PercentEncoding.rfc3986($0.1)) }
            updated.percentEncodedQueryItems = items
            request.url = updated.url
        } else {
            var parts = oauthParams.map { "\($0.0)=\"\(PercentEncoding.rfc3986($0.1))\"" }
            if !config.realm.isEmpty { parts.insert("realm=\"\(config.realm)\"", at: 0) }
            request.setValue("OAuth " + parts.joined(separator: ", "), forHTTPHeaderField: "Authorization")
        }
    }

    static func baseURL(_ components: URLComponents) -> String {
        var base = components
        base.query = nil
        base.fragment = nil
        base.scheme = base.scheme?.lowercased()
        base.host = base.host?.lowercased()
        if (base.scheme == "http" && base.port == 80) || (base.scheme == "https" && base.port == 443) { base.port = nil }
        return base.string ?? ""
    }

    static func signature(method httpMethod: String, baseURL: String, params: [(String, String)], consumerSecret: String, tokenSecret: String, method: OAuth1Auth.SignatureMethod) -> String {
        let key = PercentEncoding.rfc3986(consumerSecret) + "&" + PercentEncoding.rfc3986(tokenSecret)
        if method == .plaintext { return key }
        let normalized = PercentEncoding.normalizedParameters(params)
        let baseString = [httpMethod.uppercased(), PercentEncoding.rfc3986(baseURL), PercentEncoding.rfc3986(normalized)].joined(separator: "&")
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        switch method {
        case .hmacSHA256:
            return Data(HMAC<SHA256>.authenticationCode(for: Data(baseString.utf8), using: symmetricKey)).base64EncodedString()
        default:
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(baseString.utf8), using: symmetricKey)).base64EncodedString()
        }
    }
}
