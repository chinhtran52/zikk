import Foundation
import APICore
import ScriptEngine
import Execution

/// One request in a run, in execution order.
public struct RunnerItem: Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Request with inherited scripts/auth. Iteration fields are filled in by the runner.
    public var request: ExecutionRequest

    public init(id: String, name: String, request: ExecutionRequest) {
        self.id = id
        self.name = name
        self.request = request
    }
}

public struct RunConfiguration: Sendable {
    /// Iterations to run; when data is supplied and this is nil, one iteration per data row.
    public var iterations: Int?
    public var delay: Duration
    public var data: DataTable?
    /// Stop the run on the first error or failed test.
    public var stopOnFailure: Bool
    /// Keep response bodies in results (memory heavy for large runs).
    public var keepResponses: Bool

    public init(iterations: Int? = nil, delay: Duration = .zero, data: DataTable? = nil, stopOnFailure: Bool = false, keepResponses: Bool = true) {
        self.iterations = iterations
        self.delay = delay
        self.data = data
        self.stopOnFailure = stopOnFailure
        self.keepResponses = keepResponses
    }

    public var iterationCount: Int {
        max(1, iterations ?? (data.map { max($0.rows.count, 1) } ?? 1))
    }
}

public struct RunItemResult: Sendable, Identifiable {
    public var id = UUID()
    public var iteration: Int
    public var itemID: String
    public var name: String
    public var method: String
    public var url: String
    public var statusCode: Int?
    public var duration: Double
    public var responseSize: Int
    public var tests: [TestResult]
    public var errorMessage: String?
    public var scriptErrors: [String]
    public var skipped: Bool
    public var response: ResponseSnapshot?
    public var request: RequestSpec

    public var failed: Bool { errorMessage != nil || !scriptErrors.isEmpty || tests.contains { !$0.passed } }
}

public struct RunSummary: Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var iterations: Int
    public var results: [RunItemResult]
    public var cancelled: Bool
    public var scopes: VariableScopes

    public var totalRequests: Int { results.filter { !$0.skipped }.count }
    public var passedTests: Int { results.flatMap(\.tests).filter { $0.passed && !$0.skipped }.count }
    public var failedTests: Int { results.flatMap(\.tests).filter { !$0.passed }.count }
    public var skippedTests: Int { results.flatMap(\.tests).filter(\.skipped).count }
    public var errors: Int { results.filter { $0.errorMessage != nil }.count }
    public var totalDuration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    public var averageResponseTime: Double {
        let durations = results.filter { $0.statusCode != nil }.map(\.duration)
        return durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
    }
}

public enum RunEvent: Sendable {
    case iterationStarted(Int)
    case itemStarted(iteration: Int, itemID: String)
    case itemFinished(RunItemResult)
}

/// Runs a sequence of requests for several iterations, honoring `postman.setNextRequest`.
public struct CollectionRunner: Sendable {
    public var executor: RequestExecutor

    public init(executor: RequestExecutor) {
        self.executor = executor
    }

    public func run(_ items: [RunnerItem], scopes initialScopes: VariableScopes, configuration: RunConfiguration,
                    onEvent: @escaping @Sendable (RunEvent) async -> Void = { _ in }) async -> RunSummary {
        var scopes = initialScopes
        var results: [RunItemResult] = []
        let started = Date()
        let iterationCount = configuration.iterationCount
        var cancelled = false


        iterations: for iteration in 0..<iterationCount {
            await onEvent(.iterationStarted(iteration))
            let row = configuration.data.flatMap { table -> [KeyValue]? in
                guard !table.rows.isEmpty else { return nil }
                let values = table.rows[iteration % table.rows.count]
                return table.columns.map { KeyValue(key: $0, value: values[$0] ?? "") }
            } ?? []
            scopes.data = row

            var index = 0
            var executedInIteration = 0
            // Guard against setNextRequest loops that never end.
            let maxSteps = max(items.count * 100, 1000)
            while index < items.count {
                if Task.isCancelled { cancelled = true; break iterations }
                if executedInIteration >= maxSteps { break }
                let item = items[index]
                await onEvent(.itemStarted(iteration: iteration, itemID: item.id))

                var request = item.request
                request.iteration = iteration
                request.iterationCount = iterationCount
                scopes.local = []
                let execution = await executor.execute(request, scopes: scopes)
                scopes = execution.scopes
                scopes.local = []
                executedInIteration += 1

                let result = RunItemResult(
                    iteration: iteration, itemID: item.id, name: item.name, method: execution.request.method.rawValue, url: execution.resolvedURL,
                    statusCode: execution.response?.statusCode, duration: execution.response?.timings.total ?? 0,
                    responseSize: execution.response?.size ?? 0, tests: execution.tests, errorMessage: execution.errorMessage,
                    scriptErrors: execution.scriptErrors, skipped: execution.skipped,
                    response: configuration.keepResponses ? execution.response : nil, request: execution.request
                )
                results.append(result)
                await onEvent(.itemFinished(result))

                if configuration.stopOnFailure && result.failed { break iterations }

                switch execution.nextRequest {
                case .stop:
                    index = items.count
                case .named(let name):
                    if let target = items.firstIndex(where: { $0.name == name }) { index = target } else { index = items.count }
                case nil:
                    index += 1
                }
                if configuration.delay > .zero, index < items.count || iteration < iterationCount - 1 {
                    try? await Task.sleep(for: configuration.delay)
                }
            }
        }
        return RunSummary(startedAt: started, finishedAt: Date(), iterations: iterationCount, results: results, cancelled: cancelled, scopes: scopes)
    }
}
