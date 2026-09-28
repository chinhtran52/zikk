import Foundation
import Execution

public struct PerformanceConfiguration: Sendable {
    public var virtualUsers: Int
    public var duration: Duration
    /// Time over which virtual users are started (0 = all at once).
    public var rampUp: Duration

    public init(virtualUsers: Int = 10, duration: Duration = .seconds(30), rampUp: Duration = .zero) {
        self.virtualUsers = max(1, virtualUsers)
        self.duration = duration
        self.rampUp = rampUp
    }
}

public struct PerformanceSample: Sendable, Hashable {
    /// Seconds since the test started.
    public var time: Double
    public var responseTime: Double
    public var failed: Bool
}

public struct PerformanceMetrics: Sendable {
    public var samples: [PerformanceSample]
    public var elapsed: Double

    public init(samples: [PerformanceSample], elapsed: Double) {
        self.samples = samples.sorted { $0.time < $1.time }
        self.elapsed = elapsed
    }

    public var totalRequests: Int { samples.count }
    public var errorRate: Double { samples.isEmpty ? 0 : Double(samples.filter(\.failed).count) / Double(samples.count) }
    public var throughput: Double { elapsed > 0 ? Double(samples.count) / elapsed : 0 }
    public var average: Double { samples.isEmpty ? 0 : samples.map(\.responseTime).reduce(0, +) / Double(samples.count) }

    /// Nearest-rank percentile of response times (p in 0...100).
    public func percentile(_ p: Double) -> Double {
        let sorted = samples.map(\.responseTime).sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// Load test: each virtual user loops over the items until the duration elapses.
public struct PerformanceRunner: Sendable {
    public var executor: RequestExecutor

    public init(executor: RequestExecutor) {
        self.executor = executor
    }

    public func run(_ items: [RunnerItem], scopes: VariableScopes, configuration: PerformanceConfiguration,
                    onSample: @escaping @Sendable (PerformanceSample) async -> Void = { _ in }) async -> PerformanceMetrics {
        guard !items.isEmpty else { return PerformanceMetrics(samples: [], elapsed: 0) }
        let clock = ContinuousClock()
        let start = clock.now
        let end = start + configuration.duration
        let executor = executor
        let samples = await withTaskGroup(of: [PerformanceSample].self) { group in
            for user in 0..<configuration.virtualUsers {
                let offset = configuration.rampUp / configuration.virtualUsers * user
                group.addTask {
                    try? await Task.sleep(for: offset)
                    var collected: [PerformanceSample] = []
                    var userScopes = scopes
                    var index = user % items.count
                    while clock.now < end, !Task.isCancelled {
                        let result = await executor.execute(items[index].request, scopes: userScopes)
                        userScopes = result.scopes
                        userScopes.local = []
                        let elapsed = start.duration(to: clock.now)
                        let sample = PerformanceSample(
                            time: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                            responseTime: result.response?.timings.total ?? 0,
                            failed: result.errorMessage != nil || result.response.map { $0.statusCode >= 400 } ?? true || result.failedCount > 0
                        )
                        collected.append(sample)
                        await onSample(sample)
                        index = (index + 1) % items.count
                    }
                    return collected
                }
            }
            var all: [PerformanceSample] = []
            for await chunk in group { all += chunk }
            return all
        }
        let elapsed = start.duration(to: clock.now)
        return PerformanceMetrics(samples: samples, elapsed: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
}
