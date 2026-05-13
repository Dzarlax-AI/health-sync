import Foundation
import UserNotifications
import HealthKit

@MainActor
@Observable
final class SyncEngine {
    static let shared = SyncEngine()

    private(set) var isSyncing = false
    private(set) var lastSync: Date? = nil
    private(set) var lastPointCount: Int = 0
    private(set) var lastError: String? = nil
    private(set) var history: [SyncEntry] = []
    /// Set during chunked re-syncs (e.g. syncFullDays). nil otherwise.
    private(set) var resyncProgress: (current: Int, total: Int)? = nil

    private let defaults = UserDefaults.standard
    private let lastSyncKey = "health-sync.last-sync-date"
    private let historyKey = "health-sync.history"
    private var foregroundTimer: Timer?

    /// Every regular incremental sync re-pulls at least this many hours back,
    /// regardless of when we last successfully synced. Apple Watch and the
    /// HealthKit sleep classifier routinely write samples for past intervals
    /// hours after the fact (e.g. a morning nap whose record gets created at
    /// 15:00 with startDate 09:14). Pure incremental sync — `since = lastSync` —
    /// would never see those late additions because their startDate is earlier
    /// than `lastSync`. Server upserts on (metric_name, date, source) so the
    /// overlap is idempotent; cost is a few extra HR/step samples per sync.
    private let runSyncOverlapHours: TimeInterval = 24

