import Foundation

// MARK: - Briefing (rich Today payload from /api/health-briefing)

struct BriefingResponse: Decodable, Sendable {
    let date: String
    let greeting: String?
    let overall: String?

    let headline: HeadlineSignal?
    let sections: [BriefingSection]?
    let highlights: [BriefingDetail]?

    let readinessScore: Int?
    let readinessLabel: String?
    let readinessTip: String?
    let recoveryPct: Int?
    let readinessToday: Int?
    let readinessTodayLabel: String?

    let correlation: [CorrelationPoint]?
    let insights: [Insight]?
    let alerts: [Alert]?

    let sleep: SleepAnalysis?
    let metricCards: [MetricCard]?
    let energyBank: EnergyBank?

    /// Planned: Gemini-generated narrative. Currently absent from API
    /// (server change required); decoded as nil until backend exposes it.
    let aiInsight: String?

    enum CodingKeys: String, CodingKey {
        case date, greeting, overall, headline, sections, highlights
        case readinessScore = "readiness_score"
        case readinessLabel = "readiness_label"
        case readinessTip = "readiness_tip"
        case recoveryPct = "recovery_pct"
        case readinessToday = "readiness_today"
        case readinessTodayLabel = "readiness_today_label"
        case correlation, insights, alerts, sleep
        case metricCards = "metric_cards"
        case energyBank = "energy_bank"
        case aiInsight = "ai_insight"
    }
}

struct HeadlineSignal: Decodable, Sendable {
    let key: String
    let severity: String
    let title: String
    let detail: String
    let metrics: [HeadlineMetricDelta]?
}

struct HeadlineMetricDelta: Decodable, Sendable {
    let metric: String
    let value: Double
    let baseline: Double
    let deltaAbs: Double
    let deltaPct: Double
    let zScore: Double
    let unit: String

    enum CodingKeys: String, CodingKey {
        case metric, value, baseline, unit
        case deltaAbs = "delta_abs"
        case deltaPct = "delta_pct"
        case zScore = "z_score"
    }
}

struct EnergyBank: Decodable, Sendable {
    let capacity: Int
    let current: Int
    let drainSoFar: Int
    let strain: Int
    let stress: Int
    let actionVerdict: String
    let verdictReason: String
    let components: [EnergyBankComponent]?

    enum CodingKeys: String, CodingKey {
        case capacity, current, strain, stress, components
        case drainSoFar = "drain_so_far"
        case actionVerdict = "action_verdict"
        case verdictReason = "verdict_reason"
    }
}

struct EnergyBankComponent: Decodable, Sendable {
    let name: String
    let value: Int
    let note: String
}

struct BriefingSection: Decodable, Sendable, Identifiable {
    var id: String { key }
    let key: String
    let title: String
    let icon: String?
    let status: String
    let summary: String
    let details: [BriefingDetail]?
}

struct BriefingDetail: Decodable, Sendable, Hashable {
    let label: String
    let value: String
    let note: String?
    let trend: String?
}

struct MetricCard: Decodable, Sendable, Identifiable {
    var id: String { metric }
    let name: String
    let metric: String
    let value: String
    let unit: String
    let trendPct: Double?
    let trendLabel: String?
    let trendStatus: String?
    let trend7dPct: Double?
    let trend7dLabel: String?
    let trend7dStatus: String?
    let trend30dPct: Double?
    let trend30dLabel: String?
    let trend30dStatus: String?

    enum CodingKeys: String, CodingKey {
        case name, metric, value, unit
        case trendPct = "trend_pct"
        case trendLabel = "trend_label"
        case trendStatus = "trend_status"
        case trend7dPct = "trend_7d_pct"
        case trend7dLabel = "trend_7d_label"
        case trend7dStatus = "trend_7d_status"
        case trend30dPct = "trend_30d_pct"
        case trend30dLabel = "trend_30d_label"
        case trend30dStatus = "trend_30d_status"
    }
}

struct Alert: Decodable, Sendable, Hashable {
    let text: String
    let severity: String
    let metric: String?
}

