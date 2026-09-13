import Foundation
import SwiftData
import Testing
@testable import health_sync

@MainActor
struct SyncAttemptStateTests {
    @Test func sleepCoverageSurvivesTheDurableSyncTransport() async throws {
        let health = EmptyTestHealthData(), transport = SuccessTestTransport()
        health.metrics = [.init(name: "night_sleep_total", units: "hr", data: [.qty(date: "2026-01-01 07:00:00 +0000", value: 7, source: "Watch")])]
        health.nightSleepCoverage = [.init(
            wakeDate: "2026-01-01", metricDate: "2026-01-01 07:00:00 +0000",
            source: "Watch", sourceEpoch: "health-sync-ios-v1",
            captureCompleteness: "complete", syncGeneration: "fixture",
            coveredIntervalStart: "2025-12-31T12:00:00Z", coveredIntervalEnd: "2026-01-01T12:00:00Z"
        )]
        let engine = try makeTestSyncEngine(health: health, transport: transport, groups: [.sleep])

        #expect(await engine.syncNow() == .accepted(points: 1, workouts: 0))
        let encoded = try JSONEncoder().encode(transport.metricPayloads.first)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payloadData = try #require(object["data"] as? [String: Any])
        #expect((payloadData["night_sleep_coverage"] as? [[String: Any]])?.count == 1)
    }

    @Test func noDataAfterReceiptPreservesReceiptAndMarksScan() async throws {
        let state = InMemoryTestSyncState()
        state.value.metrics.acceptedAt = Date(timeIntervalSince1970: 10)
        let engine = try makeTestSyncEngine(state: state)
        #expect(await engine.syncNow() == .acceptedNoData)
        #expect(engine.metricsSnapshot.status == .noData)
        #expect(engine.metricsSnapshot.lastAcceptedAt == Date(timeIntervalSince1970: 10))
        #expect(engine.workoutsSnapshot.status == .disabled)
    }

    @Test func completeEmptySleepPeriodIsUploadedWithoutMetricSamples() async throws {
        let health = EmptyTestHealthData(), transport = SuccessTestTransport()
        health.sleepPeriodCoverage = [.init(
            wakeDate: "2026-01-01", sourceEpoch: "health-sync-ios-v1",
            captureCompleteness: "complete", syncGeneration: "period-1",
            coveredIntervalStart: "2025-12-31T12:00:00Z", coveredIntervalEnd: "2026-01-01T12:00:00Z"
        )]
        let engine = try makeTestSyncEngine(health: health, transport: transport, groups: [.sleep])

        #expect(await engine.syncNow() == .accepted(points: 0, workouts: 0))
        #expect(transport.metricUploadCount == 2) // initial history plus the current sleep sync
        let allPayloadsAreMeaningful = transport.metricPayloads.allSatisfy { $0.hasUploadableContent }
        #expect(allPayloadsAreMeaningful)
    }

    @Test func metrics503RetainsReceiptAndSchedulesRetry() async throws {
        let state = InMemoryTestSyncState()
        state.value.metrics.acceptedAt = Date(timeIntervalSince1970: 10)
        let health = EmptyTestHealthData()
        health.metrics = [.init(name: "heart_rate", units: "bpm", data: [.avg(date: "2026-01-01 00:00:00 +0000", value: 60, source: "Watch")])]
        let transport = SuccessTestTransport()
        transport.metricError = .http(status: 503, retryAfter: nil)
        let engine = try makeTestSyncEngine(state: state, health: health, transport: transport)
        _ = await engine.syncNow()
        #expect(engine.metricsSnapshot.lastAcceptedAt == Date(timeIntervalSince1970: 10))
        #expect(engine.metricsSnapshot.retryAt != nil)
    }

    @Test func workouts503LeavesMetricsAcceptedAndWorkoutPending() async throws {
        let state = InMemoryTestSyncState()
        let health = EmptyTestHealthData()
        health.metrics = [.init(name: "heart_rate", units: "bpm", data: [.avg(date: "2026-01-01 00:00:00 +0000", value: 60, source: "Watch")])]
        health.workouts = [.init(id: "w", name: "Walking", start: "2026-01-01 00:00:00 +0000", end: "2026-01-01 01:00:00 +0000", duration: 3600, isIndoor: false, location: "Outdoor", avgHeartRate: nil, maxHeartRate: nil, activeEnergyBurned: nil, intensity: nil, distance: nil, avgSpeed: nil, maxSpeed: nil, elevationUp: nil, temperature: nil, humidity: nil, heartRateData: [], stepCount: [])]
        let transport = SuccessTestTransport(); transport.workoutError = .http(status: 503, retryAfter: nil)
        let engine = try makeTestSyncEngine(state: state, health: health, transport: transport, workoutsEnabled: true)
        _ = await engine.syncNow()
        #expect(engine.metricsSnapshot.lastAcceptedAt != nil)
        #expect(engine.workoutsSnapshot.lastAcceptedAt == nil)
        #expect(engine.workoutsSnapshot.pendingSince != nil)
        #expect(engine.workoutsSnapshot.retryAt != nil)
        #expect(engine.status == .partial)
    }

