import XCTest

extension XCTestCase {
    @MainActor
    func launchTestApplication(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if !app.launchArguments.contains("--ui-test-mode") {
            app.launchArguments.append("--ui-test-mode")
        }
        let cleanup: @Sendable () async throws -> Void = {
            await MainActor.run {
                let application = XCUIApplication()
                if application.state != .notRunning { application.terminate() }
            }
        }
        addTeardownBlock(cleanup)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "Test application did not reach the foreground", file: file, line: line)
    }

    /// Keep gestures inside content, and recover when a previous gesture moved
    /// the target above the viewport. Whole-app swipes can start on fixed chrome.
    @MainActor @discardableResult
    func scrollToElement(_ element: XCUIElement, in app: XCUIApplication,
                         scrollView: XCUIElement? = nil, fullyVisible: Bool = false,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let scroll = scrollView ?? app.scrollViews.allElementsBoundByIndex.first(where: { $0.isHittable })
            ?? app.scrollViews.firstMatch
        guard scroll.waitForExistence(timeout: 5) else {
            XCTFail("Missing scroll view for \(element)", file: file, line: line)
            return element
        }
        var unknownFrameSteps = 0
        for _ in 0..<30 {
            var viewport = scroll.frame.intersection(app.frame)
            let navigation = app.navigationBars.firstMatch
            if navigation.exists {
                let top = max(viewport.minY, navigation.frame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width,
                                  height: max(0, viewport.maxY - top))
            }
            let tabs = app.tabBars.firstMatch
            if tabs.exists {
                viewport.size.height = max(0, min(viewport.maxY, tabs.frame.minY) - viewport.minY)
            }
            viewport = viewport.insetBy(dx: 8, dy: 8)
            guard viewport.width > 0, viewport.height > 0 else {
                XCTFail("No visible scroll viewport", file: file, line: line)
                return element
            }
            let frame = element.exists ? element.frame : .zero
            let hasFrame = !frame.isEmpty && !frame.isNull
            if hasFrame && element.isHittable &&
                (fullyVisible ? viewport.contains(frame) : viewport.contains(CGPoint(x: frame.midX, y: frame.midY))) {
                return element
            }
            // SwiftUI may omit offscreen frames. Search toward the top first
            // in that case, then downward, rather than assuming it is below us.
            if !hasFrame { unknownFrameSteps += 1 }
            let movingDown = hasFrame ? frame.midY >= viewport.midY : unknownFrameSteps > 10
            let distance = min(viewport.height * 0.55,
                               max(60, hasFrame ? abs(frame.midY - viewport.midY) : viewport.height * 0.5))
            let startY = movingDown ? viewport.maxY - 10 : viewport.minY + 10
            let endY = startY + (movingDown ? -distance : distance)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX, dy: startY))
            let end = origin.withOffset(CGVector(dx: viewport.midX, dy: endY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Cannot reach \(element)", file: file, line: line)
        return element
    }
}