struct Insight: Decodable, Sendable, Hashable {
    let text: String
    let type: String
}

struct CorrelationPoint: Decodable, Sendable {
    let date: String
    let load: Double
    let hrv: Double
}

struct SleepAnalysis: Decodable, Sendable {
    let nights: Int
    let totalAvg: Double
    let deepAvg: Double
    let remAvg: Double
    let awakeAvg: Double
    let efficiency: Double
    let sources: [SleepSourceSummary]?

    enum CodingKeys: String, CodingKey {
        case nights, efficiency, sources
        case totalAvg = "total_avg"
        case deepAvg = "deep_avg"
        case remAvg = "rem_avg"
        case awakeAvg = "awake_avg"
    }
}

struct SleepSourceSummary: Decodable, Sendable, Identifiable {
    var id: String { source }
    let source: String
    let total: Double
    let deep: Double
    let rem: Double
    let core: Double
    let awake: Double
}

// MARK: - AI briefing (separate endpoint, never blocks)

/// Response from `/api/ai-briefing`. The narrative now lives in its own
/// endpoint so a cold cache doesn't block `/api/health-briefing`. Clients
/// poll this endpoint until `generating == false` and `insight != ""`.
///
/// `disabled == true` means the tenant has no Gemini API key configured —
/// the AI section should be hidden entirely rather than left in a loading
/// state forever.
struct AIBriefingResponse: Decodable, Sendable {
    let date: String
    let lang: String
    /// Joined SLEEP / YESTERDAY / RECOVERY / RECOMMENDATION text.
    /// Empty when cache is cold or AI is disabled.
    let insight: String
    /// Per-block dict, e.g. `["SLEEP": "...", "RECOVERY": "..."]`.
    /// Always present; empty when no blocks are cached yet.
    let blocks: [String: String]
    /// True when the server is currently regenerating the briefing in a
    /// background goroutine. Clients should keep polling until this flips
    /// to false.
    let generating: Bool
    /// True when the tenant has no AI configured.
    let disabled: Bool
}

// MARK: - Readiness history

struct ReadinessPoint: Decodable, Sendable, Identifiable, Hashable {
    var id: String { date }
    let date: String
    let score: Int
}

// MARK: - Lean dashboard (cards-only)

struct DashboardResponse: Decodable, Sendable {
    let date: String
    let lastUpdated: String?
    let cards: [CardData]?

    enum CodingKeys: String, CodingKey {
        case date, cards
        case lastUpdated = "last_updated"
    }
}

struct CardData: Decodable, Sendable, Identifiable {
    var id: String { metric }
    let metric: String
    let value: Double
    let prev: Double?
    let unit: String
    let date: String
}

// MARK: - Latest values

struct LatestValue: Decodable, Sendable, Identifiable {
    var id: String { metric }
    let metric: String
    let value: Double
    let unit: String
    let date: String
}

// MARK: - Metric list / data / range

struct MetricSummary: Decodable, Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    /// Localized human-readable name from the server (depends on `?lang=`).
    /// Falls back to `name` when the server doesn't ship a translation
    /// (legacy server pre-`display_name`).
    let displayName: String?
    let units: String
    let count: Int
    let min: String
    let max: String

    /// Server shipped two shapes in the wild:
    ///  - new: `name`, `units`, `count`, `min`, `max`, `display_name`
    ///  - legacy: `Name`, `Units`, `Count`, `Min`, `Max` (Go default JSON)
    /// Decode both so the iOS app keeps working before the server ships
    /// the new endpoint.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func str(_ keys: String...) throws -> String {
            for k in keys {
                if let v = try? c.decode(String.self, forKey: AnyKey(k)) { return v }
            }
            throw DecodingError.keyNotFound(
                AnyKey(keys.first ?? ""),
                .init(codingPath: c.codingPath,
                      debugDescription: "none of \(keys) present")
            )
        }
        func int(_ keys: String...) throws -> Int {
            for k in keys {
                if let v = try? c.decode(Int.self, forKey: AnyKey(k)) { return v }
            }
            throw DecodingError.keyNotFound(
                AnyKey(keys.first ?? ""),
                .init(codingPath: c.codingPath,
                      debugDescription: "none of \(keys) present")
            )
        }
        self.name  = try str("name", "Name")
        self.units = try str("units", "Units")
        self.count = try int("count", "Count")
        self.min   = try str("min", "Min")
        self.max   = try str("max", "Max")
        self.displayName = try? c.decode(String.self, forKey: AnyKey("display_name"))
    }

    private struct AnyKey: CodingKey, Hashable {
        let stringValue: String
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
}

