import Testing
import Foundation
import APICore
import HTTPEngine
import HTTPServer
import Execution
@testable import Runner

@Suite struct DatasetParserTests {
    @Test func csvWithQuotesAndNewlines() throws {
        let table = try DatasetParser.parseCSV("\u{FEFF}name,note,age\r\n\"Doe, John\",\"said \"\"hi\"\"\nthen left\",30\nJane,,\n")
        #expect(table.columns == ["name", "note", "age"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0]["name"] == "Doe, John")
        #expect(table.rows[0]["note"] == "said \"hi\"\nthen left")
        #expect(table.rows[1]["age"] == "")
        #expect(try DatasetParser.parseCSV(DatasetParser.csv(table)) == table)
    }

    @Test func jsonArray() throws {
        let table = try DatasetParser.parse(#"[{"id": 1, "ok": true, "tags": ["a"]}, {"id": 2, "extra": null}]"#)
        #expect(table.columns == ["id", "ok", "tags", "extra"])
        #expect(table.rows[0]["ok"] == "true")
        #expect(table.rows[0]["tags"] == #"["a"]"#)
        #expect(table.rows[1]["extra"] == "")
    }

    @Test func errors() {
        #expect(throws: DatasetParser.Failure.invalidJSON) { try DatasetParser.parse("[1, 2]") }
        #expect(throws: DatasetParser.Failure.unterminatedQuote(line: 2)) { try DatasetParser.parseCSV("a\n\"open") }
    }
}

/// Counts hits per path on a local server.
final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [String] = []
    func record(_ path: String) { lock.withLock { hits.append(path) } }
    var all: [String] { lock.withLock { hits } }
}

@Suite struct CollectionRunnerTests {
    func server(_ counter: HitCounter) async throws -> (HTTPServer, String) {
        let server = HTTPServer { request in
            counter.record(request.target)
            if request.path == "/fail" { return ServerResponse(status: 500, text: "boom") }
            return .json(["path": request.path, "query": request.query ?? ""])
        }
        let port = try await server.start()
        return (server, "http://127.0.0.1:\(port)")
    }

    func item(_ name: String, _ url: String, pre: String = "", test: String = "") -> RunnerItem {
        RunnerItem(id: name, name: name, request: ExecutionRequest(spec: RequestSpec(url: url, preRequestScript: pre, testScript: test), name: name))
    }

    @Test func iteratesOverDataRows() async throws {
        let counter = HitCounter()
        let (server, base) = try await server(counter)
        defer { server.stop() }
        let items = [
            item("Search", base + "/search?q={{term}}", test: "pm.test('echo', () => pm.expect(pm.response.json().query).to.eql('q=' + pm.iterationData.get('term')));"),
            item("Count", base + "/count", test: "pm.environment.set('count', String(Number(pm.environment.get('count') || 0) + 1));"),
        ]
        let data = DataTable(columns: ["term"], rows: [["term": "a"], ["term": "b"], ["term": "c"]])
        let summary = await CollectionRunner(executor: RequestExecutor(client: HTTPClient())).run(items, scopes: VariableScopes(), configuration: RunConfiguration(data: data))
        #expect(summary.iterations == 3)
        #expect(counter.all == ["/search?q=a", "/count", "/search?q=b", "/count", "/search?q=c", "/count"])
        #expect(summary.passedTests == 3)
        #expect(summary.failedTests == 0)
        #expect(summary.scopes.environment.first { $0.key == "count" }?.value == "3")
    }

    @Test func setNextRequestJumpsAndStops() async throws {
        let counter = HitCounter()
        let (server, base) = try await server(counter)
        defer { server.stop() }
        let items = [
            item("A", base + "/a", test: "postman.setNextRequest('C');"),
            item("B", base + "/b"),
            item("C", base + "/c", test: "postman.setNextRequest(null);"),
            item("D", base + "/d"),
        ]
        let summary = await CollectionRunner(executor: RequestExecutor(client: HTTPClient())).run(items, scopes: VariableScopes(), configuration: RunConfiguration(iterations: 2))
        #expect(counter.all == ["/a", "/c", "/a", "/c"])
        #expect(summary.results.count == 4)
    }

    @Test func stopOnFailure() async throws {
        let counter = HitCounter()
        let (server, base) = try await server(counter)
        defer { server.stop() }
        let items = [
            item("ok", base + "/ok"),
            item("fail", base + "/fail", test: "pm.test('status', () => pm.response.to.have.status(200));"),
            item("never", base + "/never"),
        ]
        let summary = await CollectionRunner(executor: RequestExecutor(client: HTTPClient())).run(items, scopes: VariableScopes(), configuration: RunConfiguration(iterations: 3, stopOnFailure: true))
        #expect(counter.all == ["/ok", "/fail"])
        #expect(summary.failedTests == 1)

        let json = String(decoding: RunReport.json(summary, collectionName: "C"), as: UTF8.self)
        #expect(json.contains(#""failedTests" : 1"#))
        let junit = String(decoding: RunReport.junit(summary, collectionName: "C & D"), as: UTF8.self)
        #expect(junit.contains(#"<testsuites name="C &amp; D""#))
        #expect(junit.contains(#"<failure message="expected response to have status code 200 but got 500"/>"#))
    }

    @Test func cancellation() async throws {
        let counter = HitCounter()
        let (server, base) = try await server(counter)
        defer { server.stop() }
        let task = Task {
            await CollectionRunner(executor: RequestExecutor(client: HTTPClient()))
                .run([item("slow", base + "/x")], scopes: VariableScopes(), configuration: RunConfiguration(iterations: 1000, delay: .milliseconds(20)))
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let summary = await task.value
        #expect(summary.cancelled)
        #expect(summary.results.count < 1000)
    }

    @Test func performanceMetrics() async throws {
        let counter = HitCounter()
        let (server, base) = try await server(counter)
        defer { server.stop() }
        let metrics = await PerformanceRunner(executor: RequestExecutor(client: HTTPClient()))
            .run([item("a", base + "/a"), item("fail", base + "/fail")], scopes: VariableScopes(),
                 configuration: PerformanceConfiguration(virtualUsers: 4, duration: .milliseconds(400)))
        #expect(metrics.totalRequests > 4)
        #expect(metrics.errorRate > 0.2 && metrics.errorRate < 0.8)
        #expect(metrics.percentile(50) <= metrics.percentile(95))
        #expect(metrics.throughput > 0)

        let fixed = PerformanceMetrics(samples: (1...100).map { PerformanceSample(time: Double($0), responseTime: Double($0), failed: false) }, elapsed: 10)
        #expect(fixed.percentile(50) == 50)
        #expect(fixed.percentile(95) == 95)
        #expect(fixed.throughput == 10)
    }
}
