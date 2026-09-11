import Foundation
import HealthKit
import BackgroundTasks
import UIKit

// Box for mutable bg task id shared between expiration handler and async code
@MainActor
private final class BGTaskHolder {
    var id: UIBackgroundTaskIdentifier = .invalid
    var waiter: Task<SyncOutcome, Never>?
}

@MainActor
final class BackgroundSyncManager: @unchecked Sendable {
    static let shared = BackgroundSyncManager()
    static let taskIdentifier = "com.health-sync.background-sync"
    static let dailyResyncIdentifier = "com.health-sync.daily-resync"
    // Window the nightly BGProcessingTask re-pulls. Bigger than the live sync
    // overlap because watch-side classifiers and shared-device dribbles can
    // drop samples into HK days after the fact.
    static let dailyResyncDaysBack = 7

    private let store = HKHealthStore()
    private let lock = NSLock()
    private var observersRegistered = false
    private var observers: [HKObserverQuery] = []

    private init() {}

    // MARK: - BGTask registration — must be called before app finishes launching

    func registerBGTask() {
        guard !SyncRuntime.isTestMode else { return }
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
        guard !SyncRuntime.isTestMode,
              let config = try? UserDefaultsSyncConfiguration.shared.snapshot(),
              config.backgroundEnabled else {
            cancelScheduledWork()
            return
        }
        let interval = config.interval
        let req = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(req)
    }

    // Schedules the next daily full-day re-sync to fire after the next 03:00 local time.
    // BG tasks run at iOS's discretion; this is an "earliest" hint, not a guarantee.
    func scheduleDailyResync() {
        guard !SyncRuntime.isTestMode,
              let config = try? UserDefaultsSyncConfiguration.shared.snapshot(),
              config.backgroundEnabled else {
            cancelScheduledWork()
            return
        }
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

        let owner = UUID()
        let syncTask = Task { @MainActor in
            await SyncEngine.shared.syncNow(reason: .backgroundTask, owner: owner)
        }

        task.expirationHandler = { syncTask.cancel(); Task { @MainActor in SyncEngine.shared.cancelCurrentSync(owner: owner) } }

        let outcome = await syncTask.value
        task.setTaskCompleted(success: outcome.wasAccepted)
    }

    private static func handleDailyResync(_ task: BGProcessingTask) async {
        guard let config = try? UserDefaultsSyncConfiguration.shared.snapshot(), config.backgroundEnabled else {
            task.setTaskCompleted(success: false)
            return
        }
        // Reschedule first so we always have a next slot queued, even if this run fails.
        BackgroundSyncManager.shared.scheduleDailyResync()

        let owner = UUID()
        let resyncTask = Task { @MainActor in
            await SyncEngine.shared.syncFullDays(daysBack: dailyResyncDaysBack, reason: .dailyResync, owner: owner)
        }

        task.expirationHandler = { resyncTask.cancel(); Task { @MainActor in SyncEngine.shared.cancelCurrentSync(owner: owner) } }

        let outcome = await resyncTask.value
        task.setTaskCompleted(success: outcome.wasAccepted)
    }

    // MARK: - HKObserverQuery + background delivery
    //
    // Subscribe only to a small set of high-frequency "trigger" metrics.
    // When any of these fire, we sync ALL metrics. Subscribing to all 100+
    // types causes iOS to throttle background wake-ups.

    private static let triggerQuantityTypes: [HKQuantityTypeIdentifier] = [
        .stepCount,           // fires during any walking/movement
        .heartRate,           // fires ~every few minutes from Apple Watch
        .activeEnergyBurned,  // fires during activity
    ]

    // Sleep is added to HealthKit asynchronously (often hours after the fact,
    // when the watch syncs to phone or the classifier reanalyses). Observing
    // it here means a fresh sleep_analysis sample wakes the app and triggers
    // a sync — which then pulls the last 24h overlap window, picking up the
    // late record. Sleep volume is ~1–10 samples/day, no throttling concern.
    private static let triggerCategoryTypes: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis,
    ]

    func setupObserverQueriesIfNeeded() {
        guard !SyncRuntime.isTestMode,
              let config = try? UserDefaultsSyncConfiguration.shared.snapshot(),
              config.backgroundEnabled else { return }
        lock.lock()
        if observersRegistered { lock.unlock(); return }
        observersRegistered = true
        lock.unlock()

        let quantitySampleTypes: [(label: String, type: HKSampleType)] =
            Self.triggerQuantityTypes.map { id in
                (label: id.rawValue, type: HKQuantityType(id))
            }
        let categorySampleTypes: [(label: String, type: HKSampleType)] =
            Self.triggerCategoryTypes.map { id in
                (label: id.rawValue, type: HKObjectType.categoryType(forIdentifier: id)!)
            }

        for (label, sampleType) in quantitySampleTypes + categorySampleTypes {
            store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, err in
                if !success || err != nil {
                    print("[bgDelivery] \(label.suffix(20)) ok=\(success) err=\(err?.localizedDescription ?? "-")")
                }
            }

            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
                if let error = error {
                    print("[observer] \(label.suffix(20)) err=\(error.localizedDescription)")
                    completionHandler()
                    return
                }
                Task { @MainActor in
                    defer { completionHandler() }
                    guard let config = try? UserDefaultsSyncConfiguration.shared.snapshot(),
                          config.backgroundEnabled else { return }
                    let owner = UUID()
                    // Proper bg task lifecycle — if we run out of time, iOS calls
                    // the expiration handler and we MUST end the task there or iOS
                    // punishes us with more aggressive throttling on next wake.
                    let holder = BGTaskHolder()
                    holder.id = UIApplication.shared.beginBackgroundTask(withName: "health-sync") {
                        holder.waiter?.cancel()
                        Task { @MainActor in SyncEngine.shared.cancelCurrentSync(owner: owner) }
                        if holder.id != .invalid {
                            UIApplication.shared.endBackgroundTask(holder.id)
                            holder.id = .invalid
                        }
                    }
                    let waiter = Task { @MainActor in
                        await SyncEngine.shared.syncNow(reason: .observer, owner: owner)
                    }
                    holder.waiter = waiter
                    _ = await waitForSyncTask(waiter)
                    holder.waiter = nil
                    if holder.id != .invalid {
                        UIApplication.shared.endBackgroundTask(holder.id)
                        holder.id = .invalid
                    }
                }
            }
            store.execute(query)
            observers.append(query)
        }
    }

    func cancelScheduledWork() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.dailyResyncIdentifier)
        store.disableAllBackgroundDelivery { _, _ in }
        lock.lock()
        let active = observers
        observers.removeAll()
        observersRegistered = false
        lock.unlock()
        active.forEach { store.stop($0) }
    }

    /// Called after a Settings mutation so off→on/off takes effect in this
    /// process rather than waiting for a relaunch.
    func applyConfiguration() {
        guard !SyncRuntime.isTestMode,
              let config = try? UserDefaultsSyncConfiguration.shared.snapshot() else {
            cancelScheduledWork()
            return
        }
        if config.backgroundEnabled {
            setupObserverQueriesIfNeeded()
            scheduleNextSync()
            scheduleDailyResync()
        } else {
            cancelScheduledWork()
        }
    }

}
