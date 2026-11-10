import Foundation

/// Presentation of server points only; scores and bands remain server-owned.
enum ReadinessPresentation {
    static func title(date: String, today: String) -> String {
        if MetricDateWindow.date(date) != nil, date == today {
            return String(localized: "Today’s readiness")
        }
        return String(localized: "Latest value")
    }

    static func dateCaption(_ value: String) -> String {
        guard let date = MetricDateWindow.date(value) else { return String(localized: "Date unavailable") }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    static func comparison(first: Int?, last: Int?) -> String {
        guard let first, let last else { return String(localized: "No trend yet") }
        let delta = last - first
        if delta == 0 { return String(localized: "Unchanged from the start of this range") }
        let direction = delta > 0 ? String(localized: "higher") : String(localized: "lower")
        return String(localized: "\(abs(delta)) points \(direction) than the start of this range")
    }
}
