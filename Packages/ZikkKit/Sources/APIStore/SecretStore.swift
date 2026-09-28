import Foundation
import Security
import APICore

/// Stores secret variable values outside the database.
public protocol SecretStore: Sendable {
    func value(for key: String) -> String?
    func setValue(_ value: String?, for key: String)
}

extension SecretStore {
    /// Key for a secret variable within a scope (environment, collection or globals).
    public static func key(scope: UUID, variable: UUID) -> String { "\(scope.uuidString).\(variable.uuidString)" }
}

/// Keychain-backed secret store (generic passwords, one item per secret).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = Branding.bundleIdentifier + ".secrets") {
        self.service = service
    }

    public func value(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setValue(_ value: String?, for key: String) {
        let query = baseQuery(key)
        guard let value else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}

/// In-memory secret store for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func value(for key: String) -> String? { lock.withLock { storage[key] } }
    public func setValue(_ value: String?, for key: String) { lock.withLock { storage[key] = value } }
}
