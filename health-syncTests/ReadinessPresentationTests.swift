import Foundation
import Testing
@testable import health_sync

@MainActor
struct ReadinessPresentationTests {
    @Test func todayTitleRequiresAnExactValidCalendarDate() {
        #expect(ReadinessPresentation.title(date: "2026-11-09", today: "2026-11-09") == String(localized: "Today’s readiness"))
        for date in ["2026-11-08", "2024-02-29", "", "2026-02-30"] {
            #expect(ReadinessPresentation.title(date: date, today: "2026-11-09") == String(localized: "Latest value"))
        }
    }

    @Test func comparisonAlwaysNamesItsBaseline() {
        #expect(ReadinessPresentation.comparison(first: 55, last: 55) == String(localized: "Unchanged from the start of this range"))
        #expect(ReadinessPresentation.comparison(first: nil, last: 55) == String(localized: "No trend yet"))
        for (first, last) in [(55, 65), (65, 55), (55, 56), (56, 55)] {
            let direction = last > first ? String(localized: "higher") : String(localized: "lower")
            #expect(ReadinessPresentation.comparison(first: first, last: last) == String(localized: "\(abs(last - first)) points \(direction) than the start of this range"))
        }
    }

    @Test func dateCaptionPreservesCalendarDateAndYear() throws {
        let date = try #require(MetricDateWindow.date("2024-02-29"))
        #expect(ReadinessPresentation.dateCaption("2024-02-29") == date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))
        #expect(ReadinessPresentation.dateCaption("bad") == String(localized: "Date unavailable"))
    }
}
