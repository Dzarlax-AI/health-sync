import Foundation
import HealthKit
import Observation
import UserNotifications

@MainActor
@Observable
final class SyncEngine {
    static let shared = SyncEngine()

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastPointCount = 0
    private(set) var lastError: String?
    private(set) var history: [SyncEntry] = []
    /// History rows from before account association was introduced. These
    /// remain visible only as explicitly unassociated legacy attempts.
    private(set) var legacyHistory: [SyncEntry] = []
    private(set) var resyncProgress: (current: Int, total: Int)?
    private(set) var uiState: SyncUIState
    var status: SyncStatus { uiState.status }
    var metricsSnapshot: SyncChannelSnapshot { uiState.metrics }
    var workoutsSnapshot: SyncChannelSnapshot { uiState.workouts }
    var primaryAction: SyncPrimaryAction { uiState.primaryAction }
    var canSync: Bool { uiState.canSync }

    private let configuration: SyncConfigurationProviding
    private let health: HealthDataFetching
    private let transport: SyncTransport
    private let stateStore: SyncStateStoring
    private let defaults: UserDefaults
    private let historyStore: SyncHistoryStore
    private let clock: () -> Date
    private let productionComposition: Bool
    private var state: SyncPersistedState?
    private var timer: Timer?
    private var task: Task<SyncOutcome, Never>?
    private var activeFingerprint: String?
    private var runOwner: UUID?
    private var historyFingerprint: String?
    private var activeMetricsSince: Date?
    private var activeWorkoutsSince: Date?
    private var lastActiveLaunch: Date?
    private var transientPersistenceFailure: SyncFailure?

    private let legacyDateKey = "health-sync.last-sync-date"
    private let migrationKey = "health-sync.sync-state.legacy-migrated.v1"
    private let metricsOverlap: TimeInterval = 24 * 60 * 60

    private init() {
        configuration = UserDefaultsSyncConfiguration.shared
        health = HealthKitManager.shared
        transport = URLSessionSyncTransport()
        stateStore = SyncStateStore()
        defaults = .standard
        historyStore = SyncHistoryStore()
        clock = Date.init
        productionComposition = true
        history = []
        legacyHistory = []
        lastPointCount = 0
        uiState = Self.fixtureState ?? Self.ui(metrics: .idle, workouts: .idle, configured: false, syncing: false)
    }

    init(configuration: SyncConfigurationProviding, health: HealthDataFetching,
         transport: SyncTransport, stateStore: SyncStateStoring,
         defaults: UserDefaults, historyStore: SyncHistoryStore,
         clock: @escaping () -> Date = Date.init) {
        self.configuration = configuration; self.health = health; self.transport = transport
        self.stateStore = stateStore; self.defaults = defaults; self.historyStore = historyStore; self.clock = clock
        self.productionComposition = false
        self.history = []
        self.legacyHistory = []
        self.lastPointCount = 0
        self.uiState = Self.ui(metrics: .idle, workouts: .idle, configured: false, syncing: false)
    }

    func refreshConfiguration() {
        // UI fixtures are an explicit, test-only launch contract. Keep the
        // injected state stable while Settings and dashboard views refresh
        // configuration during navigation; never inspect credentials or
        // touch persisted/network state for this path.
        if let fixture = Self.fixtureState {
            uiState = fixture
            return
        }
        guard let config = try? configuration.snapshot() else {
            state = nil; clearVisibleAccountState(); uiState = Self.ui(metrics: .idle, workouts: .idle, configured: false, syncing: isSyncing)
            return
        }
        do {
            if historyFingerprint != nil && historyFingerprint != config.fingerprint { clearVisibleAccountState() }
            historyFingerprint = config.fingerprint
            let loaded = try loadState(config)
            history = loadVisibleHistory(config.fingerprint)
            legacyHistory = loadLegacyHistory()
            state = loaded; lastSync = loaded.metrics.acceptedAt
            lastPointCount = loaded.metrics.acceptedCount + loaded.workouts.acceptedCount
            publish(config, loaded)
            if timer != nil { startForegroundTimer() }
            BackgroundSyncManager.shared.applyConfiguration()
        } catch { setStateFailure() }
    }

