import Foundation

// MARK: - Top-level payload

struct HealthPayload: Encodable {
    struct DataWrapper: Encodable {
        let metrics: [MetricData]
    }
    let data: DataWrapper

    init(metrics: [MetricData]) {
        self.data = DataWrapper(metrics: metrics)
    }
}

struct MetricData: Encodable {
    let name: String
    let units: String
    let data: [MetricSample]
}

// MARK: - Sample (flexible encoding for different server field names)

enum MetricSample: Encodable {
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

// MARK: - Date formatting (matches server format: "2026-04-20 07:01:00 +0200")

func formatForServer(_ date: Date, in tz: TimeZone = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let base = f.string(from: date)
    let seconds = tz.secondsFromGMT(for: date)
    let sign = seconds >= 0 ? "+" : "-"
    let absSeconds = abs(seconds)
    let hours = absSeconds / 3600
    let minutes = (absSeconds % 3600) / 60
    return String(format: "%@ %@%02d%02d", base, sign, hours, minutes)
}
