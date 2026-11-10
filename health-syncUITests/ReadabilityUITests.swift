import XCTest
import UIKit

final class ReadabilityUITests: XCTestCase {
    private var systemTop: CGFloat = 0
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSystemThemeScrollClippingAndNativeBack() throws {
        let app = launch()
        let sync = element("today-sync-status", app)
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        assertTarget(sync)
        assertDisclosure("overall", app)
        checkScroll("today-scroll", name: "Today", app)
        top("today-scroll", app)

        app.tabBars.buttons["Sleep"].tap()
        XCTAssertTrue(element("domain-hero-sleep", app).waitForExistence(timeout: 5))
        assertDisclosure("sleep", app)
        checkScroll("sleep-scroll", name: "Sleep", app)

        app.tabBars.buttons["Today"].tap()
        element("today-ring-recovery", app).tap()
        XCTAssertTrue(element("domain-hero-recovery", app).waitForExistence(timeout: 5))
        assertBack(app)
        assertDisclosure("recovery", app)
        checkScroll("section-scroll-recovery", name: "Recovery", app)
        app.navigationBars.buttons.firstMatch.tap()

        element("today-ring-energy", app).tap()
        XCTAssertTrue(element("energy-current", app).waitForExistence(timeout: 5))
        assertBack(app)
        assertDisclosure("energy", app)
        checkScroll("energy-scroll", name: "Energy", app)
        app.navigationBars.buttons.firstMatch.tap()

        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(element("readiness-summary-title", app).waitForExistence(timeout: 5))
        checkScroll("trends-scroll", name: "Trends", app, compareLandscape: false)
        app.terminate()
    }

    @MainActor
    func testRussianAccessibilityXXXLAndVoiceOverDescriptions() throws {
        try checkLargeText(locale: "ru", today: "Сегодня", sleep: "Сон")
    }

    @MainActor
    func testSerbianAccessibilityXXXLAndVoiceOverDescriptions() throws {
        try checkLargeText(locale: "sr", today: "Danas", sleep: "San")
    }

    @MainActor
    func testEnglishAccessibilityXXXLAndVoiceOverDescriptions() throws {
        try checkLargeText(locale: "en", today: "Today", sleep: "Sleep")
    }

    @MainActor
    func testTrendsDatesAndComparisonAcrossRangesAndLanguages() throws {
        let cases: [(String, String, String, String, [String])] = [
            ("en", "Trends", "Today’s readiness", "higher than the start of this range", []),
            ("ru", "Тренды", "Последнее значение", "ниже, чем в начале периода", ["--trends-yesterday", "--trends-falling"]),
            ("sr", "Trendovi", "Poslednja vrednost", "Bez promene u odnosu na početak perioda", ["--trends-historical", "--trends-flat"])
        ]
        for (locale, tab, title, comparison, extra) in cases {
            let app = launch(locale: locale, extra: ["--trends-date-fixture"] + extra)
            app.tabBars.buttons[tab].tap()
            let summary = element("readiness-summary-title", app)
            XCTAssertTrue(summary.waitForExistence(timeout: 5))
            XCTAssertEqual(summary.label, title)
            let date = element("readiness-summary-date", app)
            XCTAssertFalse(date.label.isEmpty)
            if extra.contains("--trends-historical") { XCTAssertTrue(date.label.contains("2024")) }
            let dateLabel = date.label
            let buttons = app.segmentedControls.buttons
            XCTAssertEqual(buttons.count, 3)
            for index in [0, 2, 1] {
                buttons.element(boundBy: index).tap()
                XCTAssertTrue(element("readiness-comparison", app).label.contains(comparison))
                XCTAssertEqual(summary.label, title)
                XCTAssertEqual(date.label, dateLabel)
            }
            capture("Trends dates and comparison \(locale)", app)
            app.terminate()
        }
    }

    @MainActor
    private func checkLargeText(locale: String, today: String, sleep: String) throws {
        let app = launch(locale: locale, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let energy = element("today-ring-energy", app)
        XCTAssertTrue(energy.waitForExistence(timeout: 5))
        XCTAssertTrue(energy.label.contains(locale == "ru" ? "Энергия" : locale == "sr" ? "Energija" : "Energy"))
        XCTAssertTrue((energy.value as? String)?.contains("58") == true)
        capture("Today Accessibility XXXL \(locale)", app)

        app.tabBars.buttons[sleep].tap()
        let gauge = element("domain-hero-sleep", app)
        XCTAssertTrue(gauge.waitForExistence(timeout: 5))
        XCTAssertEqual(gauge.value as? String, "95%")
        XCTAssertLessThan(gauge.frame.height, 230, "Text summary must not retain a large fixed ring")
        XCTAssertGreaterThan(gauge.frame.height, 40, "Value must scale with Dynamic Type")
        capture("Sleep Accessibility XXXL \(locale)", app)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])

