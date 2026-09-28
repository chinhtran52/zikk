import Foundation

/// Resolves `{{name}}` placeholders against layered scopes.
///
/// Scopes are ordered from lowest to highest precedence:
/// globals → collection → environment → iteration data → local.
public struct VariableResolver: Sendable {
    public var scopes: [[String: String]]
    public var maxDepth = 10

    public init(scopes: [[String: String]] = []) {
        self.scopes = scopes
    }

    public init(globals: [Variable] = [], collection: [Variable] = [], environment: [Variable] = [], data: [String: String] = [:], local: [String: String] = [:]) {
        self.scopes = [globals.asDictionary, collection.asDictionary, environment.asDictionary, data, local]
    }

    public func value(for key: String) -> String? {
        for scope in scopes.reversed() {
            if let value = scope[key] { return value }
        }
        return DynamicVariables.value(for: key)
    }

    /// Replaces every resolvable placeholder; unresolved ones are left untouched.
    public func resolve(_ input: String) -> String {
        guard input.contains("{{") else { return input }
        var current = input
        for _ in 0..<maxDepth {
            let next = substituteOnce(current)
            if next == current { break }
            current = next
        }
        return current
    }

    /// Placeholder names that cannot be resolved in `input`.
    public func unresolvedVariables(in input: String) -> [String] {
        Self.placeholders(in: resolve(input)).filter { value(for: $0) == nil }
    }

    /// All `{{name}}` placeholder names in `input`, in order of appearance.
    public static func placeholders(in input: String) -> [String] {
        input.matches(of: placeholderRegex).map { String($0.output.1).trimmingCharacters(in: .whitespaces) }
    }

    nonisolated(unsafe) private static let placeholderRegex = /\{\{([^{}]+)\}\}/

    private func substituteOnce(_ input: String) -> String {
        input.replacing(Self.placeholderRegex) { match in
            let name = String(match.output.1).trimmingCharacters(in: .whitespaces)
            return value(for: name) ?? String(match.output.0)
        }
    }
}

extension Array where Element == Variable {
    public var asDictionary: [String: String] {
        var result: [String: String] = [:]
        for variable in self where variable.isEnabled && !variable.key.isEmpty {
            result[variable.key] = variable.value
        }
        return result
    }
}
