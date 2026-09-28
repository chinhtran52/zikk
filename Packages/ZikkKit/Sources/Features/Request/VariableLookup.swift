import Foundation
import APICore
import APIStore
import DesignSystem

/// Looks up what a `{{variable}}` currently resolves to for the editor (hover popovers, coloring).
///
/// Uses the stored values only: secrets are persisted blank and are shown masked, so the Keychain is never read here.
@MainActor
struct VariableLookup {
    private struct Scope {
        let name: String
        let variables: [Variable]
    }

    /// Highest precedence first.
    private let scopes: [Scope]

    init(workspace: Workspace, node: CollectionNode?) {
        let environment = workspace.activeEnvironment
        var scopes: [Scope] = []
        if let environment {
            scopes.append(Scope(name: "\(L("Environment")) · \(environment.name)", variables: environment.variables))
        }
        if let collection = node?.collection {
            scopes.append(Scope(name: L("Collection"), variables: collection.variables))
        }
        scopes.append(Scope(name: L("Global"), variables: workspace.globals))
        self.scopes = scopes
    }

    func info(for name: String) -> VariableInfo {
        for scope in scopes {
            if let variable = scope.variables.last(where: { $0.isEnabled && $0.key == name }) {
                let resolved = resolver.resolve(variable.value)
                return VariableInfo(name: name, value: variable.value, scope: scope.name, isSecret: variable.isSecret,
                                    resolvedValue: resolved == variable.value ? nil : resolved)
            }
        }
        if DynamicVariables.names.contains(name) {
            return VariableInfo(name: name, value: L("Generated when the request is sent"), scope: L("Dynamic"))
        }
        return VariableInfo(name: name, value: nil)
    }

    private var resolver: VariableResolver {
        VariableResolver(scopes: scopes.reversed().map(\.variables.asDictionary))
    }
}
