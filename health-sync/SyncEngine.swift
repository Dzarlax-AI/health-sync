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

    private let defaults = UserDefaults.standard
    private let lastSyncKey = "health-sync.last-sync-date"

    private init() {
        lastSync = defaults.object(forKey: lastSyncKey) as? Date
    }

    var syncSince: Date {
        if let last = lastSync { return last }
        return Calendar.current.date(byAdding: .day, value: -3, to: Date()) ?? Date()
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil

        do {
            try await HealthKitManager.shared.requestAuthorization()
            await BackgroundSyncManager.shared.setupObserverQueriesIfNeeded()
            await BackgroundSyncManager.shared.scheduleNextSync()
            let since = await resolvedSyncSince()
            let metrics = try await HealthKitManager.shared.fetchAll(since: since)
            let count = metrics.reduce(0) { $0 + $1.data.count }
            let payload = HealthPayload(metrics: metrics)
            try await upload(payload)

            let now = Date()
            defaults.set(now, forKey: lastSyncKey)
            lastSync = now
            lastPointCount = count
            history.insert(SyncEntry(date: now, points: count, success: true, error: nil), at: 0)
            if history.count > 50 { history = Array(history.prefix(50)) }
            if defaults.bool(forKey: "notifyOnSync") { sendSyncNotification(points: count) }
        } catch let hkErr as HKError where hkErr.code == .errorProtectedDataNotAvailable {
            // Device is locked — silent skip, next BGProcessingTask will retry
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            history.insert(SyncEntry(date: Date(), points: 0, success: false, error: msg), at: 0)
        }

        isSyncing = false
    }

    // Returns the earliest date to sync from:
    // max(serverCheckpoint - 1h buffer, localLastSync, 3 days ago)
    // Falls back gracefully if the server is unreachable.
    private func resolvedSyncSince() async -> Date {
        let fallback = syncSince
        guard
            let serverURL = defaults.string(forKey: "serverURL"), !serverURL.isEmpty,
            let url = URL(string: serverURL + "/api/sync/checkpoint")
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
        content.title = "Health Sync"
        content.body = "Synced \(points) data points"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func upload(_ payload: HealthPayload) async throws {
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
