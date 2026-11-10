import XCTest

final class HorizonAppearanceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testRussianScreensInBothThemes() throws {
        for dark in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-mode", "--insights-fixture", "--charts-fixture",
                                   dark ? "--ui-test-force-dark-mode" : "--ui-test-force-light-mode",
                                   "-AppleLanguages", "(ru)", "-AppleLocale", "ru"]
            app.launch()
            XCTAssertTrue(app.scrollViews["today-scroll"].waitForExistence(timeout: 5))
            let sleepGauge = app.buttons["today-ring-sleep"]
            XCTAssertTrue(sleepGauge.label.contains("Эффективность сна"))
            XCTAssertEqual(app.staticTexts["today-ring-caption-sleep"].label, "Сон")
            capture("Horizon Today \(dark ? "dark" : "light")", app)
            app.tabBars.buttons["Сон"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["domain-hero-sleep"].firstMatch.waitForExistence(timeout: 5))
            capture("Horizon Sleep \(dark ? "dark" : "light")", app)
            let structure = app.staticTexts["Структура сна"].firstMatch
            for _ in 0..<6 {
                if structure.isHittable && structure.frame.minY < app.frame.midY { break }
                app.swipeUp()
            }
            XCTAssertTrue(structure.isHittable)
            capture("Horizon Sleep structure \(dark ? "dark" : "light")", app)
            app.tabBars.buttons["Тренды"].tap()
            let summary = app.staticTexts["readiness-summary-title"]
            XCTAssertTrue(summary.waitForExistence(timeout: 5))
            capture("Horizon Trends \(dark ? "dark" : "light")", app)
            let lastRow = app.staticTexts["Кардио"].firstMatch
            for _ in 0..<6 {
                if lastRow.isHittable && lastRow.frame.maxY <= app.tabBars.firstMatch.frame.minY { break }
                app.swipeUp()
            }
            XCTAssertTrue(lastRow.isHittable)
            XCTAssertLessThanOrEqual(lastRow.frame.maxY, app.tabBars.firstMatch.frame.minY)
            capture("Horizon Trends bottom \(dark ? "dark" : "light")", app)
            app.terminate()
        }
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
