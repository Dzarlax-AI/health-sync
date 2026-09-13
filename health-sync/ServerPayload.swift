@preconcurrency import Foundation

// MARK: - Top-level payload

nonisolated struct HealthPayload: Encodable, Sendable {
    nonisolated struct DataWrapper: Encodable, Sendable {
        let metrics: [MetricData]
        let nightSleepCoverage: [NightSleepCoverage]?
        let sleepPeriodCoverage: [SleepPeriodCoverage]?
        let completedSleepEpisodes: [CompletedSleepEpisode]?

        enum CodingKeys: String, CodingKey {
            case metrics
            case nightSleepCoverage = "night_sleep_coverage"
            case sleepPeriodCoverage = "sleep_period_coverage"
            case completedSleepEpisodes = "completed_sleep_episodes"
        }
    }
    let data: DataWrapper

    init(metrics: [MetricData],
         nightSleepCoverage: [NightSleepCoverage] = [],
         sleepPeriodCoverage: [SleepPeriodCoverage] = [],
         completedSleepEpisodes: [CompletedSleepEpisode] = []) {
        self.data = DataWrapper(
            metrics: metrics,
            nightSleepCoverage: nightSleepCoverage.isEmpty ? nil : nightSleepCoverage,
            sleepPeriodCoverage: sleepPeriodCoverage.isEmpty ? nil : sleepPeriodCoverage,
            completedSleepEpisodes: completedSleepEpisodes.isEmpty ? nil : completedSleepEpisodes
        )
    }

    var pointCount: Int { data.metrics.reduce(0) { $0 + $1.data.count } }

    /// A complete sleep-period commitment is meaningful server input even
    /// when HealthKit found no asleep samples. Without this, the server cannot
    /// distinguish a genuinely sleep-free period from a period the adapter
    /// never observed.
    var hasUploadableContent: Bool {
        pointCount > 0 || !(data.sleepPeriodCoverage?.isEmpty ?? true)
    }
}

/// A controlled-adapter coverage commitment for one emitted
/// `night_sleep_total` point. It says which fixed overnight window was read;
/// it does not claim that HealthKit will never revise the night later.
nonisolated struct NightSleepCoverage: Encodable, Sendable {
    let wakeDate: String
    let metricDate: String
    let source: String
    let sourceEpoch: String
    let captureCompleteness: String
    let syncGeneration: String
    let coveredIntervalStart: String
    let coveredIntervalEnd: String

    enum CodingKeys: String, CodingKey {
        case wakeDate = "wake_date"
        case metricDate = "metric_date"
        case source
        case sourceEpoch = "source_epoch"
        case captureCompleteness = "capture_completeness"
        case syncGeneration = "sync_generation"
        case coveredIntervalStart = "covered_interval_start"
        case coveredIntervalEnd = "covered_interval_end"
    }
}

/// One complete tenant-local noon-to-noon observation window. It has no
/// wearable source because it attests to the adapter's query coverage, not to
/// a particular device. A period may be sent without episodes.
nonisolated struct SleepPeriodCoverage: Encodable, Sendable {
    let wakeDate: String
    let sourceEpoch: String
    let captureCompleteness: String
    let syncGeneration: String
    let coveredIntervalStart: String
    let coveredIntervalEnd: String

    enum CodingKeys: String, CodingKey {
        case wakeDate = "wake_date"
        case sourceEpoch = "source_epoch"
        case captureCompleteness = "capture_completeness"
        case syncGeneration = "sync_generation"
        case coveredIntervalStart = "covered_interval_start"
        case coveredIntervalEnd = "covered_interval_end"
    }
}

/// A source-selected, non-overlapping asleep interval inside one complete
/// `SleepPeriodCoverage` window. The server derives its identity and rejects
/// it unless the generation matches the accompanying period commitment.
nonisolated struct CompletedSleepEpisode: Encodable, Sendable {
    let wakeDate: String
    let start: String
    let end: String
    let source: String
    let sourceEpoch: String
    let syncGeneration: String

    enum CodingKeys: String, CodingKey {
        case wakeDate = "wake_date"
        case start, end, source
        case sourceEpoch = "source_epoch"
        case syncGeneration = "sync_generation"
    }
}

nonisolated struct MetricData: Encodable, Sendable {
    let name: String
    let units: String
    let data: [MetricSample]
}

// MARK: - Sample (flexible encoding for different server field names)

nonisolated enum MetricSample: Encodable, Sendable {
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

nonisolated func formatForServer(_ date: Date, in tz: TimeZone = .current) -> String {
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
