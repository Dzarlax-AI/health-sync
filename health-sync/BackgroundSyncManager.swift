import BackgroundTasks
import Foundation
import HealthKit
import UIKit

@MainActor
private final class HealthBackgroundObservers: HealthBackgroundObserving {
    private let store = HKHealthStore()
    private var queries: [HKObserverQuery] = []
    private var enabledTypes: Set<String> = []
    private let onUpdate: @MainActor @Sendable (HealthObserverCompletion, Bool) -> Void
    private let types: [HKSampleType] = [HKQuantityType(.stepCount), HKQuantityType(.heartRate),
                                         HKQuantityType(.activeEnergyBurned), HKCategoryType(.sleepAnalysis)]

    init(onUpdate: @escaping @MainActor @Sendable (HealthObserverCompletion, Bool) -> Void) { self.onUpdate = onUpdate }

    func startObservers() {
        guard queries.isEmpty else { return }
        let onUpdate = self.onUpdate
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { @Sendable _, completion, error in
                let failed = error != nil
                let acknowledgement = HealthObserverCompletion(completion)
                Task { @MainActor in onUpdate(acknowledgement, failed) }
            }
            queries.append(query)
            store.execute(query)
        }
    }

    func stopObservers() { queries.forEach { store.stop($0) }; queries.removeAll() }

    func enableDelivery() async -> Bool {
        for type in types where !enabledTypes.contains(type.identifier) {
            let success = await withCheckedContinuation { continuation in
                store.enableBackgroundDelivery(for: type, frequency: .immediate) { success, error in
                    continuation.resume(returning: success && error == nil)
                }
            }
            if success { enabledTypes.insert(type.identifier) }
        }
        return enabledTypes.count == types.count
    }

    func disableDelivery() async -> Bool {
        let success = await withCheckedContinuation { continuation in
            store.disableAllBackgroundDelivery { success, error in
                continuation.resume(returning: success && error == nil)
            }
        }
        // After any disable attempt, re-enable every type on the next on transition.
        enabledTypes.removeAll()
        return success
    }
}

/// Completes the OS callback immediately on expiration, independent of how
/// quickly the underlying network or HealthKit operation responds to cancel.
@MainActor
final class BackgroundSyncRun {
    private var waiter: Task<Void, Never>?
    private let operation: () async -> SyncOutcome
    private let cancel: () -> Void
    private var completion: ((SyncOutcome) -> Void)?

    init(operation: @escaping () async -> SyncOutcome, cancel: @escaping () -> Void,
         completion: @escaping (SyncOutcome) -> Void) {
        self.operation = operation; self.cancel = cancel; self.completion = completion
    }
    func start() {
        guard waiter == nil, completion != nil else { return }
        waiter = Task { finish(await operation()) }
    }
    func expire() {
        guard completion != nil else { return }
        waiter?.cancel()
        cancel()
        finish(.cancelled)
    }
    private func finish(_ outcome: SyncOutcome) {
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
        waiter = nil
    }
}

