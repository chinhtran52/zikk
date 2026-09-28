import Foundation
import APICore
import HTTPEngine
import ScriptEngine

/// Variable scopes a request executes against. Scripts may modify them.
public struct VariableScopes: Sendable, Equatable {
    public var globals: [Variable]
    public var collection: [Variable]
    public var environment: [Variable]
    public var data: [KeyValue]
    public var local: [KeyValue]
    public var environmentName: String

    public init(globals: [Variable] = [], collection: [Variable] = [], environment: [Variable] = [], data: [KeyValue] = [], local: [KeyValue] = [], environmentName: String = "") {
        self.globals = globals
        self.collection = collection
        self.environment = environment
        self.data = data
        self.local = local
        self.environmentName = environmentName
    }

    public var resolver: VariableResolver {
        VariableResolver(scopes: [globals.asDictionary, collection.asDictionary, environment.asDictionary, data.asDictionary, local.asDictionary])
    }
}

extension Array where Element == KeyValue {
    var asDictionary: [String: String] {
        reduce(into: [:]) { result, row in if row.isEnabled && !row.key.isEmpty { result[row.key] = row.value } }
    }

    var scopeValues: ScopeValues { active.map { ($0.key, $0.value) } }
}

extension Array where Element == Variable {
    var scopeValues: ScopeValues { filter { $0.isEnabled && !$0.key.isEmpty }.map { ($0.key, $0.value) } }
}

/// A request plus the inherited context from its collection and folders.
public struct ExecutionRequest: Sendable {
    public var spec: RequestSpec
    public var name: String
    public var id: String
    /// Auth of the collection and folders, outermost first (the request's own auth comes from `spec`).
    public var parentAuth: [AuthConfig]
    /// Collection and folder pre-request scripts, outermost first.
    public var parentPreRequestScripts: [String]
    /// Collection and folder test scripts, outermost first.
    public var parentTestScripts: [String]
    public var iteration: Int
    public var iterationCount: Int
    public var cookies: [(name: String, value: String)]

    public init(spec: RequestSpec, name: String = "", id: String = "", parentAuth: [AuthConfig] = [], parentPreRequestScripts: [String] = [], parentTestScripts: [String] = [],
                iteration: Int = 0, iterationCount: Int = 1, cookies: [(name: String, value: String)] = []) {
        self.spec = spec
        self.name = name
        self.id = id
        self.parentAuth = parentAuth
        self.parentPreRequestScripts = parentPreRequestScripts
        self.parentTestScripts = parentTestScripts
        self.iteration = iteration
        self.iterationCount = iterationCount
        self.cookies = cookies
    }
}

public struct ExecutionResult: Sendable {
    /// The request after pre-request script changes.
    public var request: RequestSpec
    public var resolvedURL: String
    public var response: ResponseSnapshot?
    /// Build or network failure.
    public var errorMessage: String?
    public var tests: [TestResult]
    public var logs: [ConsoleEntry]
    public var scriptErrors: [String]
    public var scopes: VariableScopes
    public var nextRequest: NextRequest?
    /// Set when a pre-request script called `pm.execution.skipRequest()`.
    public var skipped: Bool
    public var visualizer: (template: String, dataJSON: String)?

    public var passedCount: Int { tests.filter { $0.passed && !$0.skipped }.count }
    public var failedCount: Int { tests.filter { !$0.passed }.count }
}

/// Runs the full request pipeline: pre-request scripts → send → test scripts.
public struct RequestExecutor: Sendable {
    /// Extra checks on each response (e.g. OpenAPI contract tests), reported as test results.
    public typealias ResponseValidator = @Sendable (_ request: RequestSpec, _ resolvedURL: String, _ response: ResponseSnapshot) -> [TestResult]

    public var client: HTTPClient
    public var scriptTimeout: Duration
    public var responseValidator: ResponseValidator?

    public init(client: HTTPClient, scriptTimeout: Duration = .seconds(30), responseValidator: ResponseValidator? = nil) {
        self.client = client
        self.scriptTimeout = scriptTimeout
        self.responseValidator = responseValidator
    }

