import XCTest

@MainActor
final class MockTests: XCTestCase {
    func testMockServerStartsInsideSandbox() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.radioButtons["Mock Servers"].firstMatch.click()
        app.buttons["New Mock Server"].firstMatch.click()
        let start = app.buttons["mock-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        let url = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'http://127.0.0.1:'")).firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 10))

        // The mock answers (404 JSON, since the collection has no examples yet).
        let address = try XCTUnwrap(url.value as? String)
        let (data, response) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: address + "/anything")))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("mockRequestNotFoundError"))
        XCTAssertTrue(app.staticTexts["/anything"].waitForExistence(timeout: 5))
    }
}