    private init() {
        lastSync = defaults.object(forKey: lastSyncKey) as? Date
        if let data = defaults.data(forKey: historyKey),
           let saved = try? JSONDecoder().decode([SyncEntry].self, from: data) {
            history = saved
            lastPointCount = saved.first(where: { $0.success })?.points ?? 0
        }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
            // Force disk flush — background tasks may be suspended before async write completes
            defaults.synchronize()
        }
    }

    // Call when app becomes active, cancel when it goes to background
    func startForegroundTimer() {
        stopForegroundTimer()
        let minutes = defaults.integer(forKey: "syncIntervalMinutes")
        let interval = TimeInterval((minutes > 0 ? minutes : 15) * 60)
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.syncNow() }
        }
    }

    func stopForegroundTimer() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    var syncSince: Date {
        let overlapFloor = Date().addingTimeInterval(-runSyncOverlapHours * 3600)
        if let last = lastSync {
            // Always look back at least `runSyncOverlapHours`, even if we just
            // synced a moment ago — catches late-added HK samples for past dates.
            return min(last, overlapFloor)
        }
        // Bootstrap: no anchor yet, pull the last 3 days.
        return Calendar.current.date(byAdding: .day, value: -3, to: Date()) ?? overlapFloor
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil

        do {
            try await HealthKitManager.shared.requestAuthorization()
            let since = await resolvedSyncSince()
            let metrics = try await HealthKitManager.shared.fetchAll(since: since)
            let count = metrics.reduce(0) { $0 + $1.data.count }
            let payload = HealthPayload(metrics: metrics)
            try await upload(payload)

            // Workouts ship in a separate POST to /health/workouts (the
            // server has a dedicated handler and DB table). Gated by the
            // user-facing toggle in SettingsView. Failure here does NOT
            // fail the whole sync — metric sync is the primary use case
            // and workout history catches up on the next cycle. The
            // WorkoutUploadResult.failure case already inserts its own
            // history entry with a `workouts:` prefix, so the user sees
            // both the metric-sync success line AND the workout failure
            // line.
            let workoutResult = await uploadWorkoutsIfEnabled(since: since)
            let workoutCount = workoutResult.count

            let now = Date()
            defaults.set(now, forKey: lastSyncKey)
            lastSync = now
            lastPointCount = count + workoutCount
            history.insert(SyncEntry(date: now, points: count + workoutCount, success: true, error: nil), at: 0)
            if history.count > 50 { history = Array(history.prefix(50)) }
            persistHistory()
            if defaults.bool(forKey: "notifyOnSync") { sendSyncNotification(points: count + workoutCount) }
        } catch let hkErr as HKError where hkErr.code == .errorDatabaseInaccessible {
            // Device is locked — silent skip, next BGProcessingTask will retry
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            history.insert(SyncEntry(date: Date(), points: 0, success: false, error: msg), at: 0)
            persistHistory()
        }

        isSyncing = false
    }

    // Re-syncs the last `daysBack` days, ignoring incremental checkpoints.
    // Chunks per calendar day to keep memory + payload size small and make
    // partial failures recoverable. Server upserts on (metric_name, date, source).
    // Does NOT advance `lastSync` — incremental sync continues as usual.
    func syncFullDays(daysBack: Int = 2) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        defer {
            isSyncing = false
            resyncProgress = nil
        }

        do {
            try await HealthKitManager.shared.requestAuthorization()
        } catch let hkErr as HKError where hkErr.code == .errorDatabaseInaccessible {
            return
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            history.insert(SyncEntry(date: Date(), points: 0, success: false,
                                     error: "full re-sync auth: \(msg)"), at: 0)
            persistHistory()
            return
        }

        let cal = Calendar.current
        let now = Date()
        guard let endOfToday = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now),
              let startOfFirstDay = cal.date(byAdding: .day, value: -(daysBack - 1),
                                             to: cal.startOfDay(for: now))
        else { return }

        // Build day-chunks oldest → newest
        var chunks: [(start: Date, end: Date)] = []
        var dayStart = startOfFirstDay
        while dayStart <= now {
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? endOfToday
            chunks.append((start: dayStart, end: min(dayEnd, endOfToday)))
            dayStart = dayEnd
        }

        let total = chunks.count
        var totalPoints = 0
        var failed = 0
        var firstError: String? = nil
        // +1 chunk for the up-front sleep payload that covers the entire
        // re-sync window in one go (see fetchSleepOnly). Server unions all
        // dates and runs UpsertRecentCache once after the last chunk lands.
        let session = SyncSession(id: UUID().uuidString, total: total + 1)

        // Sleep is fetched in a SINGLE pass for the whole window. Per-day
        // chunking caused later chunks to overwrite earlier ones whenever
        // a chunk's 12h overlap saw only a partial slice of a sleep session
        // (e.g. one chunk had the full 8h night, the next had only the 1h
        // afternoon nap whose wake-up landed on the same date — server's
        // UPSERT then dropped the 8h record to 1h).
        do {
            let sleepMetrics = try await HealthKitManager.shared.fetchSleepOnly(
                since: startOfFirstDay, until: endOfToday
            )
            let sleepCount = sleepMetrics.reduce(0) { $0 + $1.data.count }
            try await upload(HealthPayload(metrics: sleepMetrics), session: session)
            totalPoints += sleepCount
        } catch let hkErr as HKError where hkErr.code == .errorDatabaseInaccessible {
            firstError = "device locked"
            failed += total + 1
        } catch {
            failed += 1
            if firstError == nil { firstError = "sleep pass: \(error.localizedDescription)" }
        }

        // If the sleep pass failed with a device-lock the loop below short-circuits;
        // otherwise we still process per-day chunks for the rest of the metrics
        // (HR, steps, etc.) — sleep is excluded via includeSleep:false.
        if !(failed > total) {
        for (idx, chunk) in chunks.enumerated() {
            resyncProgress = (current: idx + 2, total: total + 1)
            do {
                let metrics = try await HealthKitManager.shared.fetchAll(
                    since: chunk.start, until: chunk.end, includeSleep: false
                )
                let count = metrics.reduce(0) { $0 + $1.data.count }
                let payload = HealthPayload(metrics: metrics)
                // Always send — even empty payloads count toward the session's
                // chunk total so the server flushes once at the end.
                try await upload(payload, session: session)
                totalPoints += count
            } catch let hkErr as HKError where hkErr.code == .errorDatabaseInaccessible {
                // device locked mid-resync — abort the rest, the daily task will pick up
                firstError = firstError ?? "device locked"
                failed += (total - idx)
                break
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
                // continue with the next day; partial progress is still useful
            }
        }
        }

        // Workouts: one extra POST covering the whole re-sync window.
        // Server upserts on workout UUID so resending is idempotent. We
        // do this AFTER metric chunks so a workout's daily metric context
        // is already in the DB when the workout row lands. Treat the
        // workouts upload as its own "chunk" for summary accounting so a
        // workout-only failure surfaces in the success report rather
        // than being hidden by the otherwise-clean metric chunks.
        let workoutResult = await uploadWorkoutsIfEnabled(
            since: startOfFirstDay, until: endOfToday
        )
        totalPoints += workoutResult.count
        let workoutChunkCounted = 1
        var workoutChunkFailed = 0
        if let workoutErr = workoutResult.errorMessage {
            workoutChunkFailed = 1
            if firstError == nil { firstError = "workouts: \(workoutErr)" }
        }

        let summary: String
        let totalChunks = total + 1 + workoutChunkCounted // +1 sleep pass, +1 workouts
        let totalFailed = failed + workoutChunkFailed
        if totalFailed == 0 {
            summary = "full re-sync (last \(daysBack)d, \(totalChunks) chunks)"
        } else {
            summary = "full re-sync \(totalChunks - totalFailed)/\(totalChunks) chunks ok" +
                      (firstError.map { " — \($0)" } ?? "")
        }
        history.insert(
            SyncEntry(date: Date(), points: totalPoints, success: totalFailed == 0, error: summary),
            at: 0
        )
        if history.count > 50 { history = Array(history.prefix(50)) }
        persistHistory()
        if totalFailed > 0 { lastError = firstError }
    }

    // Returns the earliest date to sync from. Picks the EARLIEST of:
    //   - server checkpoint − 1h buffer (when reachable)
    //   - local syncSince  (≤ now − overlap floor; never just `lastSync`)
    // so we always look back at least one overlap window even if both the
    // server and local anchor say "you're up to date".
    private func resolvedSyncSince() async -> Date {
        let fallback = syncSince
        guard
            let serverURL = defaults.string(forKey: "serverURL"), !serverURL.isEmpty,
            let url = URL(string: serverURL + "/health/checkpoint")
        else { return fallback }

        var req = URLRequest(url: url, timeoutInterval: 10)
        if let key = KeychainStore.apiKey, !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "X-API-Key")
        }

        guard
            let (data, response) = try? await URLSession.shared.data(for: req),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONDecoder().decode([String: Int64].self, from: data),
            let unixTS = json["latest_unix"], unixTS > 0
        else { return fallback }

        // Use server date minus 1 hour buffer, but never earlier than fallback
        let serverDate = Date(timeIntervalSince1970: TimeInterval(unixTS))
        let buffered = serverDate.addingTimeInterval(-3600)
        return min(buffered, fallback)  // pick the earlier date so we don't miss anything
    }

    private func sendSyncNotification(points: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Health Sync")
        content.body = String(localized: "Synced \(points) data points")
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Optional batched-sync hint for the server. When set, the server holds
    /// off on the per-POST cache rebuild until `total` chunks of `id` arrive
    /// (or a safety timeout fires) and runs aggregation once for the union.
    struct SyncSession {
        let id: String
        let total: Int
    }

    /// Outcome of one workout-upload attempt. Callers use this to keep
    /// metric sync non-fatal while still surfacing workout failures in
    /// summaries (the previous Int-returning shape collapsed disabled /
    /// no-data / failure into the same `0`, so `syncFullDays` reported
    /// "all chunks ok" even when the workout backfill silently failed —
    /// flagged by CodeRabbit on PR #3).
    enum WorkoutUploadResult {
        case disabled
        case uploaded(Int)              // 0 means "no new workouts"
        case failure(String)            // already logged into history

        var count: Int {
            if case .uploaded(let n) = self { return n }
            return 0
        }
        var errorMessage: String? {
            if case .failure(let m) = self { return m }
            return nil
        }
    }

    /// Fetches and uploads workouts when the user has enabled the feature.
    /// On error: logs into history with a `workouts:` prefix and returns
    /// `.failure(msg)` so callers can decide whether to mark the parent
    /// sync as degraded. Errors do NOT propagate as throws — the metric-
    /// sync path stays non-fatal.
    private func uploadWorkoutsIfEnabled(since: Date, until: Date? = nil) async -> WorkoutUploadResult {
        let syncWorkouts = (defaults.object(forKey: "syncWorkouts") as? Bool) ?? true
        guard syncWorkouts else { return .disabled }
        let includeHRTimeline = (defaults.object(forKey: "workoutHRTimeline") as? Bool) ?? true
        do {
            let items = try await HealthKitManager.shared.fetchWorkouts(
                since: since, until: until, includeHRTimeline: includeHRTimeline
            )
            guard !items.isEmpty else { return .uploaded(0) }
            try await uploadWorkouts(WorkoutsPayload(items: items))
            return .uploaded(items.count)
        } catch {
            let msg = error.localizedDescription
            history.insert(SyncEntry(
                date: Date(), points: 0, success: false,
                error: "workouts: \(msg)"
            ), at: 0)
            persistHistory()
            return .failure(msg)
        }
    }

    private func upload(_ payload: HealthPayload, session: SyncSession? = nil) async throws {
        let serverURL = defaults.string(forKey: "serverURL") ?? ""
        guard !serverURL.isEmpty, let url = URL(string: serverURL + "/health") else {
            throw SyncError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = KeychainStore.apiKey, !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
        if let session {
            req.setValue(session.id, forHTTPHeaderField: "X-Sync-Session")
            req.setValue(String(session.total), forHTTPHeaderField: "X-Sync-Session-Total")
        }
        req.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw SyncError.httpError(code)
        }
    }

    /// Twin of `upload` that hits the workouts endpoint. Kept separate
    /// rather than overloading `upload` because the path, payload type,
    /// and X-Sync-Session semantics differ — workouts batch as a single
    /// POST, no chunking.
    private func uploadWorkouts(_ payload: WorkoutsPayload) async throws {
        let serverURL = defaults.string(forKey: "serverURL") ?? ""
        guard !serverURL.isEmpty, let url = URL(string: serverURL + "/health/workouts") else {
            throw SyncError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = KeychainStore.apiKey, !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
        req.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw SyncError.httpError(code)
        }
    }

    enum SyncError: LocalizedError {
        case invalidURL
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:        return "Invalid server URL"
            case .httpError(let c):  return "HTTP \(c)"
            }
        }
    }
}
