import XCTest
import HTTPServer

@MainActor
final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    func testLaunchShowsEmptyWorkspace() throws {
        XCTAssertTrue(app.buttons["New Request"].firstMatch.waitForExistence(timeout: 10))
    }

    func testSendRequestShowsResponse() async throws {
        let server = HTTPServer { request in
            .json(["path": request.path, "method": request.method])
        }
        let port = try await server.start()
        defer { server.stop() }

        app.typeKey("t", modifierFlags: .command)
        let url = app.textFields["url-field"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.click()
        url.typeText("http://127.0.0.1:\(port)/hello?x=1")
        app.buttons["send-button"].click()

        let status = app.staticTexts["response-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertTrue((status.value as? String ?? status.label).hasPrefix("200"))
    }
}
