import Foundation
import Testing
@testable import health_sync

@MainActor
struct MetricRangeSelectionTests {
    @Test(arguments: [("2024-03-01", "2024-02-24"), ("2027-01-03", "2026-12-28"),
                      ("2026-03-30", "2026-03-24"), ("2026-10-26", "2026-10-20")])
    func sevenDaysAreInclusiveAcrossLeapYearAndDST(end: String, start: String) {
        #expect(MetricDateWindow.ending(at: end, days: 7)?.from == start)
        #expect(MetricDateWindow.ending(at: end, days: 7)?.to == end)
    }

    @Test func rangeClampsToFirstRecordAndRejectsMalformedDates() {
        #expect(MetricDateWindow.ending(at: "2026-01-10", days: 90, minimum: "2026-01-08")?.from == "2026-01-08")
        for date in ["", "2026-02-30", "2026-2-01", "2026-01-01T12:00:00Z", "2026-13-01"] {
            #expect(MetricDateWindow.date(date) == nil)
        }
        #expect(MetricDateWindow(from: "2026-02-02", to: "2026-02-01") == nil)
        #expect(MetricDateWindow.ending(at: "2026-02-02", days: 0) == nil)
    }

    @Test func dateOnlyRoundTripsWithoutDeviceTimezoneConversion() throws {
        let date = try #require(MetricDateWindow.date("2026-03-29"))
        #expect(MetricDateWindow.iso(date) == "2026-03-29")
        #expect(MetricDateWindow.iso(date, timeZone: TimeZone(secondsFromGMT: -8 * 3600)!) == "2026-03-28")
        let window = try #require(MetricDateWindow.ending(at: "2026-03-29", days: 7))
        #expect(window.from == "2026-03-23")
    }

    @Test func newerPeriodWinsEvenWhenOlderRequestCompletesLast() async throws {
        let gate = MetricDataGate()
        let short = try #require(MetricDateWindow.ending(at: "2026-11-09", days: 7))
        let long = try #require(MetricDateWindow.ending(at: "2026-11-09", days: 90))
        let controller = MetricDetailController(data: { metric, window in
            if window == short { return await gate.load(metric) }
            return Self.response(metric, date: window.from, qty: 90)
        }, range: { _ in MetricDateRange(min: "2025-01-01", max: "2026-11-09") }, context: { "account" })
        let old = Task { await controller.load(metric: "steps", window: short) }
        await gate.wait()
        await controller.load(metric: "steps", window: long)
        gate.finish(date: short.from, qty: 7)
        await old.value
        #expect(controller.points.first?.qty == 90)
        #expect(controller.displayedWindow == long)
        #expect(!controller.isLoading)
    }

    @Test func failedNewPeriodKeepsPreviousGraphWithPreviousCaption() async throws {
        let state = MetricRangeTestState()
        let short = try #require(MetricDateWindow.ending(at: "2026-11-09", days: 7))
        let long = try #require(MetricDateWindow.ending(at: "2026-11-09", days: 90))
        let controller = MetricDetailController(data: { metric, window in
            if state.fail { throw URLError(.notConnectedToInternet) }
            return Self.response(metric, date: window.to, qty: 7)
        }, range: { _ in throw URLError(.notConnectedToInternet) }, context: { "account" })
        await controller.load(metric: "steps", window: short)
        #expect(controller.points.count == 1)
        state.fail = true
        await controller.load(metric: "steps", window: long)
        #expect(controller.displayedWindow == short)
        #expect(controller.points.first?.qty == 7)
        #expect(controller.loadError != nil)
        #expect(controller.availableRange == nil)
    }

    @Test func oldSuccessCannotEraseNewFailureAndCancellationCannotPublish() async throws {
        let gate = MetricDataGate()
        let short = try #require(MetricDateWindow.ending(at: "2026-11-09", days: 7))
        let long = try #require(MetricDateWindow.ending(at: "2026-11-09", days: 90))
        let controller = MetricDetailController(data: { metric, window in
            if window == short { return await gate.load(metric) }
            throw URLError(.timedOut)
        }, range: { _ in MetricDateRange(min: "2026-01-01", max: "2026-11-09") }, context: { "account" })
        let old = Task { await controller.load(metric: "steps", window: short) }
        await gate.wait()
        await controller.load(metric: "steps", window: long)
        let error = controller.loadError
        gate.finish(date: short.to, qty: 7)
        await old.value
        #expect(controller.points.isEmpty)
        #expect(controller.loadError == error)
        #expect(controller.displayedWindow == nil)

        let cancelled = Task { await controller.load(metric: "steps", window: short) }
        await gate.wait()
        cancelled.cancel()
        gate.finish(date: short.to, qty: 7)
        await cancelled.value
        #expect(controller.points.isEmpty)
        #expect(controller.displayedWindow == nil)
        #expect(!controller.isLoading)
    }