@MainActor
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()
    static let taskIdentifier = "com.health-sync.background-sync"
    static let dailyResyncIdentifier = "com.health-sync.daily-resync"
    static let dailyResyncDaysBack = 7

    private lazy var observers = HealthBackgroundObservers { [weak self] completion, failed in
        guard let self else { completion.finish(); return }
        self.handleObserver(completion: { completion.finish() }, failed: failed)
    }
    private lazy var coordinator = BackgroundWorkCoordinator(scheduler: SystemBackgroundScheduler(),
                                                             observers: observers, diagnostics: .shared)
    private var settings: BackgroundSettings { UserDefaultsSyncConfiguration.shared.backgroundSettings }
    private let unlockRetry = BackgroundUnlockRetry()
    private init() {}

    func registerBGTask() {
        guard !SyncRuntime.isTestMode else { return }
        for identifier in [Self.taskIdentifier, Self.dailyResyncIdentifier] {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                MainActor.assumeIsolated { Self.shared.handleBGTask(task, daily: identifier == Self.dailyResyncIdentifier) }
            }
            if !registered { BackgroundSyncDiagnostics.shared.record(.registrationFailed) }
        }
    }

    func scheduleNextSync() { applyConfiguration() }
    func scheduleDailyResync() { applyConfiguration() }

    func applyConfiguration(retryDelivery: Bool = false) {
        guard !SyncRuntime.isTestMode else { return }
        if !settings.enabled { unlockRetry.record(.disabled, intent: BackgroundRetryIntent()) }
        coordinator.apply(settings, retryDelivery: retryDelivery)
    }

    /// Called at launch, activation, and protected-data availability. Unlock
    /// notifications do not themselves guarantee that iOS launches this app.
    func recoverAfterUnlock(retryPending: Bool = true) {
        guard !SyncRuntime.isTestMode else { return }
        if UIApplication.shared.isProtectedDataAvailable {
            do { try KeychainStore.shared.migrateAccessibility() }
            catch { BackgroundSyncDiagnostics.shared.record(.keyMigrationFailed) }
        }
        applyConfiguration(retryDelivery: true)
        if retryPending, let intent = unlockRetry.beginRecovery(enabled: settings.enabled,
                protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable) {
            BackgroundSyncDiagnostics.shared.record(.unlock)
            handleObserver(completion: { self.unlockRetry.finishRecovery() }, failed: false,
                           recordTrigger: false, intent: intent)
        }
    }

    private func recordOutcome(_ outcome: SyncOutcome, intent: BackgroundRetryIntent) {
        BackgroundSyncDiagnostics.shared.recordOutcome(outcome)
        unlockRetry.record(outcome, intent: intent)
    }

    private func execute(_ intent: BackgroundRetryIntent, reason: SyncReason, owner: UUID) async -> SyncOutcome {
        if let interval = intent.fullResync {
            return await SyncEngine.shared.syncFullDays(in: interval, reason: .dailyResync, owner: owner)
        }
        return await SyncEngine.shared.syncNow(reason: reason, owner: owner)
    }

    private func handleBGTask(_ task: BGTask, daily: Bool) {
        applyConfiguration(retryDelivery: true)
        let completion = BackgroundCompletion { task.setTaskCompleted(success: $0) }
        guard settings.enabled else { completion.finish(false); return }
        BackgroundSyncDiagnostics.shared.record(daily ? .dailyResync : .backgroundTask)
        let owner = UUID()
        let intent = daily ? BackgroundRetryIntent.daily(now: Date(), daysBack: Self.dailyResyncDaysBack) : BackgroundRetryIntent()
        let run = BackgroundSyncRun(operation: {
            await self.execute(intent, reason: .backgroundTask, owner: owner)
        }, cancel: { SyncEngine.shared.cancelCurrentSync(owner: owner) }, completion: { outcome in
            Self.shared.recordOutcome(outcome, intent: intent)
            completion.finish(outcome.wasAccepted)
        })
        task.expirationHandler = {
            Task { @MainActor in
                BackgroundSyncDiagnostics.shared.record(.expired)
                run.expire()
            }
        }
        run.start()
    }

    private func handleObserver(completion: @escaping () -> Void, failed: Bool, recordTrigger: Bool = true,
                                intent: BackgroundRetryIntent = BackgroundRetryIntent()) {
        let acknowledgement = BackgroundCompletion { _ in completion() }
        if failed {
            BackgroundSyncDiagnostics.shared.record(.observerFailed)
            acknowledgement.finish(false)
            return
        }
        guard settings.enabled else { acknowledgement.finish(false); return }
        if recordTrigger { BackgroundSyncDiagnostics.shared.record(.observer) }
        let owner = UUID()
        var assertion: UIBackgroundTaskIdentifier = .invalid
        let run = BackgroundSyncRun(operation: {
            await self.execute(intent, reason: .observer, owner: owner)
        }, cancel: { SyncEngine.shared.cancelCurrentSync(owner: owner) }, completion: { outcome in
            Self.shared.recordOutcome(outcome, intent: intent)
            // Acknowledge before giving back the remaining background time.
            acknowledgement.finish(outcome.wasAccepted)
            if assertion != .invalid {
                UIApplication.shared.endBackgroundTask(assertion)
                assertion = .invalid
            }
        })
        assertion = UIApplication.shared.beginBackgroundTask(withName: "health-sync") {
            BackgroundSyncDiagnostics.shared.record(.expired)
            run.expire()
        }
        // HealthKit delivery itself provides execution time even if UIKit
        // declines an additional assertion. BG/HealthKit still control lifetime.
        run.start()
    }
}
