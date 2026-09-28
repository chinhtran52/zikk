import Foundation

extension VariableResolver {
    /// Resolves every string inside a Codable value (e.g. an `AuthConfig`) by round-tripping through JSON.
    public func resolveStrings<T: Codable>(in value: T) -> T {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return value }
        let resolvedObject = resolveJSON(object)
        guard let resolvedData = try? JSONSerialization.data(withJSONObject: resolvedObject, options: [.fragmentsAllowed]),
              let result = try? JSONDecoder().decode(T.self, from: resolvedData) else { return value }
        return result
    }

    private func resolveJSON(_ object: Any) -> Any {
        switch object {
        case let string as String: resolve(string)
        case let array as [Any]: array.map(resolveJSON)
        case let dictionary as [String: Any]: dictionary.mapValues(resolveJSON)
        default: object
        }
    }
}

extension AuthConfig {
    /// Effective auth for a request given its ancestor chain (collection first, then folders, then the request).
    /// `inherit` defers to the nearest ancestor that is not `inherit`; the root falls back to `none`.
    public static func effective(chain: [AuthConfig]) -> AuthConfig {
        chain.last { $0.type != .inherit } ?? .none
    }
}
