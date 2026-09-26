import XCTest

final class InsightParityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAllInsightDestinationsAndEnergyHistory() throws {
        let app = launch()
        reveal("ai-insight-overall", app).tap()
        XCTAssertTrue(element("ai-insight-details-overall", app).exists)
        capture("Today insights", app)
        reveal("insight-domain-sleep", app).tap()
        XCTAssertTrue(element("domain-hero-sleep", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("domain-hero-sleep", app).isHittable)
        capture("Sleep top", app)
        reveal("server-insight-sleep", app).tap()
        XCTAssertTrue(element("server-insight-details-sleep", app).exists)
        reveal("ai-insight-sleep", app).tap()
        XCTAssertTrue(element("ai-insight-details-sleep", app).exists)
        capture("Sleep insights", app)
        app.tabBars.buttons["Today"].tap()
        reveal("insight-domain-recovery", app).tap()
        XCTAssertTrue(element("domain-hero-recovery", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("domain-hero-recovery", app).isHittable)
        capture("Recovery top", app)
        reveal("ai-insight-recovery", app)
        capture("Recovery insights", app)
        app.navigationBars.buttons.firstMatch.tap()
        reveal("insight-domain-energy", app).tap()
        XCTAssertTrue(element("energy-current", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("energy-current", app).isHittable)
        capture("Energy top", app)
        reveal("energy-history-details", app).tap()
        reveal("energy-history-2026-09-24", app)
        XCTAssertTrue(element("energy-history-2026-09-24", app).label.contains("-12"))
        capture("Energy history", app)
        reveal("ai-insight-energy", app)
        capture("Energy insights", app)
        app.terminate()
    }

    @MainActor
    func testDashboardCompositionInBothThemes() throws {
        for dark in [false, true] {
            let app = launch(extra: dark ? ["--ui-test-force-dark-mode"] : [])
            XCTAssertTrue(element("today-ring-sleep", app).waitForExistence(timeout: 5))
            XCTAssertTrue(element("today-ring-energy", app).isHittable)
            XCTAssertTrue(element("today-ring-recovery", app).isHittable)
            capture("Today top \(dark ? "dark" : "light")", app)
            element("today-ring-sleep", app).tap()
            XCTAssertTrue(element("domain-hero-sleep", app).waitForExistence(timeout: 5))
            XCTAssertTrue(element("server-insight-sleep", app).isHittable)
            capture("Sleep top \(dark ? "dark" : "light")", app)
            app.tabBars.buttons["Today"].tap()
            element("today-ring-recovery", app).tap()
            XCTAssertTrue(element("domain-hero-recovery", app).waitForExistence(timeout: 5))
            XCTAssertTrue(element("server-insight-recovery", app).isHittable)
            capture("Recovery top \(dark ? "dark" : "light")", app)
            app.navigationBars.buttons.firstMatch.tap()
            element("today-ring-energy", app).tap()
            XCTAssertTrue(element("energy-current", app).waitForExistence(timeout: 5))
            XCTAssertTrue(element("server-insight-energy", app).isHittable)
            capture("Energy top \(dark ? "dark" : "light")", app)
            app.terminate()
        }
    }

    @MainActor
    func testMissingMetricsAndAIStates() throws {
        for state in ["disabled", "generating"] {
            let app = launch(extra: ["--insights-missing-values", "--insights-\(state)"])
            XCTAssertTrue(element("today-ring-energy", app).waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "—")).count >= 3)
            XCTAssertFalse(element("ai-insight-overall", app).exists)
            XCTAssertEqual(app.staticTexts["AI insight is updating"].exists, state == "generating")
            capture("Missing metrics AI \(state)", app)
            app.terminate()
        }
        let app = launch(extra: ["--insights-server-unavailable"])
        XCTAssertTrue(element("server-insight-overall", app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("today-ring-energy", app).exists)
        capture("Briefing unavailable", app)
        app.terminate()
    }

    @MainActor
    func testLongInsightCanExpandAndCollapse() throws {
        let app = launch(locale: "ru", extra: ["--insights-long-text"])
        let summary = reveal("server-insight-overall", app)
        let collapsedHeight = summary.frame.height
        summary.tap()
        let expanded = element("server-insight-details-overall", app)
        XCTAssertTrue(expanded.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(expanded.frame.height, collapsedHeight)
        capture("Long server insight expanded", app)
        summary.tap()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(summary.frame.height - collapsedHeight) < 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 3), .completed)
        XCTAssertFalse(expanded.exists)
        capture("Long server insight collapsed", app)
        app.terminate()
    }

