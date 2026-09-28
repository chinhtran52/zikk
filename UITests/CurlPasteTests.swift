import XCTest
import HTTPServer

/// Captures the last request received by the test server.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ServerRequest?
    func record(_ request: ServerRequest) { lock.withLock { last = request } }
    var request: ServerRequest? { lock.withLock { last } }
}

@MainActor
final class CurlPasteTests: XCTestCase {
    func testPastingCurlBuildsRequest() async throws {
        let log = RequestLog()
        let server = HTTPServer { request in
            log.record(request)
            return ServerResponse(status: 201, text: "created")
        }
        let port = try await server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.typeKey("t", modifierFlags: .command)
        let url = app.textFields["url-field"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.click()
        url.typeText("curl -X POST http://127.0.0.1:\(port)/items -H 'X-Test: yes' -d '{\"a\":1}'")
        app.buttons["send-button"].click()

        let status = app.staticTexts["response-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertTrue((status.value as? String ?? status.label).hasPrefix("201"))
        let received = try XCTUnwrap(log.request)
        XCTAssertEqual(received.method, "POST")
        XCTAssertEqual(received.header("X-Test"), "yes")
        XCTAssertEqual(String(decoding: received.body, as: UTF8.self), #"{"a":1}"#)
        XCTAssertEqual(received.header("Content-Type"), "application/json")
    }
}
