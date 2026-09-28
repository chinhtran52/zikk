import Foundation

/// A toggleable key/value row used for params, headers, url-encoded bodies, etc.
public struct KeyValue: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var isEnabled: Bool
    public var description: String

    public init(id: UUID = UUID(), key: String = "", value: String = "", isEnabled: Bool = true, description: String = "") {
        self.id = id
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
        self.description = description
    }

    public var isBlank: Bool { key.isEmpty && value.isEmpty && description.isEmpty }
}

extension Array where Element == KeyValue {
    /// Enabled rows that have a non-empty key.
    public var active: [KeyValue] { filter { $0.isEnabled && !$0.key.isEmpty } }
}

/// A variable stored in an environment, collection, or globals scope.
public struct Variable: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var key: String
    /// Plain value. For secret variables this is empty in persisted form; the value lives in the Keychain.
    public var value: String
    public var isEnabled: Bool
    public var isSecret: Bool

    public init(id: UUID = UUID(), key: String = "", value: String = "", isEnabled: Bool = true, isSecret: Bool = false) {
        self.id = id
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
        self.isSecret = isSecret
    }
}