struct MetricDataResponse: Decodable, Sendable {
    let metric: String
    let bucket: String
    let agg: String
    let points: [DataPoint]?
    let bySource: Bool?
    let pointsBySource: [SourceDataPoints]?

    enum CodingKeys: String, CodingKey {
        case metric, bucket, agg, points
        case bySource = "by_source"
        case pointsBySource = "points_by_source"
    }
}

struct DataPoint: Decodable, Sendable, Hashable {
    let date: String
    let qty: Double
    let min: Double?
    let max: Double?
}

struct SourceDataPoints: Decodable, Sendable, Identifiable {
    var id: String { source }
    let source: String
    let points: [DataPoint]
}

struct MetricDateRange: Decodable, Sendable {
    let min: String
    let max: String
}

// MARK: - Section detail (/api/section/{key})

struct SectionResponse: Decodable, Sendable {
    let key: String
    let title: String
    let summary: String
    let details: [SectionDetail]
    let charts: [SectionChart]
    let explains: [SectionExplain]
}

struct SectionDetail: Decodable, Sendable, Hashable {
    let label: String
    let value: String
    let trend: String?
    let note: String?
}

struct SectionChart: Decodable, Sendable, Hashable {
    let metric: String?
    let agg: String?
    let label: String
    let unit: String?
    let color: String?
    let type: String?
    let stacked: Bool?
    let virtual: Bool?
}

struct SectionExplain: Decodable, Sendable, Hashable {
    let title: String
    let body: String
}

// MARK: - Section catalogue

/// Catalogue of detail-page sections returned by `GET /api/sections?lang=`
/// (`health_dashboard` PR #90). Drives the Trends tab's row list — added
/// to replace the previous hardcoded three-row block whose titles and
/// subtitles never localized. New section keys appearing on the server
/// auto-surface in Trends without an App Store release.
struct SectionsCatalogueResponse: Decodable, Sendable {
    let sections: [SectionCatalogueEntry]
}

struct SectionCatalogueEntry: Decodable, Sendable, Identifiable, Hashable {
    var id: String { key }
    /// Stable routing identifier — matches `/api/section/{key}` path,
    /// used to navigate into `SectionDetailView`.
    let key: String
    /// Server-localized title (`section_<key>_title` i18n key).
    let title: String
    /// Server-localized subtitle (`section_<key>_subtitle` i18n key).
    let subtitle: String
    /// Abstract token: `heart` / `activity` / `leaf` / future values.
    /// iOS maps to SF Symbol + DS tint client-side because both are
    /// design semantics, not translations. Unknown values fall back
    /// to a generic glyph so a server-added section still renders.
    let icon: String
}

// MARK: - User / tenant settings

/// Server returns a heavy payload that mostly belongs to the web (Telegram,
/// reports). We only decode the fields the mobile app actually shows.
/// `username` / `tenant` / `isAdmin` are optional — older servers (pre PR #18)
/// don't ship them; the iOS Account block degrades to "unknown" gracefully.
struct UserSettings: Decodable, Sendable {
    let timezone: String?
    let reportLang: String?
    let username: String?
    let tenant: String?
    let isAdmin: Bool?

    enum CodingKeys: String, CodingKey {
        case timezone, username, tenant
        case reportLang = "report_lang"
        case isAdmin = "is_admin"
    }
}
