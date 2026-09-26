import XCTest

final class ChartLayoutUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testRussianSleepRanges() throws { checkSleep(large: false) }

    @MainActor
    func testRussianSleepLargeText() throws { checkSleep(large: true) }

    @MainActor
    func testTrendsAndSectionCharts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode", "--insights-fixture", "--charts-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        app.launch()
        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(app.buttons["90d"].waitForExistence(timeout: 5))
        app.buttons["90d"].tap()
        capture("Readiness 90 days", app)
        let recovery = app.staticTexts["Recovery"].firstMatch
        reveal(recovery, in: app)
        recovery.tap()
        XCTAssertTrue(app.buttons["90d"].waitForExistence(timeout: 5))
        app.buttons["90d"].tap()
        reveal(app.staticTexts["Sleep stages"], in: app)
        capture("Section sleep chart", app)
        reveal(app.staticTexts["Daily steps"], in: app)
        capture("Section daily bars", app)
        app.terminate()
    }

    @MainActor
    private func checkSleep(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode", "--insights-fixture", "--charts-fixture", "--ui-test-force-dark-mode",
                               "-AppleLanguages", "(ru)", "-AppleLocale", "ru"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        app.tabBars.buttons["Сон"].tap()
        let structure = app.staticTexts["Структура сна"]
        reveal(structure, in: app)
        capture("Sleep structure \(large ? "large" : "normal")", app)
        let picker = app.buttons["sleep-range-90"]
        for _ in 0..<24 {
            if picker.isHittable && picker.frame.midY < app.tabBars.firstMatch.frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(picker.isHittable)
        reveal(app.staticTexts["sleep-trend-title"], in: app)
        for days in [90, 7, 30] {
            app.buttons["sleep-range-\(days)"].tap()
            capture("Sleep \(days) days \(large ? "large" : "normal")", app)
            let title = app.staticTexts["sleep-trend-title"]
            XCTAssertGreaterThanOrEqual(title.frame.minX, 30, "Chart title needs an inset inside the rounded card")
            XCTAssertLessThanOrEqual(picker.frame.maxX, app.frame.width - 30)
            XCTAssertFalse(title.frame.intersects(picker.frame), "Range control must not overlap title")
        }
        let awake = app.descendants(matching: .any)["stage-legend-Awake"].firstMatch
        reveal(awake, in: app)
        XCTAssertGreaterThanOrEqual(awake.frame.minX, 30)
        XCTAssertLessThanOrEqual(awake.frame.maxX, app.frame.width - 30)
        capture("Sleep legend \(large ? "large" : "normal")", app)
        app.terminate()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<24 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        let offset = element.frame.minY - 140
        if offset > 40 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: min(app.frame.height - 130, 140 + offset)))
            let end = start.withOffset(CGVector(dx: 0, dy: -min(offset, app.frame.height - 270)))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
