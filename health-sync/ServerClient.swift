import Foundation

// MARK: - Errors

enum ServerError: LocalizedError {
    case missingConfig
    case invalidURL
    case http(Int, String?)
    case redirected(to: String)
    case configurationChanged
    case unexpectedContentType(String, sample: String)
    case decode(String, sample: String)

    /// Strings interpolated through `String(localized:)` so each variant is
    /// a catalog key the user sees in their iOS locale. Format placeholders
    /// (`%lld`, `%@`) are inferred from the typed interpolation.
    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return String(localized: "Server URL or API key is not configured")
        case .invalidURL:
            return String(localized: "Invalid server URL")
        case .http(let c, let body):
            if let body, !body.isEmpty { return String(localized: "HTTP \(c): \(body)") }
            return String(localized: "HTTP \(c)")
        case .redirected(let to):
            return String(localized: "Auth required — server redirected to \(to). Check your API key or proxy (e.g. Authentik) configuration.")
        case .configurationChanged:
            return String(localized: "Server configuration changed while the request was in flight")
        case .unexpectedContentType(let ct, let sample):
            return String(localized: "Expected JSON, got \(ct). Body starts with: \(sample)")
        case .decode(let m, let sample):
            return String(localized: "Decode error: \(m). Body starts with: \(sample)")
        }
    }
}

// MARK: - Redirect-blocking delegate

/// We don't want URLSession to silently follow `302 → /login` (HTML page) on
/// auth failure — that turns "you're not logged in" into "decode error" by the
/// time we read the body. Returning nil from this delegate aborts the redirect
/// and surfaces the original 302 to the caller.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Client

/// Marked `@MainActor` rather than `actor` so it can safely use the
/// MainActor-isolated `KeychainStore.apiKey` and the project's default
/// MainActor-isolated Decodable conformances. URLSession.data releases
/// the main actor while awaiting the network round-trip, so concurrent
/// requests still overlap on the wire.
@MainActor
final class ServerClient {
    static let shared = ServerClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private var cachedLang: String?
    private var cachedLangFingerprint: String?

    private struct ClientConfiguration: Sendable, Equatable {
        let base: URL
        let key: String
        let fingerprint: String
    }

