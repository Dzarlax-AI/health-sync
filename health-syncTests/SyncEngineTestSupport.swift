import Foundation
import SwiftData
@testable import health_sync

@MainActor
final class TestSyncConfiguration: SyncConfigurationProviding {
    var value = SyncConfiguration(endpoint: URL(string: "https://example.test")!, apiKey: "test-key", fingerprint: "test-account", metricGroups: [.vitals], workoutsEnabled: false, backgroundEnabled: true, syncOnLaunch: false, interval: 60, workoutHRTimeline: false)
    func snapshot() throws -> SyncConfiguration { value }
}

final class EmptyTestHealthData: HealthDataFetching, @unchecked Sendable {
    struct Fetch { let groups: Set<MetricGroup>; let since: Date; let until: Date? }
    var fetches: [Fetch] = []
    var cancelCount = 0
    var onFetch: (() async -> Void)?
    var metrics: [MetricData] = []
    var nightSleepCoverage: [NightSleepCoverage] = []
    var workouts: [WorkoutItem] = []
    var workoutFetches: [(Date, Date?)] = []
    var onWorkoutFetch: ((Int) async -> Void)?
    func requestAuthorization() async throws {}
    func fetchMetrics(groups: Set<MetricGroup>, since: Date, until: Date?) async throws -> HealthPayload {
        fetches.append(.init(groups: groups, since: since, until: until))
        if let onFetch { await onFetch() }
        return HealthPayload(metrics: metrics, nightSleepCoverage: nightSleepCoverage)
    }
    func fetchWorkouts(since: Date, until: Date?, includeHRTimeline: Bool) async throws -> [WorkoutItem] {
        workoutFetches.append((since, until))
        if let onWorkoutFetch { await onWorkoutFetch(workoutFetches.count) }
        return workouts
    }
    func cancelActiveQueries() async { cancelCount += 1 }
}

final class SuccessTestTransport: SyncTransport, @unchecked Sendable {
    var metricError: SyncTransportError?
    var workoutError: SyncTransportError?
    var validationError: SyncTransportError?
    var metricUploadCount = 0
    var metricPayloads: [HealthPayload] = []
    var onMetricUpload: (() -> Void)?
    var onMetricUploadAsync: (() async -> Void)?
    var sessions: [SyncUploadSession?] = []
    func uploadMetrics(_ payload: HealthPayload, configuration: SyncConfiguration, session: SyncUploadSession?) async throws -> TransportReceipt { metricUploadCount += 1; metricPayloads.append(payload); sessions.append(session); onMetricUpload?(); if let onMetricUploadAsync { await onMetricUploadAsync() }; if let metricError { throw metricError }; return .init(id: 1) }
    func uploadWorkouts(_ payload: WorkoutsPayload, configuration: SyncConfiguration) async throws -> WorkoutTransportReceipt { if let workoutError { throw workoutError }; return .init(id: 1, ingested: payload.data.workouts.count, failed: 0) }
    func validate(configuration: SyncConfiguration) async throws {
        if let validationError { throw validationError }
    }
}

final class InMemoryTestSyncState: SyncStateStoring {
    var value = SyncPersistedState.empty(fingerprint: "test-account")
    var failSaveNumber: Int?
    var failNextSave = false
    private var saveCount = 0
    func load(fingerprint: String) throws -> SyncPersistedState { value.fingerprint == fingerprint ? value : .empty(fingerprint: fingerprint) }
    func save(_ state: SyncPersistedState) throws {
        saveCount += 1
        if failNextSave || saveCount == failSaveNumber { throw TestStateError.write }
        value = state
    }
}

enum TestStateError: Error { case write }

@MainActor
func makeTestSyncEngine(state: InMemoryTestSyncState = .init(), health: EmptyTestHealthData = .init(), transport: SuccessTestTransport = .init(), workoutsEnabled: Bool = false, groups: Set<MetricGroup> = [.vitals], provider: TestSyncConfiguration? = nil) throws -> SyncEngine {
    let defaults = UserDefaults(suiteName: "health-sync-engine-tests-\(UUID().uuidString)")!
    let container = try ModelContainer(for: SyncHistoryRecord.self, configurations: .init(isStoredInMemoryOnly: true))
    let config = provider ?? TestSyncConfiguration()
    config.value = SyncConfiguration(endpoint: URL(string: "https://example.test")!, apiKey: "test-key", fingerprint: "test-account", metricGroups: groups, workoutsEnabled: workoutsEnabled, backgroundEnabled: true, syncOnLaunch: false, interval: 60, workoutHRTimeline: false)
    return SyncEngine(configuration: config, health: health, transport: transport, stateStore: state, defaults: defaults, historyStore: SyncHistoryStore(defaults: defaults, container: container), clock: { Date(timeIntervalSince1970: 1_000) })
}