        app.tabBars.buttons[today].tap()
        top("today-scroll", app)
        reveal("today-ring-recovery", app).tap()
        let recovery = element("domain-hero-recovery", app)
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        XCTAssertEqual(recovery.value as? String, "84%")
        XCTAssertLessThan(recovery.frame.height, 230)
        XCTAssertTrue(recovery.label.contains(locale == "ru" ? "Восстановление" : locale == "sr" ? "Oporavak" : "Recovery"))
        capture("Recovery Accessibility XXXL \(locale)", app)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        app.navigationBars.buttons.firstMatch.tap()
        top("today-scroll", app)
        reveal("today-ring-energy", app).tap()
        let reserve = element("energy-current", app)
        capture("Energy navigation result \(locale)", app)
        XCTAssertTrue(reserve.waitForExistence(timeout: 5))
        XCTAssertEqual(reserve.value as? String, "58")
        XCTAssertLessThan(reserve.frame.height, 230)
        capture("Energy Accessibility XXXL \(locale)", app)
        app.terminate()
    }

    @MainActor
    private func launch(locale: String = "en", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode", "--insights-fixture", "-AppleLanguages", "(\(locale))", "-AppleLocale", locale] + extra
        launchTestApplication(app)
        XCTAssertTrue(app.scrollViews["today-scroll"].waitForExistence(timeout: 5))
        let status = XCUIApplication(bundleIdentifier: "com.apple.springboard").statusBars.firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), "System status bar must be queried from SpringBoard")
        systemTop = status.frame.maxY
        return app
    }

    @MainActor
    private func assertDisclosure(_ slot: String, _ app: XCUIApplication) {
        for prefix in ["ai", "server"] {
            let button = reveal("\(prefix)-insight-\(slot)", app)
            assertTarget(button)
            XCTAssertEqual(button.label, prefix == "ai" ? "AI Insight" : "Server Insight")
            XCTAssertEqual(button.value as? String, prefix == "ai" ? "Expanded" : "Collapsed")
        }
    }

    @MainActor
    private func assertTarget(_ button: XCUIElement) {
        XCTAssertGreaterThanOrEqual(button.frame.width, 44)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
    }

    @MainActor
    private func assertBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.isHittable)
        XCTAssertGreaterThanOrEqual(back.frame.minY, systemTop)
    }

    @MainActor
    private func checkScroll(_ id: String, name: String, _ app: XCUIApplication, compareLandscape: Bool = true) {
        top(id, app)
        let scroll = app.scrollViews[id]
        XCTAssertTrue(scroll.exists)
        let before = statusBand(app)
        XCTAssertNotNil(before)
        capture("System theme \(name) top", app)
        for index in 1...2 {
            scroll.swipeUp(velocity: .slow)
            if compareLandscape {
                let after = statusBand(app)
                XCTAssertNotNil(after)
                XCTAssertEqual(after, before, "Scrolling foreground must not paint over the fixed status inset")
            }
            capture("System theme \(name) scroll \(index)", app)
        }
    }

    @MainActor
    private func statusBand(_ app: XCUIApplication) -> Data? {
        let image = app.screenshot().image
        guard let cgImage = image.cgImage else { return nil }
        let scale = CGFloat(cgImage.width) / app.frame.width
        let rect = CGRect(x: 0, y: (systemTop - 5) * scale, width: CGFloat(cgImage.width), height: 4 * scale)
        guard let crop = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: crop).pngData()
    }

    @MainActor
    private func top(_ id: String, _ app: XCUIApplication) {
        let anchor: String
        switch id {
        case "today-scroll": anchor = "today-sync-status"
        case "sleep-scroll": anchor = "domain-hero-sleep"
        case "section-scroll-recovery": anchor = "domain-hero-recovery"
        case "energy-scroll": anchor = "energy-current"
        case "trends-scroll": anchor = "readiness-summary-title"
        default:
            XCTFail("Missing top anchor for \(id)")
            return
        }
        scrollToElement(element(anchor, app), in: app, scrollView: app.scrollViews[id])
    }

    @MainActor
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor @discardableResult
    private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        scrollToElement(element(id, app), in: app)
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
