import Foundation
import HealthKit
import BackgroundTasks
import UIKit
import UserNotifications

// Box for mutable bg task id shared between expiration handler and async code
@MainActor
private final class BGTaskHolder {
    var id: UIBackgroundTaskIdentifier = .invalid
}

final class BackgroundSyncManager: @unchecked Sendable {
    static let shared = BackgroundSyncManager()
    static let taskIdentifier = "com.health-sync.background-sync"
    static let dailyResyncIdentifier = "com.health-sync.daily-resync"
    static let dailyResyncDaysBack = 2

    private let store = HKHealthStore()
    private let lock = NSLock()
    private var observersRegistered = false

    private init() {}

    // MARK: - BGTask registration — must be called before app finishes launching

    func registerBGTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            Task { await Self.handleBGTask(task as! BGProcessingTask) }
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.dailyResyncIdentifier,
            using: nil
        ) { task in
            Task { await Self.handleDailyResync(task as! BGProcessingTask) }
        }
    }

    func scheduleNextSync() {
        let minutes = UserDefaults.standard.integer(forKey: "syncIntervalMinutes")
        let interval = TimeInterval((minutes > 0 ? minutes : 15) * 60)
        let req = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(req)
    }

    // Schedules the next daily full-day re-sync to fire after the next 03:00 local time.
    // BG tasks run at iOS's discretion; this is an "earliest" hint, not a guarantee.
    func scheduleDailyResync() {
        let cal = Calendar.current
        let now = Date()
        var next = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 3, minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(24 * 3600)
        // Safety: if for some reason `next` is in the past, push forward 24h
        if next <= now { next = now.addingTimeInterval(24 * 3600) }

        let req = BGProcessingTaskRequest(identifier: Self.dailyResyncIdentifier)
        req.earliestBeginDate = next
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(req)
    }

    // MARK: - BGTask handler

    private static func handleBGTask(_ task: BGProcessingTask) async {
        BackgroundSyncManager.shared.scheduleNextSync()

        let syncTask = Task { @MainActor in
            await SyncEngine.shared.syncNow()
        }

        task.expirationHandler = { syncTask.cancel() }

        _ = await syncTask.result
        task.setTaskCompleted(success: !syncTask.isCancelled)
    }

    private static func handleDailyResync(_ task: BGProcessingTask) async {
        // Reschedule first so we always have a next slot queued, even if this run fails.
        BackgroundSyncManager.shared.scheduleDailyResync()

        let resyncTask = Task { @MainActor in
            await SyncEngine.shared.syncFullDays(daysBack: dailyResyncDaysBack)
        }

        task.expirationHandler = { resyncTask.cancel() }

        _ = await resyncTask.result
        task.setTaskCompleted(success: !resyncTask.isCancelled)
    }

    // MARK: - HKObserverQuery + background delivery
    //
    // Subscribe only to a small set of high-frequency "trigger" metrics.
    // When any of these fire, we sync ALL metrics. Subscribing to all 100+
    // types causes iOS to throttle background wake-ups.

    private static let triggerTypes: [HKQuantityTypeIdentifier] = [
        .stepCount,           // fires during any walking/movement
        .heartRate,           // fires ~every few minutes from Apple Watch
        .activeEnergyBurned,  // fires during activity
    ]

    func setupObserverQueriesIfNeeded() {
        lock.lock()
        if observersRegistered { lock.unlock(); return }
        observersRegistered = true
        lock.unlock()

        for id in Self.triggerTypes {
            let sampleType = HKQuantityType(id)
            store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, err in
                Self.debugNotify(title: "bgDelivery \(id.rawValue.suffix(20))",
                                 body: "ok=\(success) err=\(err?.localizedDescription ?? "-")")
            }

            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
                completionHandler() // must be called immediately
                Self.debugNotify(title: "observer fired",
                                 body: "\(id.rawValue.suffix(20)) err=\(error?.localizedDescription ?? "-")")
                guard error == nil else { return }
                Task { @MainActor in
                    // Proper bg task lifecycle — if we run out of time, iOS calls
                    // the expiration handler and we MUST end the task there or iOS
                    // punishes us with more aggressive throttling on next wake.
                    let holder = BGTaskHolder()
                    holder.id = UIApplication.shared.beginBackgroundTask(withName: "health-sync") {
                        if holder.id != .invalid {
                            UIApplication.shared.endBackgroundTask(holder.id)
                            holder.id = .invalid
                        }
                    }
                    await SyncEngine.shared.syncNow()
                    if holder.id != .invalid {
                        UIApplication.shared.endBackgroundTask(holder.id)
                        holder.id = .invalid
                    }
                }
            }
            store.execute(query)
        }
    }

    // Debug helper — remove once stable
    private static func debugNotify(title: String, body: String) {
        let n = UNMutableNotificationContent()
        n.title = title
        n.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil)
        )
    }
}
