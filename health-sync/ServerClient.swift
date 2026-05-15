import Foundation

// MARK: - Errors

enum ServerError: LocalizedError {
    case missingConfig
    case invalidURL
    case http(Int, String?)
    case redirected(to: String)
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

    init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config,
                                  delegate: NoRedirectDelegate(),
                                  delegateQueue: nil)
        self.decoder = JSONDecoder()
    }

    // MARK: Config

    private func config() throws -> (base: URL, key: String) {
        var urlString = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlString.hasSuffix("/") { urlString.removeLast() }
        guard !urlString.isEmpty, let base = URL(string: urlString) else {
            throw ServerError.missingConfig
        }
        guard let key = KeychainStore.apiKey, !key.isEmpty else {
            throw ServerError.missingConfig
        }
        return (base, key)
    }

    private func makeRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        let (base, key) = try config()
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
        let req = try makeRequest(path: path, query: query)
        let (data, response) = try await session.data(for: req)
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
    private func serverLang() async -> String {
        if let cachedLang { return cachedLang }
        do {
            let settings = try await get(UserSettings.self, path: "/api/settings")
            let lang = settings.reportLang ?? "en"
            cachedLang = lang
            return lang
        } catch {
            return "en"
        }
    }

    /// Force-refresh the cached server language. Call after the user changes
    /// it on the server (web).
    func refreshServerLang() async {
        cachedLang = nil
        _ = await serverLang()
    }

    // MARK: Endpoints

    func healthBriefing() async throws -> BriefingResponse {
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

    func readinessHistory(days: Int = 30) async throws -> [ReadinessPoint] {
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
        let lang = await serverLang()
        return try await get(SectionsCatalogueResponse.self,
                             path: "/api/sections",
                             query: [URLQueryItem(name: "lang", value: lang)])
    }
}
