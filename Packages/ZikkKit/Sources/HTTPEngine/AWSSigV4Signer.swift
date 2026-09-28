import Foundation
import CryptoKit
import APICore

/// AWS Signature Version 4 signing.
struct AWSSigV4Signer {
    let config: AWSSigV4Auth
    let date: Date

    func sign(_ request: inout URLRequest) {
        guard let url = request.url, let host = url.host else { return }
        let amzDate = Self.format(date, "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = Self.format(date, "yyyyMMdd")
        let payloadHash = SHA256.hash(data: request.httpBody ?? Data()).hex

        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if !config.sessionToken.isEmpty { request.setValue(config.sessionToken, forHTTPHeaderField: "X-Amz-Security-Token") }
        if config.service == "s3" { request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256") }

        var headers: [String: String] = ["host": hostHeader]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if lower == "user-agent" || lower == "accept" { continue }
            headers[lower] = value.trimmingCharacters(in: .whitespaces).replacing(/\s+/, with: " ")
        }
        let signedHeaderNames = headers.keys.sorted()
        let canonicalHeaders = signedHeaderNames.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = signedHeaderNames.joined(separator: ";")

        let canonicalRequest = [
            (request.httpMethod ?? "GET").uppercased(),
            Self.canonicalPath(url, service: config.service),
            Self.canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(config.region)/\(config.service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, SHA256.hash(data: Data(canonicalRequest.utf8)).hex].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(config.secretKey)".utf8))
        for part in [dateStamp, config.region, config.service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)).hex
        request.setValue("AWS4-HMAC-SHA256 Credential=\(config.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
    }

    static func canonicalPath(_ url: URL, service: String) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        guard !path.isEmpty else { return "/" }
        if service == "s3" { return path }
        // Non-S3 services require each segment to be URI-encoded twice (once already applied by the URL).
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { PercentEncoding.rfc3986(String($0)) }
            .joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return PercentEncoding.normalizedParameters(items.map { ($0.name, $0.value ?? "") })
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
