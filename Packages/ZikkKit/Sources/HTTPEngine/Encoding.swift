import Foundation

enum PercentEncoding {
    /// Unreserved characters per RFC 3986 (used by OAuth 1 and SigV4).
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func rfc3986(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// Encodes characters that are not valid in a URL while leaving existing `%XX` escapes intact.
    static func encodeURL(_ url: String) -> String {
        let (base, query, fragment) = split(url)
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.insert(charactersIn: "%:@!$&'()*+,;=")
        var queryAllowed = CharacterSet.urlQueryAllowed
        queryAllowed.insert("%")
        queryAllowed.remove(charactersIn: "+ ")
        queryAllowed.insert("+")
        var result = base.addingPercentEncoding(withAllowedCharacters: pathAllowed.union(CharacterSet(charactersIn: "/?#[]"))) ?? base
        if let query { result += "?" + (query.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? query) }
        if let fragment { result += "#" + (fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(["%"])) ?? fragment) }
        return result
    }

    private static func split(_ url: String) -> (String, String?, String?) {
        var rest = Substring(url)
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        }
        if let q = rest.firstIndex(of: "?") {
            return (String(rest[..<q]), String(rest[rest.index(after: q)...]), fragment)
        }
        return (String(rest), nil, fragment)
    }

    /// `application/x-www-form-urlencoded` encoding of one component.
    static func formComponent(_ string: String) -> String {
        var allowed = unreserved
        allowed.insert(" ")
        return (string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string).replacingOccurrences(of: " ", with: "+")
    }
}

extension PercentEncoding {
    /// RFC 3986-encodes each pair, sorts by name then value, and joins as `name=value&…`.
    static func normalizedParameters(_ pairs: [(String, String)]) -> String {
        let encoded: [(name: String, value: String)] = pairs.map { (rfc3986($0.0), rfc3986($0.1)) }
        let sorted = encoded.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }
}
