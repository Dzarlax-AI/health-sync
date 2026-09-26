import XCTest

final class BackgroundDiagnosticsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testDiagnosticsLight() throws { try checkDiagnostics(dark: false, largeText: false) }

    @MainActor
    func testDiagnosticsDarkLargeText() throws { try checkDiagnostics(dark: true, largeText: true) }

    @MainActor
    private func checkDiagnostics(dark: Bool, largeText: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode", "--background-diagnostics-fixture", "-AppleLanguages", "(en)"]
        if dark { app.launchArguments.append("--ui-test-force-dark-mode") }
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let title = app.staticTexts["background-diagnostics-title"]
        for _ in 0..<10 {
            if title.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(title.isHittable)
        let headerAttachment = XCTAttachment(screenshot: app.screenshot())
        headerAttachment.name = dark ? "Background diagnostics dark large text" : "Background diagnostics light"
        headerAttachment.lifetime = .keepAlways
        add(headerAttachment)
        let pending = app.descendants(matching: .any).matching(identifier: "background-event-locked").firstMatch
        for _ in 0..<10 {
            if pending.isHittable && pending.frame.maxY < app.tabBars.firstMatch.frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(pending.isHittable)
        XCTAssertLessThan(pending.frame.maxY, app.tabBars.firstMatch.frame.minY)
        XCTAssertTrue(pending.label.contains("Waiting for device unlock"))
        let eventAttachment = XCTAttachment(screenshot: app.screenshot())
        eventAttachment.name = dark ? "Background events dark large text" : "Background events light"
        eventAttachment.lifetime = .keepAlways
        add(eventAttachment)
        app.terminate()
    }
}
