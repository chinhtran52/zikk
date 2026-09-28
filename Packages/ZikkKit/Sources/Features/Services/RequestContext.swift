import Foundation
import SwiftData
import APICore
import APIStore
import HTTPEngine
import Execution

/// Everything needed to resolve and send a request: variable scopes, inherited auth and scripts.
@MainActor
struct RequestContext {
    var scopes: VariableScopes
    /// Collection and folder auth, outermost first.
    var parentAuth: [AuthConfig]
    var parentPreRequestScripts: [String]
    var parentTestScripts: [String]
    let node: CollectionNode?

    init(spec: RequestSpec, node: CollectionNode?, workspace: Workspace, secrets: any SecretStore, data: [KeyValue] = []) {
        self.node = node
        let collection = node?.collection
        let folders = node?.ancestors ?? []
        let environment = workspace.activeEnvironment
        scopes = VariableScopes(
            globals: SecretVariables.load(workspace.globals, scope: workspace.id, store: secrets),
            collection: collection.map { SecretVariables.load($0.variables, scope: $0.id, store: secrets) } ?? [],
            environment: environment.map { SecretVariables.load($0.variables, scope: $0.id, store: secrets) } ?? [],
            data: data,
            environmentName: environment?.name ?? ""
        )
        parentAuth = (collection.map { [$0.auth] } ?? []) + folders.map(\.auth)
        parentPreRequestScripts = [collection?.preRequestScript ?? ""] + folders.map(\.preRequestScript)
        parentTestScripts = [collection?.testScript ?? ""] + folders.map(\.testScript)
    }

    var resolver: VariableResolver { scopes.resolver }

    func effectiveAuth(for spec: RequestSpec) -> AuthConfig {
        AuthConfig.effective(chain: parentAuth + [spec.auth])
    }

    func builder(for spec: RequestSpec) -> RequestBuilder {
        RequestBuilder(resolver: resolver, auth: effectiveAuth(for: spec))
    }

    func executionRequest(spec: RequestSpec, name: String, cookies: [(name: String, value: String)] = [], iteration: Int = 0, iterationCount: Int = 1) -> ExecutionRequest {
        ExecutionRequest(spec: spec, name: name, id: node?.id.uuidString ?? "", parentAuth: parentAuth, parentPreRequestScripts: parentPreRequestScripts,
                         parentTestScripts: parentTestScripts, iteration: iteration, iterationCount: iterationCount, cookies: cookies)
    }

    /// Writes script changes to variables back to the store (secrets go to the Keychain).
    static func persist(_ updated: VariableScopes, original: VariableScopes, workspace: Workspace, collection: APICollection?, secrets: any SecretStore) {
        if updated.globals != original.globals {
            workspace.globals = SecretVariables.save(updated.globals, previous: workspace.globals, scope: workspace.id, store: secrets)
        }
        if updated.environment != original.environment, let environment = workspace.activeEnvironment {
            environment.variables = SecretVariables.save(updated.environment, previous: environment.variables, scope: environment.id, store: secrets)
        }
        if updated.collection != original.collection, let collection {
            collection.variables = SecretVariables.save(updated.collection, previous: collection.variables, scope: collection.id, store: secrets)
        }
    }
}