    @Test func cancelledOldRequestDoesNotClearANewerLoadingIndicator() async throws {
        let oldGate = MetricDataGate()
        let newGate = MetricDataGate()
        let short = try #require(MetricDateWindow.ending(at: "2026-11-09", days: 7))
        let long = try #require(MetricDateWindow.ending(at: "2026-11-09", days: 90))
        let controller = MetricDetailController(data: { metric, window in
            await (window == short ? oldGate : newGate).load(metric)
        }, range: { _ in MetricDateRange(min: "2026-01-01", max: "2026-11-09") }, context: { "account" })
        let old = Task { await controller.load(metric: "steps", window: short) }
        await oldGate.wait()
        old.cancel()
        let new = Task { await controller.load(metric: "steps", window: long) }
        await newGate.wait()
        oldGate.finish(date: short.to, qty: 7)
        await old.value
        #expect(controller.isLoading)
        newGate.finish(date: long.to, qty: 90)
        await new.value
        #expect(!controller.isLoading)
        #expect(controller.points.first?.qty == 90)
    }

    @Test(arguments: ["2026-03-29", "2026-10-25", "2026-11-09"])
    func dailyChartBucketsUseTheSameDatesAsTheirLabels(day: String) throws {
        let point = try #require(MetricDateWindow.date(day))
        let bucket = try #require(MetricDateWindow.calendar.dateInterval(of: .day, for: point))
        #expect(bucket.start == point)
        #expect(MetricDateWindow.iso(bucket.start) == day)
    }

    @Test(arguments: [false, true])
    func metricOrAccountChangeRejectsPriorResponse(changeAccount: Bool) async throws {
        let gate = MetricDataGate()
        let state = MetricRangeTestState()
        let window = try #require(MetricDateWindow.ending(at: "2026-11-09", days: 7))
        let controller = MetricDetailController(data: { metric, _ in
            if metric == "old" { return await gate.load(metric) }
            return Self.response(metric, date: window.to, qty: 2)
        }, range: { _ in MetricDateRange(min: "2026-01-01", max: "2026-11-09") }, context: { state.account })
        let old = Task { await controller.load(metric: "old", window: window) }
        await gate.wait()
        if changeAccount { state.account = "second" }
        else { await controller.load(metric: "new", window: window) }
        gate.finish(date: window.to, qty: 1)
        await old.value
        #expect(controller.points.first?.qty == (changeAccount ? nil : 2))
        if changeAccount { #expect(controller.displayedWindow == nil) }
    }

    @Test func freshRangeEnablesHistoricalWindowAndInvalidRangeDoesNot() async throws {
        let state = MetricRangeTestState()
        let window = try #require(MetricDateWindow.ending(at: "2026-11-09", days: 30))
        let controller = MetricDetailController(data: { metric, _ in Self.response(metric) },
            range: { _ in state.bounds }, context: { "account" })
        await controller.load(metric: "steps", window: window)
        let range = try #require(controller.availableRange)
        #expect(MetricDateWindow.ending(at: range.to, days: 7, minimum: range.from)?.from == "2024-02-28")
        state.bounds = MetricDateRange(min: "", max: "2026-02-30")
        await controller.load(metric: "steps", window: window)
        #expect(controller.availableRange == nil)
    }

    private static func response(_ metric: String, date: String? = nil, qty: Double = 0) -> MetricDataResponse {
        MetricDataResponse(metric: metric, bucket: "day", agg: "AVG",
            points: date.map { [DataPoint(date: $0, qty: qty, min: nil, max: nil)] } ?? [],
            bySource: nil, pointsBySource: nil)
    }
}

@MainActor
private final class MetricDataGate {
    private var continuation: CheckedContinuation<MetricDataResponse, Never>?
    private var metric = ""
    func load(_ metric: String) async -> MetricDataResponse {
        self.metric = metric
        return await withCheckedContinuation { continuation = $0 }
    }
    func wait() async { while continuation == nil { await Task.yield() } }
    func finish(date: String, qty: Double) {
        continuation?.resume(returning: MetricDataResponse(metric: metric, bucket: "day", agg: "AVG",
            points: [DataPoint(date: date, qty: qty, min: nil, max: nil)], bySource: nil, pointsBySource: nil))
        continuation = nil
    }
}

@MainActor
private final class MetricRangeTestState {
    var fail = false
    var account = "first"
    var bounds = MetricDateRange(min: "2024-02-28", max: "2024-03-01")
}
