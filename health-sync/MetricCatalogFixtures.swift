import Foundation

/// Explicitly isolated catalogue scenarios; no credentials or real health data.
enum MetricCatalogFixtures {
    private static var catalogueAttempts = 0
    private static func has(_ flag: String) -> Bool { enabled && ProcessInfo.processInfo.arguments.contains(flag) }
    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-test-mode") && arguments.contains("--metrics-fixture")
    }

    static func metrics() throws -> [MetricSummary] {
        if has("--metrics-missing-config") { throw ServerError.missingConfig }
        catalogueAttempts += 1
        if has("--metrics-network-retry"), catalogueAttempts == 1 { throw URLError(.notConnectedToInternet) }
        if has("--metrics-empty-catalogue") { return [] }
        let ru = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        let sr = Locale.preferredLanguages.first?.hasPrefix("sr") == true
        let walk = ru ? "6-мин ходьба" : sr ? "6-min hod" : "6-minute walk"
        let identifier = ru ? "Идентификатор" : sr ? "Identifikator" : "Identifier"
        let specs: [(String, String, String, String)] = [
            ("six_min_walk_distance", walk, "m", "known"),
            ("six_minute_walking_test_distance", walk, "m", "known"),
            ("active_energy", ru ? "Активная энергия" : sr ? "Aktivna energija" : "Active energy", "kcal", "known"),
            ("unknown_metric", ru ? "Без единицы" : sr ? "Bez jedinice" : "Unknown unit", "", "unknown"),
            ("mixed_metric", ru ? "Разные единицы" : sr ? "Različite jedinice" : "Mixed units", "", "mixed"),
        ]
        let legacy = ProcessInfo.processInfo.arguments.contains("--metrics-legacy-fixture")
        let range = metricRange()
        let rows: [[String: Any]] = specs.map { name, title, unit, status in
            var row: [String: Any] = ["name": name, "display_name": title, "units": unit,
                                      "count": 3, "min": range.min, "max": range.max]
            if !legacy {
                row["unit_status"] = status
                if title == walk { row["variant_label"] = "\(identifier): \(name)" }
            }
            return row
        }
        return try JSONDecoder().decode([MetricSummary].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    static func metricRange() -> MetricDateRange {
        let now = Calendar.current.startOfDay(for: Date())
        let today = Calendar.current.date(byAdding: .day, value: has("--metrics-history-fixture") ? -400 : 0, to: now) ?? now
        let first = Calendar.current.date(byAdding: .day, value: -14, to: today) ?? today
        return MetricDateRange(min: isoDate(first), max: isoDate(today))
    }

    static func data(name: String, from: String?, to: String?) -> MetricDataResponse {
        let today = MetricDateWindow.date(metricRange().max)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let points: [DataPoint] = [-14, -7, 0].compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let day = MetricDateWindow.iso(date)
            guard !has("--metrics-empty-data"), from.map({ day >= $0 }) ?? true, to.map({ day <= $0 }) ?? true else { return nil }
            let base = name == "six_minute_walking_test_distance" ? 620.0 : 400.0
            return DataPoint(date: day, qty: base + Double(offset + 14), min: nil, max: nil)
        }
        return MetricDataResponse(metric: name, bucket: "day", agg: name == "active_energy" ? "SUM" : "AVG",
                                  points: points, bySource: nil, pointsBySource: nil)
    }

    static func loadRange() throws -> MetricDateRange {
        if has("--metrics-unavailable-range") { throw URLError(.notConnectedToInternet) }
        if has("--metrics-invalid-range") { return MetricDateRange(min: "2026-02-30", max: "not-a-date") }
        if has("--metrics-no-range") { return MetricDateRange(min: "", max: "") }
        return metricRange()
    }

    private static func isoDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash))
    }
}
