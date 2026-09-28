import Foundation

/// Where to connect: host, port and transport security.
public struct GRPCTarget: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var verifyTLS: Bool

    public init(host: String, port: Int, useTLS: Bool, verifyTLS: Bool = true) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.verifyTLS = verifyTLS
    }

    /// Parses `grpc://host:port`, `grpcs://host:port`, `https://host`, `http://host:port` or bare `host:port` (plaintext).
    public static func parse(_ text: String, verifyTLS: Bool = true) -> GRPCTarget? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var useTLS = false
        var defaultPort = 80
        for (scheme, tls, port) in [("grpcs://", true, 443), ("https://", true, 443), ("grpc://", false, 80), ("http://", false, 80)] where rest.lowercased().hasPrefix(scheme) {
            rest = String(rest.dropFirst(scheme.count))
            useTLS = tls
            defaultPort = port
        }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        guard !rest.isEmpty else { return nil }
        var host = rest
        var port = defaultPort
        if rest.hasPrefix("["), let end = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<end])
            let after = rest[rest.index(after: end)...]
            if after.hasPrefix(":"), let value = Int(after.dropFirst()) { port = value }
        } else if let colon = rest.lastIndex(of: ":"), let value = Int(rest[rest.index(after: colon)...]) {
            host = String(rest[..<colon])
            port = value
        }
        return GRPCTarget(host: host, port: port, useTLS: useTLS, verifyTLS: verifyTLS)
    }
}
