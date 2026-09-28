import Foundation
import APICore
import APIStore

/// Moves secret variable values between the database (stored blank) and the `SecretStore`.
enum SecretVariables {
    /// Returns variables with secret values filled in from the store.
    static func load(_ variables: [Variable], scope: UUID, store: any SecretStore) -> [Variable] {
        variables.map { variable in
            guard variable.isSecret else { return variable }
            var filled = variable
            filled.value = store.value(for: storeKey(scope: scope, variable: variable.id)) ?? ""
            return filled
        }
    }

    /// Writes secret values to the store and returns variables safe to persist (secret values blanked).
    static func save(_ variables: [Variable], previous: [Variable], scope: UUID, store: any SecretStore) -> [Variable] {
        let currentIDs = Set(variables.map(\.id))
        for old in previous where old.isSecret && (!currentIDs.contains(old.id) || variables.first(where: { $0.id == old.id })?.isSecret == false) {
            store.setValue(nil, for: storeKey(scope: scope, variable: old.id))
        }
        return variables.map { variable in
            guard variable.isSecret else { return variable }
            store.setValue(variable.value, for: storeKey(scope: scope, variable: variable.id))
            var blank = variable
            blank.value = ""
            return blank
        }
    }

    static func storeKey(scope: UUID, variable: UUID) -> String { "\(scope.uuidString).\(variable.uuidString)" }
}
