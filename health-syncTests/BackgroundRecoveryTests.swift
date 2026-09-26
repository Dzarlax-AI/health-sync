import Foundation
import HealthKit
import Security
import Testing
@testable import health_sync

@MainActor
struct BackgroundRecoveryTests {
    @Test func lockedCredentialsDoNotAffectSchedulingSettings() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("https://example.test", forKey: "serverURL")
        defaults.set(30, forKey: "syncIntervalMinutes")
        let provider = UserDefaultsSyncConfiguration(defaults: defaults, readAPIKey: { throw APIKeyError.locked })
        #expect(provider.backgroundSettings.enabled)
        #expect(provider.backgroundSettings.interval == 1800)
        #expect(throws: APIKeyError.locked) { try provider.snapshot() }
    }

    @Test func keychainDistinguishesMissingLockedAndFailure() throws {
        let access = FakeKeychainAccess()
        let key = APIKeyStore(access: access)
        access.status = errSecItemNotFound
        #expect(try key.read() == nil)
        access.status = errSecInteractionNotAllowed
        #expect(throws: APIKeyError.locked) { try key.read() }
        access.status = errSecDecode
        #expect(throws: APIKeyError.failure(errSecDecode)) { try key.read() }
    }

    @Test func migrationChangesOnlyAccessibilityAndRetriesFailure() throws {
        let access = FakeKeychainAccess()
        access.result = [kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked]
        let key = APIKeyStore(access: access)
        access.updateStatus = errSecInteractionNotAllowed
        #expect(throws: APIKeyError.locked) { try key.migrateAccessibility() }
        access.updateStatus = errSecSuccess
        try key.migrateAccessibility()
        #expect(access.updates.count == 2)
        #expect(access.updates.allSatisfy { $0.count == 1 && $0[kSecValueData] == nil })
        #expect(access.updates.last?[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(access.deletes == 0)
    }

    @Test func existingMigrationIsNoOpAndNewKeysUseBackgroundAccessibility() throws {
        let access = FakeKeychainAccess()
        access.result = [kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let key = APIKeyStore(access: access)
        try key.migrateAccessibility()
        #expect(access.updates.isEmpty)
        access.updateStatus = errSecItemNotFound
        try key.write("isolated-test-key")
        #expect(access.additions.first?[kSecValueData] as? Data == Data("isolated-test-key".utf8))
        #expect(access.additions.first?[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(access.deletes == 0)
    }

    @Test func unavailableKeychainServiceIsDistinctFromDeviceLock() {
        let access = FakeKeychainAccess()
        access.status = errSecNotAvailable
        #expect(throws: APIKeyError.failure(errSecNotAvailable)) { try APIKeyStore(access: access).read() }
    }

    @Test func absentKeyMigrationDoesNotCreateOrDeleteAnItem() throws {
        let access = FakeKeychainAccess()
        access.status = errSecItemNotFound
        try APIKeyStore(access: access).migrateAccessibility()
        #expect(access.updates.isEmpty)
        #expect(access.additions.isEmpty)
        #expect(access.deletes == 0)
    }

    @Test func repeatedSchedulingPreservesOverdueDailyAndEarlierRegular() {
        let now = Date(timeIntervalSince1970: 100_000)
        let old = [BackgroundRequest(identifier: BackgroundSyncManager.taskIdentifier, earliest: now.addingTimeInterval(30)),
                   BackgroundRequest(identifier: BackgroundSyncManager.dailyResyncIdentifier, earliest: now.addingTimeInterval(-3600))]
        let requests = BackgroundSchedulePolicy.requests(now: now, interval: 900, pending: old, replaceRegular: false)
        #expect(requests.isEmpty)
        let changed = BackgroundSchedulePolicy.requests(now: now, interval: 1800, pending: old, replaceRegular: true)
        #expect(changed.count == 1)
        #expect(changed.first?.earliest == now.addingTimeInterval(1800))
    }

    @Test func immediateRequestsAndOverdueWorkSurviveTimeZoneChanges() {
        let pending = [BackgroundRequest(identifier: BackgroundSyncManager.taskIdentifier, earliest: nil),
                       BackgroundRequest(identifier: BackgroundSyncManager.dailyResyncIdentifier, earliest: .distantPast)]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        #expect(BackgroundSchedulePolicy.requests(now: Date(), interval: 900, pending: pending,
                                                 replaceRegular: false, calendar: calendar).isEmpty)
    }

    @Test func submitFailureCanRecoverAndConsumedRequestIsReplenished() async {
        let scheduler = FakeBackgroundScheduler(), observers = FakeBackgroundObservers()
        let diagnostics = BackgroundSyncDiagnostics(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let coordinator = BackgroundWorkCoordinator(scheduler: scheduler, observers: observers, diagnostics: diagnostics)
        scheduler.failSubmission = true
        coordinator.apply(.init(enabled: true, interval: 900))
        await coordinator.waitUntilSettled()
        #expect(scheduler.requests.isEmpty)
        #expect(diagnostics.events.contains { $0.kind == .schedulerFailed })
        scheduler.failSubmission = false
        coordinator.apply(.init(enabled: true, interval: 900))
        await coordinator.waitUntilSettled()
        #expect(scheduler.requests.count == 2)
        scheduler.requests.removeAll { $0.identifier == BackgroundSyncManager.dailyResyncIdentifier }
        coordinator.apply(.init(enabled: true, interval: 900))
        await coordinator.waitUntilSettled()
        #expect(scheduler.requests.count == 2)
        #expect(scheduler.submitted.count == 3)
    }

    @Test func completionAndExpirationAreIdempotent() {
        var values: [Bool] = []
        let completion = BackgroundCompletion { values.append($0) }
        completion.finish(false)
        completion.finish(true)
        #expect(values == [false])
    }

    @Test func partialReceiptStillRetriesLockedChannelOnUnlock() {
        let locked = SyncFailure(code: .locked, message: "fixture")
        #expect(SyncOutcome.partial(accepted: 10, failed: locked).needsUnlockRetry)
        #expect(SyncOutcome.deferred(locked).needsUnlockRetry)
        #expect(SyncOutcome.locked.needsUnlockRetry)
        #expect(!SyncOutcome.acceptedNoData.needsUnlockRetry)
        #expect(!SyncOutcome.cancelled.needsUnlockRetry)
    }

    @Test func latePendingCallbackCannotResurrectDisabledWork() async {
        let scheduler = FakeBackgroundScheduler()
        scheduler.holdPending = true
        let observers = FakeBackgroundObservers()
        let coordinator = makeCoordinator(scheduler, observers)
        coordinator.apply(.init(enabled: true, interval: 900))
        await scheduler.waitForPending()
        coordinator.apply(.init(enabled: false, interval: 900))
        scheduler.resumePending()
        await coordinator.waitUntilSettled()
        #expect(scheduler.submitted.isEmpty)
        #expect(observers.observing == false)
        #expect(observers.delivery == false)
    }

    @Test func delayedDisableCompletesBeforeReenable() async {
        let scheduler = FakeBackgroundScheduler(), observers = FakeBackgroundObservers()
        let coordinator = makeCoordinator(scheduler, observers)
        coordinator.apply(.init(enabled: true, interval: 900))
        await coordinator.waitUntilSettled()
        observers.holdDisable = true
        coordinator.apply(.init(enabled: false, interval: 900))
        await observers.waitForDisable()
        coordinator.apply(.init(enabled: true, interval: 900))
        observers.resumeDisable()
        await coordinator.waitUntilSettled()
        #expect(observers.observing)
        #expect(observers.delivery)
        #expect(observers.operations == ["enable", "disable", "enable"])
        #expect(scheduler.requests.count == 2)
    }

    @Test func failedDeliveryRetriesOnlyOnRecoveryAndDoesNotDuplicateQueries() async {
        let scheduler = FakeBackgroundScheduler(), observers = FakeBackgroundObservers()
        observers.enableSucceeds = false
        let coordinator = makeCoordinator(scheduler, observers)
        coordinator.apply(.init(enabled: true, interval: 900))
        await coordinator.waitUntilSettled()
        coordinator.apply(.init(enabled: true, interval: 900))
        await coordinator.waitUntilSettled()
        #expect(observers.operations == ["enable"])
        observers.enableSucceeds = true
        coordinator.apply(.init(enabled: true, interval: 900), retryDelivery: true)
        await coordinator.waitUntilSettled()
        #expect(observers.operations == ["enable", "enable"])
        #expect(observers.starts == 1)
        #expect(scheduler.submitted.count == 2)
    }

    @Test func expiryCompletesWithoutWaitingForUncooperativeOperation() async {
        var continuation: CheckedContinuation<SyncOutcome, Never>?
        var started: CheckedContinuation<Void, Never>?
        var completions: [SyncOutcome] = []
        var cancellations = 0
        let run = BackgroundSyncRun(operation: {
            await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
        }, cancel: { cancellations += 1 }, completion: { completions.append($0) })
        await withCheckedContinuation { started = $0; run.start() }
        run.expire()
        run.expire()
        #expect(completions == [.cancelled])
        #expect(cancellations == 1)
        continuation?.resume(returning: .acceptedNoData)
        for _ in 0..<5 { await Task.yield() }
        #expect(completions == [.cancelled])
    }

    @Test func lockedKeyDefersWithoutFetchingOrLosingDurableProgress() async throws {
        let provider = TestSyncConfiguration(), state = InMemoryTestSyncState()
        state.value.metrics.pendingSince = Date(timeIntervalSince1970: 25)
        let original = state.value
        let health = EmptyTestHealthData(), transport = SuccessTestTransport()
        let engine = try makeTestSyncEngine(state: state, health: health, transport: transport, provider: provider)
        provider.readError = .locked
        #expect(await engine.syncNow(reason: .observer) == .locked)
        engine.refreshConfiguration()
        #expect(state.value == original)
        #expect(health.fetches.isEmpty)
        #expect(transport.metricUploadCount == 0)
        provider.readError = nil
        #expect(await engine.syncNow(reason: .observer) == .acceptedNoData)
    }

    @Test func lockingBetweenFetchAndUploadNeverUsesCachedCredentials() async throws {
        let provider = TestSyncConfiguration(), state = InMemoryTestSyncState()
        let health = EmptyTestHealthData(), transport = SuccessTestTransport()
        health.metrics = [.init(name: "heart_rate", units: "bpm", data: [.avg(date: "fixture", value: 60, source: "fixture")])]
        health.onFetch = { provider.readError = .locked }
        let engine = try makeTestSyncEngine(state: state, health: health, transport: transport, provider: provider)
        _ = await engine.syncNow(reason: .observer)
        #expect(transport.metricUploadCount == 0)
        #expect(state.value.metrics.scannedThrough == nil)
        #expect(state.value.metrics.pendingSince != nil)
    }

    @Test func lockedHealthKitRetainsPendingRange() async throws {
        let state = InMemoryTestSyncState(), health = EmptyTestHealthData()
        health.fetchError = HKError(.errorDatabaseInaccessible)
        let engine = try makeTestSyncEngine(state: state, health: health)
        _ = await engine.syncNow(reason: .observer)
        #expect(state.value.metrics.failure?.code == .locked)
        #expect(state.value.metrics.scannedThrough == nil)
        #expect(state.value.metrics.pendingSince != nil)
    }

    @Test func dailyDateUsesLocalCalendarAcrossDSTAndNewTaskAfterConsumption() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Belgrade"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-24T23:30:00Z"))
        let requests = BackgroundSchedulePolicy.requests(now: now, interval: 900, pending: [], replaceRegular: false, calendar: calendar)
        let date = try #require(requests.last?.earliest)
        #expect(date > now)
        #expect(calendar.component(.hour, from: date) == 3)
        #expect(calendar.component(.day, from: date) == 25)
    }

    @Test func diagnosticsAreBoundedAndNoDataIsNotAReceipt() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let diagnostics = BackgroundSyncDiagnostics(defaults: defaults)
        for _ in 0..<50 { diagnostics.recordOutcome(.acceptedNoData) }
        #expect(diagnostics.events.count == 40)
        #expect(diagnostics.lastAccepted == nil)
        diagnostics.recordOutcome(.accepted(points: 1, workouts: 0))
        let restored = BackgroundSyncDiagnostics(defaults: defaults)
        #expect(restored.lastAccepted != nil)
        #expect(restored.events.count == 40)
        let encoded = try JSONEncoder().encode(restored.events)
        let objects = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        #expect(objects.allSatisfy { Set($0.keys) == ["id", "date", "kind"] })
    }

    private func makeCoordinator(_ scheduler: FakeBackgroundScheduler, _ observers: FakeBackgroundObservers) -> BackgroundWorkCoordinator {
        BackgroundWorkCoordinator(scheduler: scheduler, observers: observers,
                                  diagnostics: .init(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                  clock: { Date(timeIntervalSince1970: 100_000) })
    }
}

