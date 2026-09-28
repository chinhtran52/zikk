import Foundation
import CryptoKit
import APICore

/// HTTP Digest authentication (RFC 7616 / 2617) — computes the Authorization header from a 401 challenge.
struct DigestAuthenticator {
    let username: String
    let password: String
    var cnonce: () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased() }

    /// Parses `WWW-Authenticate: Digest realm="…", nonce="…", …`.
    static func parseChallenge(_ header: String) -> [String: String]? {
        guard header.lowercased().hasPrefix("digest") else { return nil }
        var result: [String: String] = [:]
        let body = header.dropFirst("digest".count)
        for match in body.matches(of: /([A-Za-z0-9_-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^,\s]+))/) {
            result[String(match.output.1).lowercased()] = String(match.output.2 ?? match.output.3 ?? "")
        }
        return result
    }

    func authorization(challenge: [String: String], method: String, uri: String, body: Data?, nc: Int = 1) -> String {
        let realm = challenge["realm"] ?? ""
        let nonce = challenge["nonce"] ?? ""
        let algorithm = (challenge["algorithm"] ?? "MD5").uppercased()
        let qopOptions = (challenge["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let qop = qopOptions.contains("auth") ? "auth" : (qopOptions.contains("auth-int") ? "auth-int" : nil)
        let hash: (String) -> String = algorithm.hasPrefix("SHA-256")
            ? { SHA256.hash(data: Data($0.utf8)).hex }
            : { Insecure.MD5.hash(data: Data($0.utf8)).hex }

        let ncValue = String(format: "%08x", nc)
        let clientNonce = cnonce()
        var ha1 = hash("\(username):\(realm):\(password)")
        if algorithm.hasSuffix("-SESS") { ha1 = hash("\(ha1):\(nonce):\(clientNonce)") }
        let ha2 = qop == "auth-int"
            ? hash("\(method):\(uri):\(SHA256.hash(data: body ?? Data()).hex)")
            : hash("\(method):\(uri)")
        let response = qop.map { hash("\(ha1):\(nonce):\(ncValue):\(clientNonce):\($0):\(ha2)") } ?? hash("\(ha1):\(nonce):\(ha2)")

        var parts = [
            "username=\"\(username)\"", "realm=\"\(realm)\"", "nonce=\"\(nonce)\"", "uri=\"\(uri)\"",
            "algorithm=\(algorithm)", "response=\"\(response)\"",
        ]
        if let qop { parts += ["qop=\(qop)", "nc=\(ncValue)", "cnonce=\"\(clientNonce)\""] }
        if let opaque = challenge["opaque"] { parts.append("opaque=\"\(opaque)\"") }
        return "Digest " + parts.joined(separator: ", ")
    }
}
