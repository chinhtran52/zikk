import Foundation
import Observation
import SwiftData
import APICore
import APIStore
import Execution
import Runner
import ScriptEngine

/// State of one Collection Runner tab.
@MainActor
@Observable
final class RunnerModel {
    struct Selection: Identifiable, Hashable {
        let id: UUID
        var name: String
        var path: String
        var method: HTTPMethod
        var kind: RequestKind
        var isSelected = true
    }

    enum Mode: Hashable { case functional, performance }
    enum State: Equatable { case idle, running, finished }

    let collectionID: UUID
    let folderID: UUID?
    var mode: Mode = .functional
    var selections: [Selection] = []

    // Functional configuration.
    var iterations = 1
    var delayMilliseconds = 0
    var datasetID: UUID?
    var stopOnFailure = false
    var keepResponses = true
    var persistVariables = true

    // Performance configuration.
    var virtualUsers = 10
    var durationSeconds = 30
    var rampUpSeconds = 0

    private(set) var state: State = .idle
    private(set) var results: [RunItemResult] = []
    private(set) var summary: RunSummary?
    private(set) var currentIteration = 0
    private(set) var samples: [PerformanceSample] = []
    private(set) var metrics: PerformanceMetrics?
    private(set) var startedAt: Date?
    private var task: Task<Void, Never>?

    init(collectionID: UUID, folderID: UUID?) {
        self.collectionID = collectionID
        self.folderID = folderID
    }

    /// Loads the requests of the collection (or folder) in depth-first order.
    func load(context: ModelContext) {
        guard let collection = CollectionQueries.collection(collectionID, in: context) else { return }
        let roots = folderID.flatMap { CollectionQueries.node($0, in: context) }.map { [$0] } ?? collection.rootNodes
        var result: [Selection] = []
        func visit(_ node: CollectionNode, path: [String]) {
            if node.isFolder {
                for child in node.sortedChildren ?? [] { visit(child, path: path + [node.name]) }
            } else {
                let spec = node.request
                result.append(Selection(id: node.id, name: node.name, path: path.joined(separator: " / "), method: spec.method, kind: spec.kind))
            }
        }
        roots.forEach { visit($0, path: []) }
        let previous = Dictionary(uniqueKeysWithValues: selections.map { ($0.id, $0.isSelected) })
        selections = result.map { var s = $0; s.isSelected = previous[s.id] ?? true; return s }
    }

    var isRunning: Bool { state == .running }

    func move(from source: IndexSet, to destination: Int) {
        selections.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: Running

    private func runnerItems(workspace: Workspace, context: ModelContext, services: AppServices) -> (items: [RunnerItem], scopes: VariableScopes, collection: APICollection?)? {
        let nodes = selections.filter(\.isSelected).compactMap { CollectionQueries.node($0.id, in: context) }
        guard let first = nodes.first else { return nil }
        let base = RequestContext(spec: first.request, node: first, workspace: workspace, secrets: services.secrets)
        let items = nodes.map { node -> RunnerItem in
            let requestContext = RequestContext(spec: node.request, node: node, workspace: workspace, secrets: services.secrets)
            return RunnerItem(id: node.id.uuidString, name: node.name, request: requestContext.executionRequest(spec: services.applyDefaults(to: node.request), name: node.name))
        }
        return (items, base.scopes, first.collection)
    }

    func run(workspace: Workspace, context: ModelContext, services: AppServices) {
        guard !isRunning, let (items, scopes, collection) = runnerItems(workspace: workspace, context: context, services: services) else { return }
        let dataTable = datasetID.flatMap { id in workspace.datasets.first { $0.id == id } }.map { DataTable(columns: $0.columns, rows: $0.rows) }
        let configuration = RunConfiguration(iterations: dataTable == nil ? iterations : (iterations > 1 ? iterations : nil),
                                             delay: .milliseconds(delayMilliseconds), data: dataTable, stopOnFailure: stopOnFailure, keepResponses: keepResponses)
        let runner = CollectionRunner(executor: RequestExecutor(client: services.httpClient,
                                                                responseValidator: SpecServices.responseValidator(for: collection, in: workspace)))
        results = []
        summary = nil
        currentIteration = 0
        state = .running
        startedAt = .now
        let persist = persistVariables
        task = Task {
            let summary = await runner.run(items, scopes: scopes, configuration: configuration) { event in
                await self.handle(event, console: services.console)
            }
            self.summary = summary
            self.state = .finished
            if persist {
                RequestContext.persist(summary.scopes, original: scopes, workspace: workspace, collection: collection, secrets: services.secrets)
                try? context.save()
            }
        }
    }

    private func handle(_ event: RunEvent, console: ConsoleStore) {
        switch event {
        case .iterationStarted(let iteration):
            currentIteration = iteration
        case .itemStarted:
            break
        case .itemFinished(let result):
            results.append(result)
            console.record(requestName: result.name, method: result.method, url: result.url, response: result.response,
                           error: result.errorMessage, logs: [])
        }
    }

    func runPerformance(workspace: Workspace, context: ModelContext, services: AppServices) {
        guard !isRunning, let (items, scopes, _) = runnerItems(workspace: workspace, context: context, services: services) else { return }
        let configuration = PerformanceConfiguration(virtualUsers: virtualUsers, duration: .seconds(durationSeconds), rampUp: .seconds(rampUpSeconds))
        let runner = PerformanceRunner(executor: RequestExecutor(client: services.httpClient))
        samples = []
        metrics = nil
        state = .running
        startedAt = .now
        task = Task {
            let metrics = await runner.run(items, scopes: scopes, configuration: configuration) { sample in
                await self.appendSample(sample)
            }
            self.metrics = metrics
            self.state = .finished
        }
    }

    private func appendSample(_ sample: PerformanceSample) {
        samples.append(sample)
    }

    /// Metrics computed from samples received so far (live while running).
    var liveMetrics: PerformanceMetrics {
        metrics ?? PerformanceMetrics(samples: samples, elapsed: startedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    func stop() {
        task?.cancel()
        task = nil
        if state == .running { state = .finished }
    }

    func report(json: Bool, collectionName: String) -> Data? {
        guard let summary else { return nil }
        return json ? RunReport.json(summary, collectionName: collectionName) : RunReport.junit(summary, collectionName: collectionName)
    }
}