    @Test func stateWriteFailureRetainsDurableCheckpointAndShowsTypedError() async throws {
        let state = InMemoryTestSyncState()
        state.value.metrics.acceptedAt = Date(timeIntervalSince1970: 10)
        let health = EmptyTestHealthData()
        health.metrics = [.init(name: "heart_rate", units: "bpm", data: [.avg(date: "2026-01-01 00:00:00 +0000", value: 60, source: "Watch")])]
        let transport = SuccessTestTransport()
        transport.onMetricUpload = { state.failNextSave = true }
        let engine = try makeTestSyncEngine(state: state, health: health, transport: transport)
        _ = await engine.syncNow()
        #expect(transport.metricUploadCount == 1)
        #expect(state.value.metrics.acceptedAt == Date(timeIntervalSince1970: 10))
        #expect(engine.uiState.metrics.failure?.code == .statePersistence)
        #expect(engine.uiState.status == .error)
    }

    @Test func fullResyncThreeDaysSendsSleepOnceAndOtherGroupsDailyInOneSession() async throws {
        let state = InMemoryTestSyncState()
        let health = EmptyTestHealthData()
        let transport = SuccessTestTransport()
        let engine = try makeTestSyncEngine(state: state, health: health, transport: transport, groups: [.vitals, .sleep])
        _ = await engine.syncFullDays(daysBack: 3)
        #expect(health.fetches.filter { $0.groups == [.sleep] }.count == 1)
        #expect(health.fetches.filter { $0.groups == [.vitals] }.count == 3)
        #expect(transport.sessions.count == 4)
        #expect(transport.sessions.allSatisfy { $0?.total == 4 })
        #expect(state.value.fullResyncStart == nil)
        #expect(state.value.fullResyncEnd == nil)
    }

    @Test func emptyFullResyncStillRecordsAcceptedReceipt() async throws {
        let state = InMemoryTestSyncState()
        let health = EmptyTestHealthData(), transport = SuccessTestTransport()
        let engine = try makeTestSyncEngine(state: state, health: health, transport: transport, groups: [.vitals])
        #expect(await engine.syncFullDays(daysBack: 1) == .accepted(points: 0, workouts: 0))
        #expect(transport.metricUploadCount > 0)
        #expect(engine.metricsSnapshot.lastAcceptedAt != nil)
        #expect(engine.metricsSnapshot.status == .accepted)
    }

