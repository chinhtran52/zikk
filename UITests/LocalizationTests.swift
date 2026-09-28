import XCTest

@MainActor
final class LocalizationTests: XCTestCase {
    func testVietnameseUI() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN"]
        app.launch()
        let newRequest = app.buttons["Request mới"].firstMatch
        XCTAssertTrue(newRequest.waitForExistence(timeout: 10))
        newRequest.click()
        XCTAssertTrue(app.buttons["send-button"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["send-button"].label, "Gửi")
    }
}
