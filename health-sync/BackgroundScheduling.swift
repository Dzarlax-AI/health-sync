import BackgroundTasks
import Foundation

struct BackgroundSettings: Equatable {
    var enabled: Bool
    var interval: TimeInterval
}

struct BackgroundRequest: Equatable {
    let identifier: String
    let earliest: Date?
}

@MainActor
protocol BackgroundTaskScheduling {
    func pending() async -> [BackgroundRequest]
    func submit(_ request: BackgroundRequest) throws
    func cancelAll()
}

@MainActor
struct SystemBackgroundScheduler: BackgroundTaskScheduling {
    func pending() async -> [BackgroundRequest] {
        await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { requests in
                continuation.resume(returning: requests.map { .init(identifier: $0.identifier, earliest: $0.earliestBeginDate) })
            }
        }
    }
    func submit(_ request: BackgroundRequest) throws {
        let task = BGProcessingTaskRequest(identifier: request.identifier)
        task.earliestBeginDate = request.earliest
        task.requiresNetworkConnectivity = true
        task.requiresExternalPower = false
        try BGTaskScheduler.shared.submit(task)
    }
    func cancelAll() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundSyncManager.taskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundSyncManager.dailyResyncIdentifier)
    }
}

@MainActor
enum BackgroundSchedulePolicy {
    static func requests(now: Date, interval: TimeInterval, pending: [BackgroundRequest],
                         replaceRegular: Bool, calendar: Calendar = .current) -> [BackgroundRequest] {
        let regular = BackgroundRequest(identifier: BackgroundSyncManager.taskIdentifier,
                                        earliest: now.addingTimeInterval(interval))
        let daily = BackgroundRequest(identifier: BackgroundSyncManager.dailyResyncIdentifier,
                                      earliest: calendar.nextDate(after: now, matching: DateComponents(hour: 3),
                                                                  matchingPolicy: .nextTime) ?? now.addingTimeInterval(86400))
        return [regular, daily].filter { candidate in
            guard let existing = pending.first(where: { $0.identifier == candidate.identifier }) else { return true }
            if candidate.identifier == regular.identifier && replaceRegular { return true }
            // A nil date is eligible immediately. Never replace overdue work.
            guard let existingDate = existing.earliest, let proposed = candidate.earliest else { return false }
            return proposed < existingDate
        }
    }
}

@MainActor
protocol HealthBackgroundObserving: AnyObject {
    func startObservers()
    func stopObservers()
    func enableDelivery() async -> Bool
    func disableDelivery() async -> Bool
}

/// Serializes asynchronous scheduler/delivery mutations while registering
/// queries synchronously on launch. Credentials are deliberately absent.
@MainActor
final class BackgroundWorkCoordinator {
    private let scheduler: BackgroundTaskScheduling
    private let observers: HealthBackgroundObserving
    private let diagnostics: BackgroundSyncDiagnostics
    private let clock: () -> Date
    private var desired: BackgroundSettings?
    private var revision = 0
    private var reconciliation: Task<Void, Never>?
    private var appliedDelivery: Bool?
    private var confirmedDelivery: Bool?
    private var retryDelivery = false
    private var replaceRegular = false

    init(scheduler: BackgroundTaskScheduling, observers: HealthBackgroundObserving,
         diagnostics: BackgroundSyncDiagnostics, clock: @escaping () -> Date = Date.init) {
        self.scheduler = scheduler; self.observers = observers
        self.diagnostics = diagnostics; self.clock = clock
    }

    func apply(_ settings: BackgroundSettings, retryDelivery: Bool = false) {
        if let desired, desired.interval != settings.interval { replaceRegular = true }
        self.retryDelivery = self.retryDelivery || retryDelivery
        desired = settings
        revision += 1
        if settings.enabled {
            observers.startObservers()
        } else {
            scheduler.cancelAll()
            observers.stopObservers()
        }
        guard reconciliation == nil else { return }
        reconciliation = Task { await reconcile() }
    }

    func waitUntilSettled() async { await reconciliation?.value }

    private func reconcile() async {
        while let settings = desired {
            let capturedRevision = revision
            let retry = retryDelivery
            retryDelivery = false
            if appliedDelivery != settings.enabled || retry {
                let success = settings.enabled ? await observers.enableDelivery() : await observers.disableDelivery()
                appliedDelivery = settings.enabled
                if !success {
                    confirmedDelivery = nil
                    diagnostics.record(.deliveryFailed)
                } else if confirmedDelivery != settings.enabled {
                    confirmedDelivery = settings.enabled
                    diagnostics.record(settings.enabled ? .deliveryEnabled : .disabled)
                }
            }
            // Finish an in-flight enable/disable before applying a newer state.
            if capturedRevision != revision { continue }
            if settings.enabled {
                let pending = await scheduler.pending()
                guard capturedRevision == revision else { continue }
                let requests = BackgroundSchedulePolicy.requests(now: clock(), interval: settings.interval,
                                                                  pending: pending, replaceRegular: replaceRegular)
                var succeeded = true
                for request in requests {
                    do {
                        try scheduler.submit(request)
                        if request.identifier == BackgroundSyncManager.taskIdentifier { replaceRegular = false }
                        diagnostics.record(.scheduled)
                    }
                    catch { succeeded = false; diagnostics.record(.schedulerFailed) }
                }
                if succeeded { replaceRegular = false }
            }
            break
        }
        reconciliation = nil
    }
}

@MainActor
final class BackgroundCompletion {
    private var action: ((Bool) -> Void)?
    init(_ action: @escaping (Bool) -> Void) { self.action = action }
    func finish(_ success: Bool) {
        let action = self.action
        self.action = nil
        action?(success)
    }
}