    @MainActor
    func testLightLargeText() throws {
        let app = launch(locale: "ru", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(element("today-ring-energy", app).waitForExistence(timeout: 5))
        capture("Today light large", app)
        app.tabBars.buttons["Сон"].tap()
        XCTAssertTrue(element("domain-hero-sleep", app).waitForExistence(timeout: 5))
        capture("Sleep light large", app)
        reveal("server-insight-sleep", app).tap()
        XCTAssertTrue(element("server-insight-details-sleep", app).exists)
        reveal("ai-insight-sleep", app).tap()
        XCTAssertTrue(element("ai-insight-details-sleep", app).exists)
        capture("Sleep expanded light large", app)
        app.terminate()
    }

    @MainActor
    func testEmptySleepKeepsInsight() throws {
        let app = launch(extra: ["--insights-empty-sleep"])
        app.tabBars.buttons["Sleep"].tap()
        XCTAssertTrue(app.staticTexts["No sleep data yet."].waitForExistence(timeout: 5))
        XCTAssertFalse(element("domain-hero-sleep", app).exists)
        XCTAssertTrue(element("server-insight-sleep", app).exists)
        capture("Empty sleep", app)
        app.terminate()
    }

    @MainActor
    func testSectionLandscapesInBothThemes() throws {
        for dark in [false, true] {
            let app = launch(extra: dark ? ["--ui-test-force-dark-mode"] : [])
            app.tabBars.buttons["Trends"].tap()
            for (key, title) in [("recovery", "Recovery"), ("activity", "Activity"), ("cardio", "Cardio")] {
                let row = app.staticTexts[title].firstMatch
                for _ in 0..<8 {
                    if row.exists && row.isHittable { break }
                    app.swipeUp()
                }
                XCTAssertTrue(row.isHittable)
                row.tap()
                XCTAssertTrue(element("domain-hero-\(key)", app).waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts[title].firstMatch.exists)
                capture("\(title) landscape \(dark ? "dark" : "light")", app)
                app.navigationBars.buttons.firstMatch.tap()
            }
            app.terminate()
        }
    }

    @MainActor
    func testRussianDarkLargeText() throws { try checkLocalized(locale: "ru", dark: true, large: true) }

    @MainActor
    func testSerbianLight() throws { try checkLocalized(locale: "sr", dark: false, large: false) }

    @MainActor
    func testFailedAIFallsBackToServerInsight() throws {
        let app = launch(extra: ["--insights-failed"])
        reveal("server-insight-overall", app)
        XCTAssertFalse(element("ai-insight-overall", app).exists)
        XCTAssertTrue(app.staticTexts["AI insight is unavailable. Server insight is shown."].exists)
        capture("AI fallback", app)
        app.terminate()
    }

    @MainActor
    private func checkLocalized(locale: String, dark: Bool, large: Bool) throws {
        var extra = dark ? ["--ui-test-force-dark-mode"] : []
        if large { extra += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        let app = launch(locale: locale, extra: extra)
        let server = reveal("server-insight-overall", app)
        XCTAssertTrue(server.label.contains(locale == "ru" ? "Инсайт сервера" : "Uvid servera"))
        reveal("ai-insight-overall", app)
        capture("Today \(locale) \(large ? "large" : "normal")", app)
        reveal("insight-domain-energy", app).tap()
        XCTAssertTrue(app.staticTexts[locale == "ru" ? "Энергия" : "Energija"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(element("energy-current", app).waitForExistence(timeout: 5))
        capture("Energy top \(locale)", app)
        reveal("ai-insight-energy", app)
        capture("Energy \(locale) \(large ? "large" : "normal")", app)
        app.terminate()
    }

    @MainActor
    private func launch(locale: String = "en", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode", "--insights-fixture", "--ui-test-force-light-mode", "-AppleLanguages", "(\(locale))", "-AppleLocale", locale] + extra
        app.launch()
        return app
    }

    @MainActor
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor @discardableResult
    private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let value = element(id, app)
        XCTAssertTrue(value.waitForExistence(timeout: 8), "Missing \(id)")
        for _ in 0..<18 {
            if value.isHittable && value.frame.midY < app.tabBars.firstMatch.frame.minY { return value }
            app.swipeUp()
        }
        XCTAssertTrue(value.isHittable, "Cannot reach \(id)")
        return value
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