    init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config,
                                  delegate: NoRedirectDelegate(),
                                  delegateQueue: nil)
        self.decoder = JSONDecoder()
    }

    // MARK: Config

    private func config() throws -> ClientConfiguration {
        let rawURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        guard let base = UserDefaultsSyncConfiguration.normalizedEndpoint(rawURL) else {
            throw ServerError.missingConfig
        }
        let key = KeychainStore.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw ServerError.missingConfig }
        return ClientConfiguration(
            base: base,
            key: key,
            fingerprint: UserDefaultsSyncConfiguration.fingerprint(endpoint: base, apiKey: key)
        )
    }

    private func makeRequest(path: String, query: [URLQueryItem] = [],
                             configuration: ClientConfiguration) throws -> URLRequest {
        let base = configuration.base
        let key = configuration.key
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ServerError.invalidURL
        }
        comps.path = (comps.path.isEmpty ? "" : comps.path) + path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw ServerError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        if SyncRuntime.isTestMode { throw ServerError.missingConfig }
        let requestConfiguration = try config()
        let req = try makeRequest(path: path, query: query, configuration: requestConfiguration)
        let (data, response) = try await session.data(for: req)
        guard let currentConfiguration = try? config(),
              currentConfiguration.fingerprint == requestConfiguration.fingerprint else {
            throw ServerError.configurationChanged
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServerError.http(0, "no HTTP response")
        }

        let bodySample = sample(from: data)

        // Redirect (302/303/307) → auth failed. With our delegate, URLSession
        // surfaces it as a 3xx response.
        if (300..<400).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location") ?? "(unknown)"
            throw ServerError.redirected(to: location)
        }

        if !(200..<300).contains(http.statusCode) {
            throw ServerError.http(http.statusCode, bodySample)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if !contentType.contains("json") {
            throw ServerError.unexpectedContentType(contentType.isEmpty ? "(none)" : contentType,
                                                    sample: bodySample)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ServerError.decode(prettyDecodeError(error), sample: bodySample)
        }
    }

    private func sample(from data: Data, max: Int = 200) -> String {
        guard let s = String(data: data, encoding: .utf8) else {
            return "<\(data.count) bytes, non-UTF8>"
        }
        if s.count <= max { return s }
        return String(s.prefix(max)) + "…"
    }

    private func prettyDecodeError(_ error: Error) -> String {
        guard let dec = error as? DecodingError else {
            return error.localizedDescription
        }
        switch dec {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)' at \(pathString(ctx.codingPath))"
        case .typeMismatch(let type, let ctx):
            return "type mismatch (\(type)) at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            return "null for non-optional \(type) at \(pathString(ctx.codingPath))"
        case .dataCorrupted(let ctx):
            return "data corrupted at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private func pathString(_ path: [CodingKey]) -> String {
        if path.isEmpty { return "<root>" }
        return path.map { $0.stringValue }.joined(separator: ".")
    }

    // MARK: Server-side language

    /// Resolve the server-side language for content endpoints (briefing,
    /// localised metric/section names). Source of truth is the user's
    /// `report_lang` on the server — fetched once and cached. UI chrome
    /// follows iOS locale separately via String Catalog.
    private func serverLang(force: Bool = false) async -> String {
        guard !SyncRuntime.isTestMode else { return "en" }
        guard let requestConfiguration = try? config() else { return "en" }
        let fingerprint = requestConfiguration.fingerprint
        if !force, let cachedLang, cachedLangFingerprint == fingerprint { return cachedLang }
        do {
            let settings = try await get(UserSettings.self, path: "/api/settings")
            guard let currentConfiguration = try? config(),
                  currentConfiguration.fingerprint == fingerprint else {
                return "en"
            }
            let lang = settings.reportLang ?? "en"
            cachedLang = lang
            cachedLangFingerprint = fingerprint
            return lang
        } catch {
            return "en"
        }
    }

    /// Force-refresh the cached server language. Call after the user changes
    /// it on the server (web).
    func refreshServerLang() async {
        _ = await serverLang(force: true)
    }

    /// Account identity stays local and is never logged or displayed.
    func dashboardContext() throws -> String {
        if InsightFixtures.enabled { return "fixture" }
        guard !SyncRuntime.isTestMode else { throw ServerError.missingConfig }
        return try config().fingerprint + "|" + (cachedLang ?? "") + "|" + Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    func energyHistory(days: Int = 14) async throws -> EnergyHistoryResponse {
        if InsightFixtures.enabled { return try InsightFixtures.energyHistory() }
        return try await get(EnergyHistoryResponse.self, path: "/api/energy-history",
                             query: [URLQueryItem(name: "granularity", value: "day"),
                                     URLQueryItem(name: "days", value: String(days))])
    }

    // MARK: Endpoints

    func healthBriefing() async throws -> BriefingResponse {
        if InsightFixtures.enabled { return try InsightFixtures.briefing() }
        let lang = await serverLang()
        return try await get(BriefingResponse.self,
                             path: "/api/health-briefing",
                             query: [URLQueryItem(name: "lang", value: lang)])
    }

    /// Fetch the AI narrative independently of the rest of the briefing.
    /// Cold cache returns `insight: ""` + `generating: true`; the server
    /// kicks off async regen so polling this endpoint will eventually return
    /// the populated text (typically within 30-60s).
    func aiBriefing() async throws -> AIBriefingResponse {
        let lang = await serverLang()
        return try await get(AIBriefingResponse.self,
                             path: "/api/ai-briefing",
                             query: [URLQueryItem(name: "lang", value: lang)])
    }

    /// Fetches the server-owned three-domain Today snapshot. This endpoint is
    /// independent from legacy AI blocks, so factual content remains available
    /// when narrative generation is cold, disabled, or unavailable.
    func todayInsights() async throws -> TodayInsightsResponse {
        if InsightFixtures.enabled { return try InsightFixtures.snapshot() }
        let lang = await serverLang()
        return try await get(TodayInsightsResponse.self,
                             path: "/api/today-insights",
                             query: [URLQueryItem(name: "lang", value: lang)])
    }

    func readinessHistory(days: Int = 30) async throws -> [ReadinessPoint] {
        if InsightFixtures.enabled {
            return InsightFixtures.sleepNights(days: days).enumerated().map {
                ReadinessPoint(date: $0.element.date, score: 55 + $0.offset % 35)
            }
        }
        struct Wrap: Decodable { let points: [ReadinessPoint] }
        let w = try await get(Wrap.self,
                              path: "/api/readiness-history",
                              query: [URLQueryItem(name: "days", value: String(days))])
        return w.points
    }

    func dashboard() async throws -> DashboardResponse {
        try await get(DashboardResponse.self, path: "/api/dashboard")
    }

    func latestMetricValues() async throws -> [LatestValue] {
        try await get([LatestValue].self, path: "/api/metrics/latest")
    }

    func listMetrics() async throws -> [MetricSummary] {
        let lang = await serverLang()
        return try await get([MetricSummary].self,
                             path: "/api/metrics",
                             query: [URLQueryItem(name: "lang", value: lang)])
    }

    func metricData(name: String,
                    from: String? = nil,
                    to: String? = nil,
                    bucket: String? = nil,
                    bySource: Bool = false) async throws -> MetricDataResponse {
        if InsightFixtures.enabled { return InsightFixtures.metricData(name: name, from: from) }
        var q: [URLQueryItem] = [URLQueryItem(name: "metric", value: name)]
        if let from { q.append(URLQueryItem(name: "from", value: from)) }
        if let to { q.append(URLQueryItem(name: "to", value: to)) }
        if let bucket { q.append(URLQueryItem(name: "bucket", value: bucket)) }
        if bySource { q.append(URLQueryItem(name: "by_source", value: "1")) }
        return try await get(MetricDataResponse.self, path: "/api/metrics/data", query: q)
    }

    func metricRange(name: String) async throws -> MetricDateRange {
        try await get(MetricDateRange.self,
                      path: "/api/metrics/range",
                      query: [URLQueryItem(name: "metric", value: name)])
    }

    func userSettings() async throws -> UserSettings {
        try await get(UserSettings.self, path: "/api/settings")
    }

    /// Fetches the rich per-section page (recovery / sleep / activity /
    /// cardio): summary + KPI details + curated chart list + "How it works"
    /// explainer cards. Mirrors the web's section page.
    func section(_ key: String) async throws -> SectionResponse {
        if InsightFixtures.enabled {
            if key == "activity" || key == "cardio" {
                let activity = key == "activity"
                return SectionResponse(key: key, title: activity ? String(localized: "Activity") : String(localized: "Cardio"), summary: "", details: [
                    SectionDetail(label: activity ? "Steps" : "VO₂ max", value: activity ? "6,200" : "38.2", trend: "stable", note: nil),
                    SectionDetail(label: activity ? "Active calories" : "Blood oxygen", value: activity ? "360 kcal" : "98%", trend: "stable", note: nil),
                    SectionDetail(label: activity ? "Exercise" : "Respiratory rate", value: activity ? "24 min" : "16/min", trend: "stable", note: nil)
                ], charts: [SectionChart(metric: activity ? "step_count" : "vo2_max", agg: nil,
                                         label: activity ? "Daily steps" : "VO₂ max", unit: "", color: nil,
                                         type: activity ? "bar" : "line", stacked: false, virtual: false)], explains: [])
            }
            if ProcessInfo.processInfo.arguments.contains("--charts-fixture") {
                return SectionResponse(key: key, title: String(localized: "Recovery"), summary: "", details: [], charts: [
                    SectionChart(metric: nil, agg: nil, label: "Sleep stages", unit: "h", color: nil, type: "bar", stacked: true, virtual: false),
                    SectionChart(metric: "step_count", agg: nil, label: "Daily steps", unit: "", color: nil, type: "bar", stacked: false, virtual: false)
                ], explains: [])
            }
            return SectionResponse(key: key, title: String(localized: "Recovery"), summary: "", details: [
                SectionDetail(label: "HRV", value: "48 ms", trend: "stable", note: nil),
                SectionDetail(label: "Resting heart rate", value: "56 bpm", trend: "stable", note: nil)
            ], charts: [
                SectionChart(metric: nil, agg: nil, label: "Recovery history", unit: "%", color: nil, type: "line", stacked: false, virtual: true)
            ], explains: [])
        }
        let lang = await serverLang()
        return try await get(SectionResponse.self,
                             path: "/api/section/\(key)",
                             query: [URLQueryItem(name: "lang", value: lang)])
    }

    /// Lists the stable catalogue of section detail pages with
    /// server-localized title + subtitle. Used by Trends to render
    /// navigation rows dynamically instead of hardcoding the list and
    /// its labels. `health_dashboard` PR #90.
    func sections() async throws -> SectionsCatalogueResponse {
        if InsightFixtures.enabled {
            return SectionsCatalogueResponse(sections: [
                SectionCatalogueEntry(key: "recovery", title: "Recovery", subtitle: "Synthetic charts", icon: "leaf"),
                SectionCatalogueEntry(key: "activity", title: "Activity", subtitle: "Synthetic charts", icon: "figure.walk"),
                SectionCatalogueEntry(key: "cardio", title: "Cardio", subtitle: "Synthetic charts", icon: "heart")
            ])
        }
        let lang = await serverLang()
        return try await get(SectionsCatalogueResponse.self,
                             path: "/api/sections",
                             query: [URLQueryItem(name: "lang", value: lang)])
    }
}
