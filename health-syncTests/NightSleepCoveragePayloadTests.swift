import Foundation
import Testing
@testable import health_sync

struct NightSleepCoveragePayloadTests {
    @Test func coverageUsesTheServerContractKeys() throws {
        let coverage = NightSleepCoverage(
            wakeDate: "2026-09-11",
            metricDate: "2026-09-11 00:00:00 +0200",
            source: "Alexey's Apple Watch",
            sourceEpoch: "health-sync-ios-v1",
            captureCompleteness: "complete",
            syncGeneration: "scan-1",
            coveredIntervalStart: "2026-09-10T10:00:00Z",
            coveredIntervalEnd: "2026-09-11T10:00:00Z"
        )
        let payload = HealthPayload(
            metrics: [MetricData(name: "night_sleep_total", units: "hr", data: [
                .qty(date: "2026-09-11 00:00:00 +0200", value: 7.2, source: "Alexey's Apple Watch")
            ])],
            nightSleepCoverage: [coverage]
        )

        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        let data = raw["data"] as! [String: Any]
        let encoded = (data["night_sleep_coverage"] as! [[String: String]]).first!
        #expect(encoded["wake_date"] == "2026-09-11")
        #expect(encoded["metric_date"] == "2026-09-11 00:00:00 +0200")
        #expect(encoded["source_epoch"] == "health-sync-ios-v1")
        #expect(encoded["capture_completeness"] == "complete")
        #expect(encoded["covered_interval_end"] == "2026-09-11T10:00:00Z")
    }

    @Test func regularPayloadOmitsCoverageUntilTheSleepFetcherProvidesIt() throws {
        let payload = HealthPayload(metrics: [])
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        let data = raw["data"] as! [String: Any]
        #expect(data["night_sleep_coverage"] == nil)
    }

    @Test func coverageUsesLocalNoonAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Belgrade"))
        let wakeDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 8)))
        let window = try #require(HealthKitManager.nightCoverageWindow(for: wakeDay, calendar: calendar))

        #expect(calendar.component(.hour, from: window.start) == 12)
        #expect(calendar.component(.hour, from: window.end) == 12)
        #expect(calendar.dateComponents([.day], from: window.start, to: window.end).day == 1)
    }

    @Test func coverageNeverExtendsPastTheActualQueryTime() {
        let now = Date(timeIntervalSinceReferenceDate: 1234)
        let future = now.addingTimeInterval(24 * 60 * 60)

        #expect(HealthKitManager.effectiveSleepQueryEnd(until: future, now: now) == now)
        #expect(HealthKitManager.effectiveSleepQueryEnd(until: nil, now: now) == now)
    }
}
