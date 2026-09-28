import Foundation
import Observation
import SwiftData
import APICore
import APIStore
import HTTPEngine
import Interop
import Execution
import ScriptEngine
import RealtimeEngine

/// Editing state for one request tab: the working copy, the last response, and send/save actions.
@MainActor
@Observable
public final class RequestDocument {
    public var name: String
    public private(set) var nodeID: UUID?
    public var spec: RequestSpec
    private var savedSpec: RequestSpec
    private var savedName: String

    public var response: ResponseSnapshot?
    public var errorMessage: String?
    /// WebSocket/SSE connection state.
    let realtime = RealtimeSessionModel()
    /// GraphQL schema from the last introspection.
    var graphQLSchema: GraphQLSchema?
    /// gRPC schema and call state.
    let grpc = GRPCSessionModel()
    public private(set) var isSending = false
    private var sendTask: Task<Void, Never>?

    public init(name: String, spec: RequestSpec = RequestSpec(), nodeID: UUID? = nil) {
        self.name = name
        self.spec = spec
        self.nodeID = nodeID
        self.savedSpec = spec
        self.savedName = name
    }

    public var isDirty: Bool { spec != savedSpec || name != savedName }
    public var isDraft: Bool { nodeID == nil }

    // MARK: URL ↔ params sync

    /// Sets the URL and re-derives query params and path variables from it (Postman behavior).
    public func setURL(_ url: String) {
        if CurlParser.looksLikeCurl(url), let parsed = try? CurlParser.parse(url) {
            // Pasting a cURL command replaces the whole request, keeping scripts.
            var replaced = parsed
            replaced.preRequestScript = spec.preRequestScript
            replaced.testScript = spec.testScript
            spec = replaced
            return
        }
        spec.url = url
        let fromURL = RawURL.queryParams(of: url)
        var merged: [KeyValue] = []
        var previousEnabled = spec.params.filter(\.isEnabled)
        for param in fromURL {
            // Keep ids/descriptions of rows that still exist in the same position.
            if let index = previousEnabled.firstIndex(where: { $0.key == param.key }) {
                var existing = previousEnabled.remove(at: index)
                existing.value = param.value
                merged.append(existing)
            } else {
                merged.append(param)
            }
        }
        spec.params = merged + spec.params.filter { !$0.isEnabled }
        spec.pathVariables = RawURL.syncPathVariables(url: url, existing: spec.pathVariables)
    }

    /// Sets query params and rewrites the URL's query string.
    public func setParams(_ params: [KeyValue]) {
        spec.params = params
        spec.url = RawURL.replacingQuery(of: spec.url, with: params)
    }

    // MARK: Sending

    public private(set) var testResults: [TestResult] = []
    public private(set) var scriptErrors: [String] = []
    public private(set) var visualizer: (template: String, dataJSON: String)?

    func send(workspace: Workspace, node: CollectionNode?, services: AppServices, context: ModelContext) {
        cancel()
        errorMessage = nil
        isSending = true
        let requestContext = RequestContext(spec: spec, node: node, workspace: workspace, secrets: services.secrets)
        let cookies = URL(string: requestContext.builder(for: spec).resolvedURLString(for: spec))
            .map { services.cookieJar.cookies(for: $0).map { (name: $0.name, value: $0.value) } } ?? []
        let execution = requestContext.executionRequest(spec: services.applyDefaults(to: spec), name: name, cookies: cookies)
        let executor = RequestExecutor(client: services.httpClient,
                                       responseValidator: SpecServices.responseValidator(for: node?.collection, in: workspace))
        let originalScopes = requestContext.scopes
        sendTask = Task {
            let result = await executor.execute(execution, scopes: originalScopes)
            guard !Task.isCancelled else { return }
            self.finish(result, originalScopes: originalScopes, workspace: workspace, collection: node?.collection, services: services, context: context)
        }
    }

    private func finish(_ result: ExecutionResult, originalScopes: VariableScopes, workspace: Workspace, collection: APICollection?, services: AppServices, context: ModelContext) {
        isSending = false
        response = result.response
        errorMessage = result.skipped ? L("Request skipped by pre-request script.") : result.errorMessage
        testResults = result.tests
        scriptErrors = result.scriptErrors
        visualizer = result.visualizer
        RequestContext.persist(result.scopes, original: originalScopes, workspace: workspace, collection: collection, secrets: services.secrets)
        services.console.record(requestName: name, method: result.request.method.rawValue, url: result.resolvedURL, response: result.response,
                                error: errorMessage, logs: result.logs)
        guard !result.skipped else { try? context.save(); return }
        let entry = HistoryEntry(request: spec, resolvedURL: result.resolvedURL, response: result.response, errorMessage: result.errorMessage, sourceNodeID: nodeID)
        entry.workspace = workspace
        context.insert(entry)
        HistoryPruner.prune(workspace: workspace, context: context, limit: services.settings.historyLimit)
        if result.response != nil { CookieStore.save(services.cookieJar, context: context) }
        try? context.save()
    }

    public func cancel() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
    }

    /// Cancels in-flight work and closes realtime connections (tab closing).
    func close() {
        cancel()
        realtime.disconnect()
        grpc.cancel()
    }

    // MARK: Saving

    /// Writes the working copy back to its collection node.
    func save(context: ModelContext) {
        guard let nodeID, let node = CollectionQueries.node(nodeID, in: context) else { return }
        node.name = name
        node.request = spec
        try? context.save()
        markSaved()
    }

    /// Attaches a draft to a newly created node.
    func didSaveAsNode(_ node: CollectionNode) {
        nodeID = node.id
        name = node.name
        markSaved()
    }

    private func markSaved() {
        savedSpec = spec
        savedName = name
    }
}

enum HistoryPruner {
    @MainActor
    static func prune(workspace: Workspace, context: ModelContext, limit: Int) {
        let history = workspace.history
        guard history.count > limit else { return }
        history.sorted { $0.date > $1.date }.dropFirst(limit).forEach(context.delete)
    }
}

enum CollectionQueries {
    @MainActor
    static func node(_ id: UUID, in context: ModelContext) -> CollectionNode? {
        var descriptor = FetchDescriptor<CollectionNode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @MainActor
    static func collection(_ id: UUID, in context: ModelContext) -> APICollection? {
        var descriptor = FetchDescriptor<APICollection>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @MainActor
    static func example(_ id: UUID, in context: ModelContext) -> SavedExample? {
        var descriptor = FetchDescriptor<SavedExample>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @MainActor
    static func environment(_ id: UUID, in context: ModelContext) -> APIEnvironment? {
        var descriptor = FetchDescriptor<APIEnvironment>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