    public func execute(_ request: ExecutionRequest, scopes initialScopes: VariableScopes) async -> ExecutionResult {
        var scopes = initialScopes
        var spec = request.spec
        var result = ExecutionResult(request: spec, resolvedURL: "", response: nil, errorMessage: nil, tests: [], logs: [], scriptErrors: [],
                                     scopes: scopes, nextRequest: nil, skipped: false, visualizer: nil)
        let engine = ScriptEngine(timeout: scriptTimeout, requestHandler: scriptRequestHandler())
        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Pre-request scripts.
        for script in (request.parentPreRequestScripts + [spec.preRequestScript]) where !isBlank(script) {
            let output = await engine.run(script, input: input(.preRequest, request: request, spec: spec, scopes: scopes, response: nil))
            apply(output, to: &scopes, result: &result)
            spec = output.request
            if output.skipRequest {
                result.skipped = true
                result.request = spec
                result.scopes = scopes
                return result
            }
        }
        result.request = spec

        // Send.
        let auth = AuthConfig.effective(chain: request.parentAuth + [spec.auth])
        let builder = RequestBuilder(resolver: scopes.resolver, auth: auth)
        result.resolvedURL = builder.resolvedURLString(for: spec)
        do {
            let prepared = try builder.build(spec)
            result.resolvedURL = prepared.url.absoluteString
            result.response = try await client.send(prepared)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                result.errorMessage = "Cancelled"
            } else {
                result.errorMessage = error.localizedDescription
            }
            result.scopes = scopes
            return result
        }

        // Test scripts.
        for script in (request.parentTestScripts + [spec.testScript]) where !isBlank(script) {
            let output = await engine.run(script, input: input(.test, request: request, spec: spec, scopes: scopes, response: result.response))
            apply(output, to: &scopes, result: &result)
        }
        if let validator = responseValidator, let response = result.response {
            result.tests += validator(spec, result.resolvedURL, response)
        }
        result.scopes = scopes
        return result
    }

    private func input(_ phase: ScriptPhase, request: ExecutionRequest, spec: RequestSpec, scopes: VariableScopes, response: ResponseSnapshot?) -> ScriptInput {
        ScriptInput(phase: phase, globals: scopes.globals.scopeValues, collection: scopes.collection.scopeValues, environment: scopes.environment.scopeValues,
                    data: scopes.data.scopeValues, local: scopes.local.scopeValues, request: spec, response: response, cookies: request.cookies,
                    requestName: request.name, requestID: request.id, environmentName: scopes.environmentName,
                    iteration: request.iteration, iterationCount: request.iterationCount)
    }

    private func apply(_ output: ScriptOutput, to scopes: inout VariableScopes, result: inout ExecutionResult) {
        scopes.globals = VariableMerge.merge(scopes.globals, with: output.globals)
        scopes.collection = VariableMerge.merge(scopes.collection, with: output.collection)
        scopes.environment = VariableMerge.merge(scopes.environment, with: output.environment)
        scopes.local = output.local.map { KeyValue(key: $0.key, value: $0.value) }
        result.tests += output.tests
        result.logs += output.logs
        if let error = output.error {
            result.scriptErrors.append(error)
            result.logs.append(ConsoleEntry(level: .error, message: error))
        }
        if let next = output.nextRequest { result.nextRequest = next }
        if let visualizer = output.visualizer { result.visualizer = visualizer }
    }

    private func scriptRequestHandler() -> ScriptRequestHandler {
        let client = client
        return { spec in
            let prepared = try RequestBuilder(resolver: VariableResolver(), auth: .none).build(spec)
            return try await client.send(prepared)
        }
    }
}

/// Applies a script's view of a scope back onto the stored variables.
public enum VariableMerge {
    /// Updates values, appends new keys and removes enabled variables the script unset. Disabled variables are kept.
    public static func merge(_ original: [Variable], with output: ScopeValues) -> [Variable] {
        let outputKeys = Set(output.map(\.key))
        var result = original.filter { !$0.isEnabled || outputKeys.contains($0.key) || $0.key.isEmpty }
        for (key, value) in output {
            if let index = result.firstIndex(where: { $0.key == key }) {
                if result[index].value != value || !result[index].isEnabled {
                    result[index].value = value
                    result[index].isEnabled = true
                }
            } else {
                result.append(Variable(key: key, value: value))
            }
        }
        return result
    }
}
