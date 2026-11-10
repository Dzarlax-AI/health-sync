import XCTest

final class MetricsFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testKnownUnitsAndBothServerVariantsReachTheirOwnDetail() throws {
        let app = launch()
        for name in ["six_min_walk_distance", "six_minute_walking_test_distance"] {
            let row = app.buttons["metric-row-\(name)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            reveal(row, app)
            XCTAssertTrue(row.label.contains(name))
            row.tap()
            let variant = app.staticTexts["metric-detail-variant"]
            XCTAssertTrue(variant.waitForExistence(timeout: 5))
            XCTAssertTrue(variant.label.contains(name))
            XCTAssertEqual(app.staticTexts["metric-chart-unit"].label, "m")
            XCTAssertTrue(app.scrollViews["metric-detail-\(name)"].exists)
            let expected = name == "six_min_walk_distance" ? "414 m" : "634 m"
            XCTAssertTrue(app.staticTexts[expected].firstMatch.exists)
            app.navigationBars.buttons.firstMatch.tap()
        }
        capture("Catalogue variants and units", app)
        app.terminate()
    }

    @MainActor
    func testUnknownAndMixedUnitsAreExplicitAndNeverInvented() throws {
        let app = launch()
        for (name, notice) in [("unknown_metric", "Unit not specified"), ("mixed_metric", "Units vary")] {
            let row = app.buttons["metric-row-\(name)"]
            reveal(row, app)
            XCTAssertTrue(row.label.contains(notice))
            row.tap()
            let message = app.staticTexts["metric-unit-notice"]
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            XCTAssertEqual(message.label, notice)
            XCTAssertFalse(app.staticTexts["metric-chart-unit"].exists)
            capture("Metric unit state \(name)", app)
            app.navigationBars.buttons.firstMatch.tap()
        }
        app.terminate()
    }

    @MainActor
    func testOldServerUsesIdentifierFallbackAndLocalizedRecordCounts() throws {
        for (locale, tab, record) in [("ru", "Метрики", "записи"), ("sr", "Metrike", "zapisa")] {
            let app = launch(locale: locale, tab: tab, extra: ["--metrics-legacy-fixture"])
            let row = app.buttons["metric-row-six_min_walk_distance"]
            reveal(row, app)
            XCTAssertTrue(row.label.contains("six_min_walk_distance"))
            XCTAssertTrue(row.label.contains(record))
            row.tap()
            XCTAssertTrue(app.staticTexts["metric-detail-variant"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["metric-detail-variant"].label.contains("six_min_walk_distance"))
            XCTAssertEqual(app.staticTexts["metric-chart-unit"].label, "m")
            capture("Legacy catalogue \(locale)", app)
            app.terminate()
        }
    }

    @MainActor
    func testHistoricalRecordsAndReturnToCurrentPeriod() throws {
        let app = launch(extra: ["--metrics-history-fixture"])
        let row = app.buttons["metric-row-active_energy"]
        reveal(row, app)
        XCTAssertTrue(row.label.contains("Last record:"))
        row.tap()
        let latest = app.buttons["metric-latest-records"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No data in this range."].exists)
        latest.tap()
        XCTAssertTrue(app.staticTexts["metric-chart-dates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["414 kcal"].exists)
        for days in ["7d", "90d", "30d"] {
            app.segmentedControls.buttons[days].tap()
            XCTAssertTrue(app.staticTexts["metric-chart-dates"].exists)
        }
        capture("Latest historical records", app)
        app.buttons["metric-current-period"].tap()
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["metric-chart-dates"].exists)
        app.terminate()
    }

    @MainActor
    func testHistoricalActionsAreLocalizedInRussianAndSerbian() throws {
        for (locale, tab, action, current) in [
            ("ru", "Метрики", "Показать последние записи", "К текущему периоду"),
            ("sr", "Metrike", "Prikaži poslednje zapise", "Tekući period")
        ] {
            let app = launch(locale: locale, tab: tab, extra: ["--metrics-history-fixture"])
            reveal(app.buttons["metric-row-active_energy"], app)
            app.buttons["metric-row-active_energy"].tap()
            let latest = app.buttons["metric-latest-records"]
            XCTAssertTrue(latest.waitForExistence(timeout: 5))
            XCTAssertEqual(latest.label, action)
            capture("Historical empty state \(locale)", app)
            latest.tap()
            let back = app.buttons["metric-current-period"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            XCTAssertEqual(back.label, current)
            XCTAssertTrue(app.staticTexts["metric-chart-dates"].exists)
            capture("Historical chart \(locale)", app)
            app.terminate()
        }
    }

    @MainActor
    func testMissingConfigurationOpensConnectionFieldsAndNetworkCanRetry() throws {
        var app = launch(extra: ["--metrics-missing-config"])
        app.tabBars.buttons["Settings"].tap()
        let activity = app.buttons["sync-status-details"]
        reveal(activity, app)
        activity.tap()
        XCTAssertTrue(app.navigationBars["Data & sync"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Metrics"].tap()
        let connect = app.buttons["metrics-connect-server"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["metrics-retry"].exists)
        connect.tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
        XCTAssertTrue(app.textFields["https://health.example.com"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["your-secret-key"].exists)
        capture("Connection fields from Metrics", app)
        app.terminate()

        app = launch(extra: ["--metrics-network-retry"])
        let retry = app.buttons["metrics-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["metrics-connect-server"].exists)
        retry.tap()
        XCTAssertTrue(app.buttons["metric-row-active_energy"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testUnavailableOrInvalidRangeDoesNotOfferHistoricalAction() throws {
        for flag in ["--metrics-invalid-range", "--metrics-unavailable-range", "--metrics-no-range"] {
            let app = launch(extra: ["--metrics-history-fixture", flag])
            let row = app.buttons["metric-row-active_energy"]
            reveal(row, app)
            row.tap()
            XCTAssertTrue(app.staticTexts["No data in this range."].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["metric-latest-records"].exists)
            app.terminate()
        }
        let app = launch(extra: ["--metrics-history-fixture", "--metrics-empty-data"])
        reveal(app.buttons["metric-row-active_energy"], app)
        app.buttons["metric-row-active_energy"].tap()
        let latest = app.buttons["metric-latest-records"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        latest.tap()
        XCTAssertTrue(app.staticTexts["No records are available for these dates."].waitForExistence(timeout: 5))
        XCTAssertFalse(latest.exists)
        app.terminate()
    }

    @MainActor
    func testEmptyCatalogueAndSearchNoMatchesAreDistinct() throws {
        var app = launch(extra: ["--metrics-empty-catalogue"])
        XCTAssertTrue(app.staticTexts["No metrics yet."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["metrics-retry"].exists)
        app.terminate()
        app = launch()
        XCTAssertTrue(app.buttons["metric-row-active_energy"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("no-such-metric")
        XCTAssertTrue(app.staticTexts["No matching metrics."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No metrics yet."].exists)
        app.terminate()
    }

    @MainActor
    private func launch(locale: String = "en", tab: String = "Metrics", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode", "--metrics-fixture", "--ui-test-force-light-mode", "-AppleLanguages", "(\(locale))", "-AppleLocale", locale] + extra
        launchTestApplication(app)
        app.tabBars.buttons[tab].tap()
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        scrollToElement(element, in: app)
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
