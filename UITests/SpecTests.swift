import XCTest

@MainActor
final class SpecTests: XCTestCase {
    func testNewSpecValidatesAndReportsErrors() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.radioButtons["APIs"].firstMatch.click()
        app.buttons["New API Spec"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Valid"].waitForExistence(timeout: 5))

        // Break the document: remove the version and add an undeclared path parameter.
        let editor = app.textViews["spec-editor"].firstMatch
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("openapi: 3.0.3\ninfo:\ntitle: X\npaths:\n/items/{id}:\nget:\nresponses:\n'200':\ndescription: ok\n")
        let diagnostic = app.buttons.matching(NSPredicate(format: "identifier == 'spec-diagnostic' AND label CONTAINS 'info.version'")).firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 10))
        XCTAssertTrue(diagnostic.label.hasSuffix("Line 2"))
    }
}
