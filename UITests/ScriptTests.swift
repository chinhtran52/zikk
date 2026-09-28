import XCTest
import HTTPServer

@MainActor
final class ScriptTests: XCTestCase {
    func testPostResponseScriptProducesTestResults() async throws {
        let server = HTTPServer { _ in .json(["ok": true]) }
        let port = try await server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.typeKey("t", modifierFlags: .command)
        let url = app.textFields["url-field"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.click()
        url.typeText("http://127.0.0.1:\(port)/check")

        app.buttons["Scripts"].firstMatch.click()
        app.radioButtons["Post-response"].firstMatch.click()
        let editor = app.textViews["test-script-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("pm.test('ok flag', () => pm.expect(pm.response.json().ok).to.be.true);")

        app.buttons["send-button"].click()
        XCTAssertTrue(app.staticTexts["response-status"].waitForExistence(timeout: 30))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Test Results")).firstMatch.click()
        XCTAssertTrue(app.staticTexts["ok flag"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["PASS"].exists)
    }
}
