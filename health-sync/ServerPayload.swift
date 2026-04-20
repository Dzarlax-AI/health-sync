import Foundation

// MARK: - Top-level payload

struct HealthPayload: Encodable, Sendable {
    struct DataWrapper: Encodable, Sendable {
        let metrics: [MetricData]
    }
    let data: DataWrapper

    init(metrics: [MetricData]) {
        self.data = DataWrapper(metrics: metrics)
    }
}

struct MetricData: Encodable, Sendable {
    let name: String
    let units: String
    let data: [MetricSample]
}

// MARK: - Sample (flexible encoding for different server field names)

enum MetricSample: Encodable, Sendable {
    /// Most metrics → `qty` field
    case qty(date: String, value: Double, source: String)
    /// heart_rate → `Avg` field
    case avg(date: String, value: Double, source: String)
    /// sleep_analysis → phase fields
    case sleep(date: String, deep: Double, rem: Double, core: Double,
                awake: Double, total: Double, source: String)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        switch self {
        case .qty(let d, let v, let s):
            try c.encode(d, forKey: .date)
            try c.encode(v, forKey: .qty)
            try c.encode(s, forKey: .source)
        case .avg(let d, let v, let s):
            try c.encode(d, forKey: .date)
            try c.encode(v, forKey: .avg)
            try c.encode(s, forKey: .source)
        case .sleep(let d, let deep, let rem, let core, let awake, let total, let s):
            try c.encode(d, forKey: .date)
            try c.encode(deep,  forKey: .deep)
            try c.encode(rem,   forKey: .rem)
            try c.encode(core,  forKey: .core)
            try c.encode(awake, forKey: .awake)
            try c.encode(total, forKey: .totalSleep)
            try c.encode(s,     forKey: .source)
        }
    }

    private enum CK: String, CodingKey {
        case date, source, qty, avg = "Avg"
        case deep, rem, core, awake, totalSleep
    }
}

// MARK: - Date formatting (matches server: "2026-04-20 07:01:00 +0200")
// Uses Calendar to avoid DateFormatter's @MainActor inference in Swift 6.

func formatForServer(_ date: Date, in tz: TimeZone = .current) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let offset = tz.secondsFromGMT(for: date)
    let sign = offset >= 0 ? "+" : "-"
    let h = abs(offset) / 3600
    let m = (abs(offset) % 3600) / 60
    return String(
        format: "%04d-%02d-%02d %02d:%02d:%02d %@%02d%02d",
        c.year ?? 0, c.month ?? 0, c.day ?? 0,
        c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
        sign, h, m
    )
}
