import Foundation

/// HTTP method. Custom methods are allowed, so this is a string wrapper rather than a closed enum.
public struct HTTPMethod: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue.uppercased() }
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    public var description: String { rawValue }

    public static let get: HTTPMethod = "GET"
    public static let post: HTTPMethod = "POST"
    public static let put: HTTPMethod = "PUT"
    public static let patch: HTTPMethod = "PATCH"
    public static let delete: HTTPMethod = "DELETE"
    public static let head: HTTPMethod = "HEAD"
    public static let options: HTTPMethod = "OPTIONS"
    public static let trace: HTTPMethod = "TRACE"

    public static let standard: [HTTPMethod] = [.get, .post, .put, .patch, .delete, .head, .options]
}