@MainActor
private final class FakeBackgroundScheduler: BackgroundTaskScheduling {
    var requests: [BackgroundRequest] = []
    var submitted: [BackgroundRequest] = []
    var holdPending = false
    var failSubmission = false
    private var continuation: CheckedContinuation<[BackgroundRequest], Never>?
    private var started: CheckedContinuation<Void, Never>?
    func pending() async -> [BackgroundRequest] {
        guard holdPending else { return requests }
        return await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
    }
    func waitForPending() async { if continuation == nil { await withCheckedContinuation { started = $0 } } }
    func resumePending() { holdPending = false; continuation?.resume(returning: requests); continuation = nil }
    func submit(_ request: BackgroundRequest) throws {
        if failSubmission { throw TestStateError.write }
        submitted.append(request); requests.removeAll { $0.identifier == request.identifier }; requests.append(request)
    }
    func cancelAll() { requests.removeAll() }
}

@MainActor
private final class FakeBackgroundObservers: HealthBackgroundObserving {
    var observing = false
    var delivery = false
    var starts = 0
    var operations: [String] = []
    var holdDisable = false
    var enableSucceeds = true
    private var continuation: CheckedContinuation<Bool, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func startObservers() { if !observing { starts += 1 }; observing = true }
    func stopObservers() { observing = false }
    func enableDelivery() async -> Bool { operations.append("enable"); delivery = enableSucceeds; return enableSucceeds }
    func disableDelivery() async -> Bool {
        operations.append("disable")
        if holdDisable { _ = await withCheckedContinuation { continuation = $0; started?.resume(); started = nil } }
        delivery = false
        return true
    }
    func waitForDisable() async { if continuation == nil { await withCheckedContinuation { started = $0 } } }
    func resumeDisable() { continuation?.resume(returning: true); continuation = nil }
}

@MainActor
final class FakeKeychainAccess: KeychainAccess {
    var status: OSStatus = errSecSuccess
    var result: Any?
    var updateStatus: OSStatus = errSecSuccess
    var updates: [[CFString: Any]] = []
    var additions: [[CFString: Any]] = []
    var deletes = 0
    func copy(_ query: [CFString: Any]) -> (OSStatus, Any?) { (status, result) }
    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        updates.append(attributes); return updateStatus
    }
    func add(_ attributes: [CFString: Any]) -> OSStatus { additions.append(attributes); return status }
    func delete(_ query: [CFString: Any]) -> OSStatus { deletes += 1; return status }
}