    @Test func newAccountSeedsNinetyDaysOfSleepBeforeRegularSync() async throws {
        let state = InMemoryTestSyncState()
        let health = EmptyTestHealthData()
        health.sleepPeriodCoverage = [.init(
            wakeDate: "2026-01-01", sourceEpoch: "health-sync-ios-v1",
            captureCompleteness: "complete", syncGeneration: "initial-period",
            coveredIntervalStart: "2025-12-31T12:00:00Z", coveredIntervalEnd: "2026-01-01T12:00:00Z"
        )]
        let transport = SuccessTestTransport()
        let engine = try makeTestSyncEngine(state: state, health: health, transport: transport, groups: [.sleep])

        _ = await engine.syncNow(reason: .appActivation)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_000))
        let expectedStart = try #require(calendar.date(byAdding: .day, value: -89, to: today))
        let sleepFetches = health.fetches.filter { $0.groups == [.sleep] }
        #expect(sleepFetches.count == 2)
        #expect(sleepFetches[0].since == expectedStart)
        #expect(state.value.initialSleepHistoryState == .completed)
    }

    @Test func emptyInitialSleepQueryStaysPendingUntilThereIsAServerReceipt() async throws {
        let state = InMemoryTestSyncState()
        let health = EmptyTestHealthData(), transport = SuccessTestTransport()
        let engine = try makeTestSyncEngine(state: state, health: health, transport: transport, groups: [.sleep])

        _ = await engine.syncNow(reason: .appActivation)

        #expect(state.value.initialSleepHistoryState == .pending)
        #expect(transport.metricUploadCount == 0)
    }

    @Test func legacyAccountDoesNotReceiveUnexpectedHistoricalBackfill() async throws {
        let state = InMemoryTestSyncState()
        state.value.initialSleepHistoryState = nil
        state.value.metrics.scannedThrough = Date(timeIntervalSince1970: 900)
        let health = EmptyTestHealthData()
        let engine = try makeTestSyncEngine(state: state, health: health, groups: [.sleep])

        _ = await engine.syncNow(reason: .appActivation)

        let sleepFetch = try #require(health.fetches.first(where: { $0.groups == [.sleep] }))
        #expect(sleepFetch.since > Date(timeIntervalSince1970: 900 - 7_000_000))
        #expect(state.value.initialSleepHistoryState == .notRequired)
    }

    @Test func failedInitialSleepHistoryRemainsPendingForANextForegroundSync() async throws {
        let state = InMemoryTestSyncState()
        let health = EmptyTestHealthData()
        health.metrics = [.init(name: "night_sleep_total", units: "hr", data: [.qty(date: "2026-01-01 07:00:00 +0000", value: 7, source: "Watch")])]
        let transport = SuccessTestTransport()
        transport.metricError = .http(status: 503, retryAfter: nil)
        let engine = try makeTestSyncEngine(state: state, health: health, transport: transport, groups: [.sleep])

        _ = await engine.syncNow(reason: .appActivation)
        #expect(state.value.initialSleepHistoryState == .pending)

        transport.metricError = nil
        _ = await engine.syncNow(reason: .appActivation)
        #expect(state.value.initialSleepHistoryState == .completed)
    }

    @Test func manualNinetyDaySleepResyncCompletesTheInitialHistoryJob() async throws {
        let state = InMemoryTestSyncState()
        let health = EmptyTestHealthData()
        let engine = try makeTestSyncEngine(state: state, health: health, groups: [.sleep])

        _ = await engine.syncFullDays(daysBack: 90)

        #expect(state.value.initialSleepHistoryState == .completed)
        #expect(health.fetches.filter { $0.groups == [.sleep] }.count == 1)
    }

    @Test func deterministic400BlocksAutomaticRetryButManualRetries() async throws {
        let health = EmptyTestHealthData()
        health.metrics = [.init(name: "heart_rate", units: "bpm", data: [.avg(date: "2026-01-01 00:00:00 +0000", value: 60, source: "Watch")])]
        let transport = SuccessTestTransport(); transport.metricError = .http(status: 400, retryAfter: nil)
        let engine = try makeTestSyncEngine(health: health, transport: transport)
        _ = await engine.syncNow()
        #expect(transport.metricUploadCount == 1)
        _ = await engine.syncNow(reason: .foregroundTimer)
        #expect(transport.metricUploadCount == 1)
        _ = await engine.syncNow()
        #expect(transport.metricUploadCount == 2)
    }

    @Test func ownerBDoesNotCancelOwnerA() async throws {
        actor Gate {
            var entered: CheckedContinuation<Void, Never>?
            var release: CheckedContinuation<Void, Never>?
            func waitForEntry() async { await withCheckedContinuation { entered = $0 } }
            func suspend() async { entered?.resume(); await withCheckedContinuation { release = $0 } }
            func open() { release?.resume() }
        }
        let gate = Gate(), health = EmptyTestHealthData()
        health.onFetch = { await gate.suspend() }
        let engine = try makeTestSyncEngine(health: health)
        let ownerA = UUID(), ownerB = UUID()
        let task = Task { await engine.syncNow(owner: ownerA) }
        await gate.waitForEntry()
        engine.cancelCurrentSync(owner: ownerB)
        #expect(health.cancelCount == 0)
        await gate.open()
        #expect(await task.value == .acceptedNoData)
    }

    @Test func enablingSleepSchedulesBoundedCatchup() async throws {
        let state = InMemoryTestSyncState()
        state.value.enabledMetricGroups = [.vitals]
        state.value.metrics.scannedThrough = Date(timeIntervalSince1970: 1_000)
        let health = EmptyTestHealthData()
        let engine = try makeTestSyncEngine(state: state, health: health, groups: [.vitals, .sleep])
        _ = await engine.syncNow()
        #expect(health.fetches.first?.since ?? .distantFuture <= Date(timeIntervalSince1970: 1_000 - 3 * 86_400))
        #expect(state.value.enabledMetricGroups?.contains(.sleep) == true)
    }

    @Test func disabledThirtyDaySleepRangeIsRestoredOnReenable() async throws {
        let state = InMemoryTestSyncState()
        let now = Date(timeIntervalSince1970: 1_000)
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86_400)
        state.value.enabledMetricGroups = [.vitals, .sleep]
        state.value.fullResyncStart = thirtyDaysAgo
        state.value.fullResyncEnd = now
        state.value.fullResyncRevision = 1
        let provider = TestSyncConfiguration(), health = EmptyTestHealthData()
        let engine = try makeTestSyncEngine(state: state, health: health, groups: [.vitals, .sleep], provider: provider)
        provider.value = SyncConfiguration(endpoint: URL(string: "https://example.test")!, apiKey: "test-key", fingerprint: "test-account", metricGroups: [.vitals], workoutsEnabled: false, backgroundEnabled: true, syncOnLaunch: false, interval: 60, workoutHRTimeline: false)
        engine.refreshConfiguration()
        #expect(state.value.deferredMetricGroupSince?[MetricGroup.sleep.rawValue] == thirtyDaysAgo)
        _ = await engine.syncNow()
        #expect(state.value.fullResyncStart == nil)
        #expect(state.value.deferredMetricGroupSince?[MetricGroup.sleep.rawValue] == thirtyDaysAgo)
        health.fetches.removeAll()
        provider.value = SyncConfiguration(endpoint: URL(string: "https://example.test")!, apiKey: "test-key", fingerprint: "test-account", metricGroups: [.vitals, .sleep], workoutsEnabled: false, backgroundEnabled: true, syncOnLaunch: false, interval: 60, workoutHRTimeline: false)
        engine.refreshConfiguration()
        _ = await engine.syncNow()
        #expect(health.fetches.first(where: { $0.groups == [.sleep] })?.since == thirtyDaysAgo)
        #expect(state.value.deferredMetricGroupSince?[MetricGroup.sleep.rawValue] == nil)
    }

    @Test func disablingAGroupPreservesItsCurrentCheckpointForReenable() throws {
        let state = InMemoryTestSyncState()
        let checkpoint = Date(timeIntervalSince1970: 400)
        state.value.enabledMetricGroups = [.vitals, .sleep]
        state.value.metrics.acceptedAt = checkpoint
        state.value.metrics.scannedThrough = checkpoint
        let provider = TestSyncConfiguration()
        let engine = try makeTestSyncEngine(state: state, groups: [.vitals, .sleep], provider: provider)

        provider.value = SyncConfiguration(endpoint: URL(string: "https://example.test")!, apiKey: "test-key", fingerprint: "test-account", metricGroups: [.vitals], workoutsEnabled: false, backgroundEnabled: true, syncOnLaunch: false, interval: 60, workoutHRTimeline: false)
        engine.refreshConfiguration()
        #expect(state.value.deferredMetricGroupSince?[MetricGroup.sleep.rawValue] == checkpoint)

        provider.value = SyncConfiguration(endpoint: URL(string: "https://example.test")!, apiKey: "test-key", fingerprint: "test-account", metricGroups: [.vitals, .sleep], workoutsEnabled: false, backgroundEnabled: true, syncOnLaunch: false, interval: 60, workoutHRTimeline: false)
        engine.refreshConfiguration()
        #expect(state.value.fullResyncStart == checkpoint)
    }

    @Test func appActivationHydratesStatusWhenSyncOnLaunchIsDisabled() throws {
        let state = InMemoryTestSyncState()
        let acceptedAt = Date(timeIntervalSince1970: 400)
        state.value.metrics.acceptedAt = acceptedAt
        let engine = try makeTestSyncEngine(state: state)

        engine.handleAppBecameActive()

        #expect(engine.lastSync == acceptedAt)
        #expect(engine.metricsSnapshot.lastAcceptedAt == acceptedAt)
    }

    @Test func appActivationDoesNotStartInitialSleepHistoryWhenSyncOnLaunchIsDisabled() throws {
        let state = InMemoryTestSyncState()
        let health = EmptyTestHealthData()
        let provider = TestSyncConfiguration()
        let engine = try makeTestSyncEngine(
            state: state, health: health, groups: [.sleep], provider: provider
        )

        engine.handleAppBecameActive()

        #expect(state.value.initialSleepHistoryState == .pending)
        #expect(health.fetches.isEmpty)
    }

    @Test func refreshUsesMostRecentAcceptedChannelForLastSync() throws {
        let state = InMemoryTestSyncState()
        let metricsAt = Date(timeIntervalSince1970: 300)
        let workoutsAt = Date(timeIntervalSince1970: 400)
        state.value.metrics.acceptedAt = metricsAt
        state.value.workouts.acceptedAt = workoutsAt
        let engine = try makeTestSyncEngine(state: state, workoutsEnabled: true)

        engine.refreshConfiguration()

        #expect(engine.lastSync == workoutsAt)
    }

    @Test func strictConnectionTestSurfacesTransportFailure() async throws {
        let transport = SuccessTestTransport()
        transport.validationError = .invalidAcknowledgement
        let engine = try makeTestSyncEngine(transport: transport)

        #expect(await engine.testConnection() == .failed(.init(code: .rejectedAck, message: "Server did not confirm the upload")))
    }

    @Test func syncStateStoreRoundTripsPendingFullAndDeferredRanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SyncStateStore(directory: directory)
        var state = SyncPersistedState.empty(fingerprint: "account")
        state.metrics.pendingSince = Date(timeIntervalSince1970: 10)
        state.fullResyncStart = Date(timeIntervalSince1970: 5)
        state.fullResyncEnd = Date(timeIntervalSince1970: 20)
        state.fullResyncRevision = 2
        state.deferredMetricGroupSince = [MetricGroup.sleep.rawValue: Date(timeIntervalSince1970: 1)]
        try store.save(state)
        let reopened = SyncStateStore(directory: directory)
        let restored = try reopened.load(fingerprint: "account")
        #expect(restored.metrics.pendingSince == state.metrics.pendingSince)
        #expect(restored.fullResyncStart == state.fullResyncStart)
        #expect(restored.fullResyncEnd == state.fullResyncEnd)
        #expect(restored.deferredMetricGroupSince == state.deferredMetricGroupSince)
    }

    @Test func workoutRelaunchResumesPendingCursorInsteadOfReceiptTime() async throws {
        let state = InMemoryTestSyncState()
        let now = Date(timeIntervalSince1970: 1_000)
        let pending = Calendar.current.date(byAdding: .day, value: -29, to: now)!
        state.value.workouts.acceptedAt = now
        state.value.workouts.scannedThrough = pending
        state.value.workouts.pendingSince = pending
        let health = EmptyTestHealthData()
        let engine = try makeTestSyncEngine(state: state, health: health, workoutsEnabled: true)
        _ = await engine.syncNow()
        #expect(health.workoutFetches.first?.0 == Calendar.current.startOfDay(for: pending))
    }

    @Test func cancelledHistoricalWorkoutRunResumesAfterAcceptedFirstChunk() async throws {
        actor Gate {
            var entered: CheckedContinuation<Void, Never>?
            var release: CheckedContinuation<Void, Never>?
            func wait() async { await withCheckedContinuation { entered = $0 } }
            func block() async { entered?.resume(); await withCheckedContinuation { release = $0 } }
            func open() { release?.resume() }
        }
        let state = InMemoryTestSyncState(), gate = Gate(), health = EmptyTestHealthData()
        let now = Date(timeIntervalSince1970: 1_000)
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        health.workouts = [.init(id: "w", name: "Walking", start: "2026-01-01 00:00:00 +0000", end: "2026-01-01 01:00:00 +0000", duration: 3600, isIndoor: false, location: "Outdoor", avgHeartRate: nil, maxHeartRate: nil, activeEnergyBurned: nil, intensity: nil, distance: nil, avgSpeed: nil, maxSpeed: nil, elevationUp: nil, temperature: nil, humidity: nil, heartRateData: [], stepCount: [])]
        state.value.workouts.pendingSince = start
        health.onWorkoutFetch = { count in if count == 2 { await gate.block() } }
        let engine = try makeTestSyncEngine(state: state, health: health, workoutsEnabled: true)
        let owner = UUID(); let run = Task { await engine.syncNow(owner: owner) }
        await gate.wait()
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start))!
        #expect(state.value.workouts.pendingSince == nextDay)
        #expect(state.value.workouts.lastAttemptStatus == .accepted)
        engine.cancelCurrentSync(owner: owner)
        await gate.open(); _ = await run.value
        let relaunchedHealth = EmptyTestHealthData()
        let relaunched = try makeTestSyncEngine(state: state, health: relaunchedHealth, workoutsEnabled: true)
        _ = await relaunched.syncNow()
        #expect(relaunchedHealth.workoutFetches.first?.0 == nextDay)
    }

    @Test func trailingEmptyWorkoutChunksKeepAcceptedStatusAndCount() async throws {
        let state = InMemoryTestSyncState(), health = EmptyTestHealthData()
        let now = Date(timeIntervalSince1970: 1_000)
        state.value.workouts.pendingSince = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        health.workouts = [.init(id: "w", name: "Walking", start: "2026-01-01 00:00:00 +0000", end: "2026-01-01 01:00:00 +0000", duration: 3600, isIndoor: false, location: "Outdoor", avgHeartRate: nil, maxHeartRate: nil, activeEnergyBurned: nil, intensity: nil, distance: nil, avgSpeed: nil, maxSpeed: nil, elevationUp: nil, temperature: nil, humidity: nil, heartRateData: [], stepCount: [])]
        health.onWorkoutFetch = { count in if count > 1 { health.workouts = [] } }
        let engine = try makeTestSyncEngine(state: state, health: health, workoutsEnabled: true)
        _ = await engine.syncNow()
        #expect(engine.workoutsSnapshot.status == .accepted)
        #expect(engine.workoutsSnapshot.acceptedCount == 1)
    }

    @Test func configSwitchDuringUploadCannotPublishOldAccount() async throws {
        actor Gate {
            var entered: CheckedContinuation<Void, Never>?
            var release: CheckedContinuation<Void, Never>?
            func wait() async { await withCheckedContinuation { entered = $0 } }
            func block() async { entered?.resume(); await withCheckedContinuation { release = $0 } }
            func open() { release?.resume() }
        }
        let provider = TestSyncConfiguration(), gate = Gate(), health = EmptyTestHealthData(), transport = SuccessTestTransport()
        health.metrics = [.init(name: "heart_rate", units: "bpm", data: [.avg(date: "2026-01-01 00:00:00 +0000", value: 60, source: "Watch")])]
        transport.onMetricUploadAsync = { await gate.block() }
        let engine = try makeTestSyncEngine(health: health, transport: transport, provider: provider)
        let run = Task { await engine.syncNow() }
        await gate.wait()
        provider.value = SyncConfiguration(endpoint: URL(string: "https://other.test")!, apiKey: "other", fingerprint: "account-b", metricGroups: [.vitals], workoutsEnabled: false, backgroundEnabled: true, syncOnLaunch: false, interval: 60, workoutHRTimeline: false)
        engine.refreshConfiguration()
        await gate.open()
        _ = await run.value
        #expect(engine.metricsSnapshot.lastAcceptedAt == nil)
        #expect(engine.history.isEmpty)
        #expect(!engine.isSyncing)
        #expect(engine.status != .sending)
        #expect(engine.canSync)
    }

    @Test func historySeparatesLegacyRowsAndHidesOtherAccounts() throws {
        let defaults = UserDefaults(suiteName: "health-sync-history-isolation-\(UUID().uuidString)")!
        let container = try ModelContainer(for: SyncHistoryRecord.self,
                                           configurations: .init(isStoredInMemoryOnly: true))
        let store = SyncHistoryStore(defaults: defaults, container: container)
        let legacy = SyncEntry(date: Date(timeIntervalSince1970: 100), points: 0, success: true, error: nil)
        let current = SyncEntry(date: Date(timeIntervalSince1970: 200), points: 2, success: true, error: nil)
        let other = SyncEntry(date: Date(timeIntervalSince1970: 300), points: 3, success: true, error: nil)
        _ = store.append(legacy)
        _ = store.append(current)
        _ = store.append(other)
        defaults.set([
            current.id.uuidString: "test-account",
            other.id.uuidString: "other-account"
        ], forKey: "health-sync.history-accounts.v1")

        let provider = TestSyncConfiguration()
        let engine = SyncEngine(
            configuration: provider,
            health: EmptyTestHealthData(),
            transport: SuccessTestTransport(),
            stateStore: InMemoryTestSyncState(),
            defaults: defaults,
            historyStore: store,
            clock: { Date(timeIntervalSince1970: 1_000) }
        )
        engine.refreshConfiguration()

        #expect(engine.history.map(\.id) == [current.id])
        #expect(engine.legacyHistory.map(\.id) == [legacy.id])
        #expect(!engine.history.contains(where: { $0.id == other.id }))
        #expect(!engine.legacyHistory.contains(where: { $0.id == other.id }))
    }
}
