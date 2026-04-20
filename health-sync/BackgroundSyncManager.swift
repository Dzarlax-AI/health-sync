import Foundation
import HealthKit
import BackgroundTasks

actor BackgroundSyncManager {
    static let shared = BackgroundSyncManager()
    static let taskIdentifier = "com.health-sync.background-sync"

    private let store = HKHealthStore()
    private var debounceTask: Task<Void, Never>?
    private var observersRegistered = false

    private init() {}

    // MARK: - BGTask registration — must be called before app finishes launching

    nonisolated func registerBGTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            Task { await BackgroundSyncManager.shared.handleBGTask(task as! BGProcessingTask) }
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

    // MARK: - BGTask handler

    private func handleBGTask(_ task: BGProcessingTask) async {
        scheduleNextSync()

        let syncTask = Task { @MainActor in
            await SyncEngine.shared.syncNow()
        }

        task.expirationHandler = { syncTask.cancel() }

        _ = await syncTask.result
        task.setTaskCompleted(success: !syncTask.isCancelled)
    }

    // MARK: - HKObserverQuery + background delivery — called once after authorization

    func setupObserverQueriesIfNeeded() {
        guard !observersRegistered else { return }
        observersRegistered = true

        for type in HealthKitManager.allReadTypes {
            guard let sampleType = type as? HKSampleType else { continue }

            // Required for HealthKit to wake the app in background
            store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { _, _ in }

            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
                completionHandler() // must be called immediately
                guard error == nil else { return }
                // BGTaskScheduler deduplicates by identifier — safe to call 80+ times
                Task { await BackgroundSyncManager.shared.scheduleNextSync() }
            }
            store.execute(query)
        }
    }
}
