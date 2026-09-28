import Foundation

/// Lenient URL manipulation that tolerates `{{variables}}` (which `URLComponents` rejects).
public enum RawURL {
    /// Splits a raw URL into (base, query, fragment). Query and fragment exclude their delimiter.
    public static func split(_ url: String) -> (base: String, query: String?, fragment: String?) {
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

    /// Parses the query string of a raw URL into key/value rows (values are left percent-encoded as typed).
    public static func queryParams(of url: String) -> [KeyValue] {
        guard let query = split(url).query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: false).compactMap { pair in
            if pair.isEmpty { return nil }
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return KeyValue(key: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// Rebuilds the URL's query string from enabled params, keeping base and fragment.
    public static func replacingQuery(of url: String, with params: [KeyValue]) -> String {
        let (base, _, fragment) = split(url)
        let enabled = params.filter { $0.isEnabled && !($0.key.isEmpty && $0.value.isEmpty) }
        var result = base
        if !enabled.isEmpty {
            result += "?" + enabled.map { $0.value.isEmpty ? $0.key : "\($0.key)=\($0.value)" }.joined(separator: "&")
        }
        if let fragment { result += "#" + fragment }
        return result
    }

    /// Names of `:pathVariable` segments in the URL path, in order.
    public static func pathVariableNames(in url: String) -> [String] {
        let base = split(url).base
        let path: Substring
        if let scheme = base.range(of: "://") {
            let afterScheme = base[scheme.upperBound...]
            path = afterScheme.firstIndex(of: "/").map { afterScheme[$0...] } ?? ""
        } else {
            path = Substring(base)
        }
        return path.split(separator: "/").compactMap { segment in
            guard segment.hasPrefix(":"), segment.count > 1 else { return nil }
            return String(segment.dropFirst())
        }
    }

    /// Replaces `:name` path segments with values from `variables`.
    public static func substitutingPathVariables(in url: String, with variables: [KeyValue]) -> String {
        let values = Dictionary(variables.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard !values.isEmpty else { return url }
        let (base, query, fragment) = split(url)
        var prefix = ""
        var path = Substring(base)
        if let scheme = base.range(of: "://") {
            let afterScheme = base[scheme.upperBound...]
            let slash = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
            prefix = String(base[..<slash])
            path = base[slash...]
        }
        let replaced = path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            if segment.hasPrefix(":"), let value = values[String(segment.dropFirst())] { return value }
            return String(segment)
        }.joined(separator: "/")
        var result = prefix + replaced
        if let query { result += "?" + query }
        if let fragment { result += "#" + fragment }
        return result
    }

    /// Keeps `pathVariables` in sync with `:name` segments in the URL, preserving existing values.
    public static func syncPathVariables(url: String, existing: [KeyValue]) -> [KeyValue] {
        pathVariableNames(in: url).map { name in
            existing.first { $0.key == name } ?? KeyValue(key: name)
        }
    }
}