    func startForegroundTimer() {
        stopForegroundTimer()
        guard !SyncRuntime.isTestMode, let config = try? configuration.snapshot() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: config.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in _ = await self?.syncNow(reason: .foregroundTimer) }
        }
    }

    func stopForegroundTimer() { timer?.invalidate(); timer = nil }

    func handleAppBecameActive() {
        startForegroundTimer()
        guard let config = try? configuration.snapshot(), config.syncOnLaunch else { return }
        let now = clock()
        guard lastActiveLaunch.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastActiveLaunch = now
        Task { _ = await syncNow(reason: .appActivation) }
    }

    func syncNow(reason: SyncReason = .manual, owner: UUID? = nil) async -> SyncOutcome {
        guard !Task.isCancelled else { return .cancelled }
        // XCTest and explicit UI fixtures must never wake HealthKit or send a
        // real request through the production singleton. Injected engines keep
        // exercising the same state machine with fakes.
        if productionComposition && SyncRuntime.isTestMode { return .disabled }
        guard let config = try? configuration.snapshot() else { return configurationFailure() }
        if let task {
            guard activeFingerprint == config.fingerprint else { return configurationFailure() }
            do { try scheduleFollowUp(config) }
            catch { return stateFailureOutcome() }
            return await waitForSyncTask(task)
        }
        do {
            var loaded = try loadState(config)
            loaded.requestedGeneration += 1
            try stateStore.save(loaded)
            state = loaded; activeFingerprint = config.fingerprint; runOwner = owner; isSyncing = true; publish(config, loaded)
            let newTask: Task<SyncOutcome, Never> = Task { @MainActor [weak self] in
                guard let self else { return SyncOutcome.cancelled }
                let outcome = await self.run(config: config, reason: reason)
                // Clear before the task publishes completion. A trigger that
                // arrives after the generation loop ends then starts a fresh
                // coordinator instead of writing work onto a dead task.
                self.isSyncing = false
                self.activeFingerprint = nil
                self.runOwner = nil
                self.activeMetricsSince = nil
                self.activeWorkoutsSince = nil
                self.refreshConfiguration()
                self.task = nil
                return outcome
            }
            task = newTask
            let result = await waitForSyncTask(newTask)
            return result
        } catch { return stateFailureOutcome() }
    }

    func retryNow() async -> SyncOutcome { await syncNow(reason: .manual) }

    func syncFullDays(daysBack: Int = 2, reason: SyncReason = .manual, owner: UUID? = nil) async -> SyncOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard let config = try? configuration.snapshot() else { return configurationFailure() }
        do {
            var loaded = try loadState(config)
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: clock())
            let start = calendar.date(byAdding: .day, value: -(max(1, daysBack) - 1), to: today) ?? today
            loaded.metrics.pendingSince = earlier(loaded.metrics.pendingSince, start)
            loaded.fullResyncStart = earlier(loaded.fullResyncStart, start)
            loaded.fullResyncEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? clock()
            loaded.fullResyncRevision = (loaded.fullResyncRevision ?? 0) + 1
            if config.workoutsEnabled { loaded.workouts.pendingSince = earlier(loaded.workouts.pendingSince, start) }
            try stateStore.save(loaded); state = loaded
        } catch { return stateFailureOutcome() }
        return await syncNow(reason: reason, owner: owner)
    }

    func cancelCurrentSync(owner: UUID? = nil) {
        guard owner == nil || owner == runOwner else { return }
        task?.cancel(); Task { await health.cancelActiveQueries() }
    }

    func testConnection() async -> ConnectionTestResult {
        if productionComposition && SyncRuntime.isTestMode {
            return .failed(.init(code: .configuration, message: "Connection testing is disabled in test mode"))
        }
        guard let config = try? configuration.snapshot() else { return .failed(configurationFailureValue) }
        do {
            try await transport.validate(configuration: config)
            guard isCurrent(config) else { return .failed(configurationFailureValue) }
            return .accepted
        }
        catch { return .failed(failure(error)) }
    }

    private func run(config: SyncConfiguration, reason: SyncReason) async -> SyncOutcome {
        var result: SyncOutcome = .acceptedNoData
        while !Task.isCancelled {
            guard var current = state, current.fingerprint == config.fingerprint else { return configurationFailure() }
            let generation = current.requestedGeneration
            let cutoff = clock()
            activeMetricsSince = metricsSince(current, cutoff)
            activeWorkoutsSince = workoutsSince(current, cutoff)
            if !config.metricGroups.isEmpty { current.metrics.pendingSince = earlier(current.metrics.pendingSince, activeMetricsSince) }
            if config.workoutsEnabled { current.workouts.pendingSince = earlier(current.workouts.pendingSince, activeWorkoutsSince) }
            // The queued lower bounds are consumed by this captured generation.
            // A later trigger writes a new value while an await is outstanding.
            current.followUpMetricsSince = nil; current.followUpWorkoutsSince = nil
            guard save(current, config) else { return stateFailureOutcome() }
            result = await runOne(config: config, cutoff: cutoff, reason: reason)
            if Task.isCancelled { return await cancelled(config) }
            guard let after = state, after.fingerprint == config.fingerprint else { return configurationFailure() }
            if after.requestedGeneration <= generation {
                var completed = after
                completed.completedGeneration = generation
                guard save(completed, config) else { return stateFailureOutcome() }
                return result
            }
        }
        return await cancelled(config)
    }

    private func runOne(config: SyncConfiguration, cutoff: Date, reason: SyncReason) async -> SyncOutcome {
        if (reason == .backgroundTask || reason == .observer || reason == .dailyResync) && !config.backgroundEnabled {
            return .disabled
        }
        if reason.mayRequestAuthorization {
            do { try await health.requestAuthorization() }
            catch { return await failBoth(config, cutoff, error) }
            guard isCurrent(config) else { return configurationFailure() }
        }
        let metric = await sendMetrics(config, cutoff, reason)
        if Task.isCancelled { return await cancelled(config) }
        let workouts = await sendWorkouts(config, cutoff, reason)
        return finish(metric, workouts, config)
    }

    private enum ChannelResult { case accepted(Int), noData, disabled, deferred(SyncFailure) }
    private enum Channel { case metrics, workouts }

    private func sendMetrics(_ config: SyncConfiguration, _ cutoff: Date, _ reason: SyncReason) async -> ChannelResult {
        guard !config.metricGroups.isEmpty else { return .disabled }
        guard var current = state, current.fingerprint == config.fingerprint else { return .deferred(configurationFailureValue) }
        if !reason.bypassesRetryDelay,
           let failure = current.metrics.failure,
           failure.code == .configuration || failure.code == .authorization || failure.code == .rejectedAck || failure.code == .partialAck { return .deferred(failure) }
        if let retry = current.metrics.retryAt, retry > clock(), !reason.bypassesRetryDelay { return .deferred(current.metrics.failure ?? retryFailure) }
        if let start = current.fullResyncStart, let end = current.fullResyncEnd {
            return await sendFullResyncMetrics(config, start, min(end, clock()), reason, current.fullResyncRevision)
        }
        let since = activeMetricsSince ?? metricsSince(current, cutoff)
        current.metrics.pendingSince = earlier(current.metrics.pendingSince, since)
        guard save(current, config) else { return .deferred(stateFailureValue) }
        do {
            let payload = try await health.fetchMetrics(groups: config.metricGroups, since: since, until: cutoff)
            guard isCurrent(config), !Task.isCancelled else { return .deferred(Task.isCancelled ? cancelledFailure : configurationFailureValue) }
            var updated = state!
            if payload.pointCount == 0 {
                clear(&updated.metrics, scanned: cutoff, count: 0, accepted: false)
                guard save(updated, config) else { return .deferred(stateFailureValue) }
                return .noData
            }
            _ = try await transport.uploadMetrics(payload, configuration: config, session: nil)
            guard isCurrent(config), !Task.isCancelled else { return .deferred(Task.isCancelled ? cancelledFailure : configurationFailureValue) }
            updated = state!; let count = payload.pointCount
            clear(&updated.metrics, scanned: cutoff, count: count, accepted: true)
            guard save(updated, config) else { return .deferred(stateFailureValue) }
            return .accepted(count)
        } catch { return await fail(.metrics, config, since, error) }
    }

    private func sendFullResyncMetrics(_ config: SyncConfiguration, _ start: Date, _ end: Date, _ reason: SyncReason, _ revision: Int?) async -> ChannelResult {
        let calendar = Calendar.current
        var days: [(Date, Date)] = []
        var cursor = start
        while cursor < end { let next = min(calendar.date(byAdding: .day, value: 1, to: cursor) ?? end, end); days.append((cursor, next)); cursor = next }
        let sleepSelected = config.metricGroups.contains(.sleep)
        let other = config.metricGroups.subtracting([.sleep])
        let total = (other.isEmpty ? 0 : days.count) + (sleepSelected ? 1 : 0)
        let session = SyncUploadSession(id: UUID().uuidString, total: total)
        var count = 0
        do {
            if sleepSelected {
                let sleep = try await health.fetchMetrics(groups: [.sleep], since: start, until: end)
                guard isCurrent(config), !Task.isCancelled else { return .deferred(Task.isCancelled ? cancelledFailure : configurationFailureValue) }
                _ = try await transport.uploadMetrics(sleep, configuration: config, session: session)
                guard isCurrent(config), !Task.isCancelled else { return .deferred(Task.isCancelled ? cancelledFailure : configurationFailureValue) }
                count += sleep.pointCount
            }
            if !other.isEmpty { for (dayStart, dayEnd) in days {
                let metrics = try await health.fetchMetrics(groups: other, since: dayStart, until: dayEnd)
                guard isCurrent(config), !Task.isCancelled else { return .deferred(Task.isCancelled ? cancelledFailure : configurationFailureValue) }
                _ = try await transport.uploadMetrics(metrics, configuration: config, session: session)
                guard isCurrent(config), !Task.isCancelled else { return .deferred(Task.isCancelled ? cancelledFailure : configurationFailureValue) }
                count += metrics.pointCount
            } }
            guard isCurrent(config), var updated = state else { return .deferred(configurationFailureValue) }
            // Even an empty full-resync payload is a strict server receipt: it
            // completes a session chunk and must be visible as accepted.
            clear(&updated.metrics, scanned: end, count: count, accepted: total > 0)
            if updated.fullResyncStart == start && updated.fullResyncRevision == revision { updated.fullResyncStart = nil; updated.fullResyncEnd = nil; updated.fullResyncRevision = nil }
            guard save(updated, config) else { return .deferred(stateFailureValue) }
            return .accepted(count)
        } catch { return await fail(.metrics, config, start, error) }
    }

    private func sendWorkouts(_ config: SyncConfiguration, _ cutoff: Date, _ reason: SyncReason) async -> ChannelResult {
        guard config.workoutsEnabled else { return .disabled }
        guard var current = state, current.fingerprint == config.fingerprint else { return .deferred(configurationFailureValue) }
        if !reason.bypassesRetryDelay,
           let failure = current.workouts.failure,
           failure.code == .configuration || failure.code == .authorization || failure.code == .rejectedAck || failure.code == .partialAck { return .deferred(failure) }
        if let retry = current.workouts.retryAt, retry > clock(), !reason.bypassesRetryDelay { return .deferred(current.workouts.failure ?? retryFailure) }
        let since = activeWorkoutsSince ?? workoutsSince(current, cutoff)
        current.workouts.pendingSince = earlier(current.workouts.pendingSince, since)
        guard save(current, config) else { return .deferred(stateFailureValue) }
        var cursor = Calendar.current.startOfDay(for: since), count = 0
        var acceptedAny = false
        while cursor < cutoff {
            let next = min(Calendar.current.date(byAdding: .day, value: 1, to: cursor) ?? cutoff, cutoff)
            do {
                let items = try await health.fetchWorkouts(since: cursor, until: next, includeHRTimeline: config.workoutHRTimeline)
                guard isCurrent(config), !Task.isCancelled else { return .deferred(Task.isCancelled ? cancelledFailure : configurationFailureValue) }
                if !items.isEmpty {
                    _ = try await transport.uploadWorkouts(WorkoutsPayload(items: items), configuration: config)
                    count += items.count
                    acceptedAny = true
                }
                guard isCurrent(config), !Task.isCancelled else { return .deferred(Task.isCancelled ? cancelledFailure : configurationFailureValue) }
                var updated = state!
                clear(&updated.workouts, scanned: next, count: count, accepted: !items.isEmpty)
                // The receipt timestamp records delivery, not the cursor. Keep
                // the next unsent boundary durable until every historical day
                // has been scanned, so a relaunch cannot skip the tail.
                updated.workouts.pendingSince = next < cutoff ? next : nil
                if acceptedAny { updated.workouts.lastAttemptStatus = .accepted }
                guard save(updated, config) else { return .deferred(stateFailureValue) }
            } catch { return await fail(.workouts, config, cursor, error) }
            cursor = next
        }
        return count == 0 ? .noData : .accepted(count)
    }

    private func clear(_ channel: inout ChannelSyncState, scanned: Date, count: Int, accepted: Bool) {
        channel.scannedThrough = scanned; channel.pendingSince = nil; channel.retryAttempt = 0; channel.retryAt = nil; channel.failure = nil
        channel.lastAttemptStatus = accepted ? .accepted : .noData
        if accepted { channel.acceptedAt = clock(); channel.acceptedCount = count }
    }

    private func fail(_ channel: Channel, _ config: SyncConfiguration, _ since: Date, _ error: Error) async -> ChannelResult {
        guard var updated = state, isCurrent(config) else { return .deferred(configurationFailureValue) }
        var value = channel == .metrics ? updated.metrics : updated.workouts
        let valueFailure = failure(error)
        value.pendingSince = earlier(value.pendingSince, since); value.failure = valueFailure
        if valueFailure.code == .transport {
            value.retryAttempt += 1; value.retryAt = retryDate(value.retryAttempt, error)
        } else { value.retryAt = nil }
        value.lastAttemptStatus = value.retryAt == nil ? .error : .retryPending
        if channel == .metrics { updated.metrics = value } else { updated.workouts = value }
        guard save(updated, config) else { return .deferred(stateFailureValue) }
        return .deferred(valueFailure)
    }

    private func failBoth(_ config: SyncConfiguration, _ cutoff: Date, _ error: Error) async -> SyncOutcome {
        _ = await fail(.metrics, config, metricsSince(state ?? .empty(fingerprint: config.fingerprint), cutoff), error)
        _ = await fail(.workouts, config, workoutsSince(state ?? .empty(fingerprint: config.fingerprint), cutoff), error)
        let value = failure(error)
        return value.code == .locked ? .locked : .deferred(value)
    }

    private func finish(_ metrics: ChannelResult, _ workouts: ChannelResult, _ config: SyncConfiguration) -> SyncOutcome {
        let metricCount = count(metrics), workoutCount = count(workouts)
        let firstFailure = [metrics, workouts].compactMap { if case .deferred(let f) = $0 { return f }; return nil }.first
        let result: SyncOutcome
        if let firstFailure { result = metricCount + workoutCount > 0 ? .partial(accepted: metricCount + workoutCount, failed: firstFailure) : .deferred(firstFailure) }
        else if case .accepted = metrics { result = .accepted(points: metricCount, workouts: workoutCount) }
        else if case .accepted = workouts { result = .accepted(points: metricCount, workouts: workoutCount) }
        else if case .disabled = metrics, case .disabled = workouts { result = .disabled }
        else { result = .acceptedNoData }
        record(result, config); return result
    }

    private func count(_ result: ChannelResult) -> Int { if case .accepted(let n) = result { return n }; return 0 }

    private func record(_ result: SyncOutcome, _ config: SyncConfiguration) {
        guard isCurrent(config), state?.fingerprint == config.fingerprint else { return }
        let date = clock()
        switch result {
        case .accepted(let p, let w): lastSync = date; lastPointCount = p + w; lastError = nil; recordHistory(.init(date: date, points: p + w, success: true, error: nil)); notify(p + w)
        case .acceptedNoData: lastError = nil; recordHistory(.init(date: date, points: 0, success: true, error: nil))
        case .partial(_, let f), .deferred(let f): lastError = f.message; recordHistory(.init(date: date, points: 0, success: false, error: f.message))
        default: break
        }
        if let state {
            publish(config, state)
        }
    }

    private func scheduleFollowUp(_ config: SyncConfiguration) throws {
        guard var updated = state, updated.fingerprint == config.fingerprint else { throw SyncTransportError.configuration }
        updated.requestedGeneration += 1
        updated.followUpMetricsSince = earlier(updated.followUpMetricsSince, earlier(activeMetricsSince, updated.metrics.pendingSince))
        updated.followUpWorkoutsSince = earlier(updated.followUpWorkoutsSince, earlier(activeWorkoutsSince, updated.workouts.pendingSince))
        try stateStore.save(updated); state = updated
    }

    private func loadState(_ config: SyncConfiguration) throws -> SyncPersistedState {
        var loaded = try stateStore.load(fingerprint: config.fingerprint)
        // `load` deliberately returns a fresh state for a different account;
        // persist it immediately so A → B → A cannot revive A's pending work.
        try stateStore.save(loaded)
        let now = clock()
        let oldGroups = loaded.enabledMetricGroups ?? []
        let disabledGroups = oldGroups.subtracting(config.metricGroups)
        if !disabledGroups.isEmpty {
            let heldSince = earlier(loaded.fullResyncStart, loaded.metrics.pendingSince)
            if let heldSince {
                var deferred = loaded.deferredMetricGroupSince ?? [:]
                for group in disabledGroups { deferred[group.rawValue] = earlier(deferred[group.rawValue], heldSince) }
                loaded.deferredMetricGroupSince = deferred
            }
        }
        let enabledGroups = config.metricGroups.subtracting(oldGroups)
        if !enabledGroups.isEmpty {
            var deferred = loaded.deferredMetricGroupSince ?? [:]
            var restored: Date?
            for group in enabledGroups {
                restored = earlier(restored, deferred.removeValue(forKey: group.rawValue))
            }
            if let restored {
                loaded.fullResyncStart = earlier(loaded.fullResyncStart, restored)
                loaded.fullResyncEnd = now
                loaded.fullResyncRevision = (loaded.fullResyncRevision ?? 0) + 1
            } else {
                loaded.metrics.pendingSince = earlier(loaded.metrics.pendingSince, now.addingTimeInterval(-3 * 86400))
            }
            loaded.deferredMetricGroupSince = deferred.isEmpty ? nil : deferred
        }
        if (loaded.workoutsEnabled == false && config.workoutsEnabled) ||
            (loaded.workoutHRTimeline == false && config.workoutHRTimeline) {
            loaded.workouts.pendingSince = earlier(loaded.workouts.pendingSince, now.addingTimeInterval(-7 * 86400))
        }
        loaded.enabledMetricGroups = config.metricGroups
        loaded.workoutsEnabled = config.workoutsEnabled
        loaded.workoutHRTimeline = config.workoutHRTimeline
        try stateStore.save(loaded)
        if !defaults.bool(forKey: migrationKey), let old = defaults.object(forKey: legacyDateKey) as? Date {
            loaded.metrics.acceptedAt = old; loaded.metrics.scannedThrough = old
            try stateStore.save(loaded); defaults.set(true, forKey: migrationKey)
        }
        return loaded
    }

    private func save(_ updated: SyncPersistedState, _ config: SyncConfiguration) -> Bool {
        guard updated.fingerprint == config.fingerprint, isCurrent(config) else { return false }
        do { try stateStore.save(updated); transientPersistenceFailure = nil; state = updated; publish(config, updated); return true }
        catch { setStateFailure(); return false }
    }

    private func isCurrent(_ config: SyncConfiguration) -> Bool { (try? configuration.snapshot()) == config }
    private func metricsSince(_ state: SyncPersistedState, _ cutoff: Date) -> Date {
        let checkpoint = later(state.metrics.acceptedAt, state.metrics.scannedThrough)
        let pending = earlier(state.followUpMetricsSince, state.metrics.pendingSince)
        return min(pending ?? checkpoint ?? cutoff.addingTimeInterval(-3 * 86400), cutoff.addingTimeInterval(-metricsOverlap))
    }
    private func workoutsSince(_ state: SyncPersistedState, _ cutoff: Date) -> Date {
        // acceptedAt is a receipt time and can be newer than an unfinished
        // historical cursor. Only scannedThrough advances fetch progression.
        let checkpoint = state.workouts.scannedThrough ?? state.workouts.acceptedAt
        let pending = earlier(state.followUpWorkoutsSince, state.workouts.pendingSince)
        return min(pending ?? checkpoint ?? cutoff.addingTimeInterval(-7 * 86400), cutoff.addingTimeInterval(-metricsOverlap))
    }
    private func retryDate(_ attempt: Int, _ error: Error) -> Date { if case SyncTransportError.http(_, let date) = error, let date { return date }; return clock().addingTimeInterval(min(21600, pow(2, Double(max(0, attempt - 1))) * 60)) }

    private func failure(_ error: Error) -> SyncFailure {
        if let error = error as? SyncTransportError { switch error {
        case .configuration, .unauthorized: return configurationFailureValue
        case .invalidAcknowledgement: return .init(code: .rejectedAck, message: "Server did not confirm the upload")
        case .partialAcknowledgement: return .init(code: .partialAck, message: "Server reported a partial workout upload")
        case .cancelled: return cancelledFailure
        case .redirected: return .init(code: .authorization, message: "Server rejected authentication")
        case .http(let code, _):
            let transient = code == 408 || code == 429 || code >= 500
            return .init(code: transient ? .transport : .rejectedAck, message: "Server returned HTTP \(code)")
        case .network: return .init(code: .transport, message: "Network request failed")
        } }
        if let error = error as? HKError { return error.code == .errorDatabaseInaccessible ? .init(code: .locked, message: "Device is locked") : .init(code: .healthData, message: "Health data is unavailable") }
        if error is CancellationError { return cancelledFailure }
        return .init(code: .healthData, message: "Health data sync failed")
    }

    private func configurationFailure() -> SyncOutcome { lastError = configurationFailureValue.message; return .deferred(configurationFailureValue) }
    private func stateFailureOutcome() -> SyncOutcome { setStateFailure(); return .deferred(stateFailureValue) }
    private func setStateFailure() {
        lastError = stateFailureValue.message
        transientPersistenceFailure = stateFailureValue
        let metrics = SyncChannelSnapshot(status: .error, lastAcceptedAt: uiState.metrics.lastAcceptedAt,
                                          pendingSince: uiState.metrics.pendingSince,
                                          retryAt: nil, acceptedCount: uiState.metrics.acceptedCount,
                                          failure: stateFailureValue)
        let workouts = SyncChannelSnapshot(status: .error, lastAcceptedAt: uiState.workouts.lastAcceptedAt,
                                           pendingSince: uiState.workouts.pendingSince,
                                           retryAt: nil, acceptedCount: uiState.workouts.acceptedCount,
                                           failure: stateFailureValue)
        uiState = Self.ui(metrics: metrics, workouts: workouts, configured: true, syncing: false)
    }
    private var configurationFailureValue: SyncFailure { .init(code: .configuration, message: "Configure the server URL and API key") }
    private var stateFailureValue: SyncFailure { .init(code: .statePersistence, message: "Unable to save sync state") }
    private var cancelledFailure: SyncFailure { .init(code: .cancelled, message: "Sync was cancelled") }
    private var retryFailure: SyncFailure { .init(code: .transport, message: "Retry scheduled") }
    private func cancelled(_ config: SyncConfiguration) async -> SyncOutcome { if var state, isCurrent(config) { state.metrics.failure = cancelledFailure; state.workouts.failure = cancelledFailure; _ = save(state, config) }; return .cancelled }

    private func publish(_ config: SyncConfiguration, _ state: SyncPersistedState) {
        if let failure = transientPersistenceFailure {
            let metrics = SyncChannelSnapshot(status: .error, lastAcceptedAt: state.metrics.acceptedAt, pendingSince: state.metrics.pendingSince, retryAt: nil, acceptedCount: state.metrics.acceptedCount, failure: failure)
            let workouts = SyncChannelSnapshot(status: .error, lastAcceptedAt: state.workouts.acceptedAt, pendingSince: state.workouts.pendingSince, retryAt: nil, acceptedCount: state.workouts.acceptedCount, failure: failure)
            uiState = Self.ui(metrics: metrics, workouts: workouts, configured: true, syncing: false)
            return
        }
        let metrics = snapshot(state.metrics, config.metricGroups.isEmpty ? .disabled : (isSyncing ? .sending : channelStatus(state.metrics)))
        let workouts = snapshot(state.workouts, !config.workoutsEnabled ? .disabled : (isSyncing ? .sending : channelStatus(state.workouts)))
        uiState = Self.ui(metrics: metrics, workouts: workouts, configured: true, syncing: isSyncing)
    }
    private func channelStatus(_ value: ChannelSyncState) -> SyncStatus { if value.retryAt != nil { return .retryPending }; if value.failure != nil { return .error }; return value.lastAttemptStatus ?? (value.acceptedAt == nil ? .noData : .accepted) }
    private func snapshot(_ value: ChannelSyncState, _ status: SyncStatus) -> SyncChannelSnapshot { .init(status: status, lastAcceptedAt: value.acceptedAt, pendingSince: value.pendingSince, retryAt: value.retryAt, acceptedCount: value.acceptedCount, failure: value.failure) }
    private static func ui(metrics: SyncChannelSnapshot, workouts: SyncChannelSnapshot, configured: Bool, syncing: Bool) -> SyncUIState {
        let hasError = metrics.status == .error || workouts.status == .error || metrics.status == .retryPending || workouts.status == .retryPending
        let hasAccepted = metrics.status == .accepted || workouts.status == .accepted
        let status: SyncStatus = !configured ? .notConfigured : syncing ? .sending : (hasError && hasAccepted ? .partial : (hasError ? (metrics.status == .retryPending || workouts.status == .retryPending ? .retryPending : .error) : (metrics.status == .disabled && workouts.status == .disabled ? .disabled : (hasAccepted ? .accepted : .noData))))
        let needsConfig = metrics.failure?.code == .configuration || workouts.failure?.code == .configuration || metrics.failure?.code == .authorization || workouts.failure?.code == .authorization
        let hasRetry = metrics.status == .retryPending || workouts.status == .retryPending
        let action: SyncPrimaryAction = !configured || needsConfig ? .configure : (hasRetry ? .retry : .sync)
        return .init(status: status, metrics: metrics, workouts: workouts, primaryAction: action, canSync: configured && !syncing)
    }
    private static var fixtureState: SyncUIState? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test-mode"), let status = SyncRuntime.uiFixture else { return nil }
        let acceptedAt = Date().addingTimeInterval(-600)
        let pendingSince = Date().addingTimeInterval(-300)
        let retryAt = Date().addingTimeInterval(120)
        let retryFailure = SyncFailure(code: .transport, message: "Retry scheduled")

        switch status {
        case .notConfigured:
            return .init(status: .notConfigured, metrics: .idle, workouts: .idle,
                         primaryAction: .configure, canSync: false)
        case .noData:
            let channel = SyncChannelSnapshot(status: .noData, lastAcceptedAt: nil,
                                              pendingSince: nil, retryAt: nil,
                                              acceptedCount: 0, failure: nil)
            return .init(status: .noData, metrics: channel, workouts: channel,
                         primaryAction: .sync, canSync: true)
        case .accepted:
            let metrics = SyncChannelSnapshot(status: .accepted, lastAcceptedAt: acceptedAt,
                                              pendingSince: nil, retryAt: nil,
                                              acceptedCount: 42, failure: nil)
            let workouts = SyncChannelSnapshot(status: .accepted, lastAcceptedAt: acceptedAt,
                                               pendingSince: nil, retryAt: nil,
                                               acceptedCount: 2, failure: nil)
            return .init(status: .accepted, metrics: metrics, workouts: workouts,
                         primaryAction: .sync, canSync: true)
        case .partial:
            let metrics = SyncChannelSnapshot(status: .accepted, lastAcceptedAt: acceptedAt,
                                              pendingSince: nil, retryAt: nil,
                                              acceptedCount: 42, failure: nil)
            let workouts = SyncChannelSnapshot(status: .retryPending, lastAcceptedAt: nil,
                                               pendingSince: pendingSince, retryAt: retryAt,
                                               acceptedCount: 0, failure: retryFailure)
            return .init(status: .partial, metrics: metrics, workouts: workouts,
                         primaryAction: .retry, canSync: true)
        case .retryPending:
            let channel = SyncChannelSnapshot(status: .retryPending, lastAcceptedAt: nil,
                                              pendingSince: pendingSince, retryAt: retryAt,
                                              acceptedCount: 0, failure: retryFailure)
            return .init(status: .retryPending, metrics: channel, workouts: channel,
                         primaryAction: .retry, canSync: true)
        case .sending, .error, .disabled:
            return nil
        }
    }
    private func recordHistory(_ entry: SyncEntry) {
        guard let config = try? configuration.snapshot(), state?.fingerprint == config.fingerprint else { return }
        let returned = historyStore.append(entry)
        var accounts = defaults.dictionary(forKey: "health-sync.history-accounts.v1") as? [String: String] ?? [:]
        accounts[entry.id.uuidString] = config.fingerprint
        let retained = Set(returned.map { $0.id.uuidString })
        accounts = accounts.filter { retained.contains($0.key) }
        defaults.set(accounts, forKey: "health-sync.history-accounts.v1")
        history = returned.filter { accounts[$0.id.uuidString] == config.fingerprint }
        legacyHistory = returned.filter { accounts[$0.id.uuidString] == nil }
    }
    private func loadVisibleHistory(_ fingerprint: String) -> [SyncEntry] {
        let accounts = defaults.dictionary(forKey: "health-sync.history-accounts.v1") as? [String: String] ?? [:]
        return historyStore.loadHistory().filter { accounts[$0.id.uuidString] == fingerprint }
    }
    private func loadLegacyHistory() -> [SyncEntry] {
        let accounts = defaults.dictionary(forKey: "health-sync.history-accounts.v1") as? [String: String] ?? [:]
        return historyStore.loadHistory().filter { accounts[$0.id.uuidString] == nil }
    }
    private func clearVisibleAccountState() {
        history = []; legacyHistory = []; lastError = nil; lastSync = nil; lastPointCount = 0; historyFingerprint = nil; transientPersistenceFailure = nil
    }
    private func notify(_ count: Int) { guard defaults.bool(forKey: "notifyOnSync"), !SyncRuntime.isTestMode else { return }; let content = UNMutableNotificationContent(); content.title = String(localized: "Health Sync"); content.body = String(localized: "Synced \(count) data points"); content.sound = .default; UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil)) }
}

private func earlier(_ a: Date?, _ b: Date?) -> Date? { switch (a, b) { case let (x?, y?): return min(x, y); case let (x?, nil): return x; case let (nil, y?): return y; case (nil, nil): return nil } }
private func later(_ a: Date?, _ b: Date?) -> Date? { switch (a, b) { case let (x?, y?): return max(x, y); case let (x?, nil): return x; case let (nil, y?): return y; case (nil, nil): return nil } }
