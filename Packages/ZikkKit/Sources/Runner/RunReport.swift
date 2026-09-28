import Foundation

/// Serializes run summaries (JSON and JUnit XML, compatible with CI tools).
public enum RunReport {
    public static func json(_ summary: RunSummary, collectionName: String) -> Data {
        let formatter = ISO8601DateFormatter()
        let object: [String: Any] = [
            "collection": collectionName,
            "startedAt": formatter.string(from: summary.startedAt),
            "finishedAt": formatter.string(from: summary.finishedAt),
            "iterations": summary.iterations,
            "totals": [
                "requests": summary.totalRequests, "passedTests": summary.passedTests, "failedTests": summary.failedTests,
                "skippedTests": summary.skippedTests, "errors": summary.errors, "averageResponseTime": summary.averageResponseTime,
            ],
            "results": summary.results.map { result -> [String: Any] in
                var entry: [String: Any] = [
                    "iteration": result.iteration + 1, "name": result.name, "method": result.method, "url": result.url,
                    "responseTime": result.duration, "responseSize": result.responseSize, "skipped": result.skipped,
                    "tests": result.tests.map { ["name": $0.name, "passed": $0.passed, "skipped": $0.skipped, "error": ($0.error as Any?) ?? NSNull()] as [String: Any] },
                ]
                if let code = result.statusCode { entry["status"] = code }
                if let error = result.errorMessage { entry["error"] = error }
                if !result.scriptErrors.isEmpty { entry["scriptErrors"] = result.scriptErrors }
                return entry
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    public static func junit(_ summary: RunSummary, collectionName: String) -> Data {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let totalTests = summary.results.reduce(0) { $0 + max($1.tests.count, 1) }
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += #"<testsuites name="\#(escape(collectionName))" tests="\#(totalTests)" failures="\#(summary.failedTests)" errors="\#(summary.errors)" time="\#(String(format: "%.3f", summary.totalDuration))">"# + "\n"
        for result in summary.results {
            let suiteName = "\(result.name) (iteration \(result.iteration + 1))"
            let failures = result.tests.filter { !$0.passed }.count
            xml += #"  <testsuite name="\#(escape(suiteName))" tests="\#(max(result.tests.count, 1))" failures="\#(failures)" errors="\#(result.errorMessage == nil ? 0 : 1)" time="\#(String(format: "%.3f", result.duration / 1000))">"# + "\n"
            if let error = result.errorMessage {
                xml += #"    <testcase name="\#(escape(result.method + " " + result.url))" classname="\#(escape(result.name))"><error message="\#(escape(error))"/></testcase>"# + "\n"
            } else if result.tests.isEmpty {
                xml += #"    <testcase name="\#(escape(result.method + " " + result.url))" classname="\#(escape(result.name))"/>"# + "\n"
            }
            for test in result.tests {
                xml += #"    <testcase name="\#(escape(test.name))" classname="\#(escape(result.name))""#
                if test.skipped {
                    xml += "><skipped/></testcase>\n"
                } else if !test.passed {
                    xml += #"><failure message="\#(escape(test.error ?? "failed"))"/></testcase>"# + "\n"
                } else {
                    xml += "/>\n"
                }
            }
            xml += "  </testsuite>\n"
        }
        xml += "</testsuites>\n"
        return Data(xml.utf8)
    }
}
