import Foundation

/// The independently selectable data families. The default configuration sends
/// every family; disabling a family never discards its persisted catch-up
/// boundary.
enum MetricGroup: String, CaseIterable, Codable, Sendable, Hashable {
    case vitals
    case activity
    case sleep
    case other
}

enum SyncStatus: String, Codable, Sendable, Equatable {
    case notConfigured
    case noData
    case sending
    case accepted
    case partial
    case retryPending
    case error
    case disabled
}

enum SyncPrimaryAction: Sendable, Equatable {
    case configure
    case sync
    case retry
}

struct SyncFailure: Codable, Sendable, Equatable {
    enum Code: String, Codable, Sendable {
        case configuration
        case authorization
        case transport
        case rejectedAck
        case partialAck
        case statePersistence
        case healthData
        case locked
        case cancelled
    }

    let code: Code
    /// This is deliberately suitable for UI/history only. It must never
    /// contain a request body, API key, or endpoint query string.
    let message: String
}

struct SyncChannelSnapshot: Codable, Sendable, Equatable {
    let status: SyncStatus
    let lastAcceptedAt: Date?
    let pendingSince: Date?
    let retryAt: Date?
    let acceptedCount: Int
    let failure: SyncFailure?

    static let idle = SyncChannelSnapshot(
        status: .noData, lastAcceptedAt: nil, pendingSince: nil,
        retryAt: nil, acceptedCount: 0, failure: nil
    )
}

struct SyncUIState: Sendable, Equatable {
    let status: SyncStatus
    let metrics: SyncChannelSnapshot
    let workouts: SyncChannelSnapshot
    let primaryAction: SyncPrimaryAction
    let canSync: Bool
}

enum SyncReason: Sendable, Equatable {
    case manual
    case foregroundTimer
    case appActivation
    case backgroundTask
    case observer
    case dailyResync

    var mayRequestAuthorization: Bool {
        self == .manual || self == .appActivation
    }

    var bypassesRetryDelay: Bool { self == .manual }
}

enum SyncOutcome: Sendable, Equatable {
    case accepted(points: Int, workouts: Int)
    case acceptedNoData
    case partial(accepted: Int, failed: SyncFailure)
    case deferred(SyncFailure)
    case disabled
    case locked
    case cancelled
    case alreadyRunning

    var wasAccepted: Bool {
        switch self {
        case .accepted, .acceptedNoData: return true
        default: return false
        }
    }
}

enum ConnectionTestResult: Sendable, Equatable {
    case accepted
    case failed(SyncFailure)
}

struct SyncConfiguration: Sendable, Equatable {
    let endpoint: URL
    let apiKey: String
    let fingerprint: String
    let metricGroups: Set<MetricGroup>
    let workoutsEnabled: Bool
    let backgroundEnabled: Bool
    let syncOnLaunch: Bool
    let interval: TimeInterval
    let workoutHRTimeline: Bool
}

@MainActor
protocol SyncConfigurationProviding: AnyObject {
    func snapshot() throws -> SyncConfiguration
}

protocol HealthDataFetching: Sendable {
    func requestAuthorization() async throws
    /// Returns the exact ingestion payload so source-owned annotations, such
    /// as night-sleep coverage, travel with the samples that justify them.
    func fetchMetrics(groups: Set<MetricGroup>, since: Date, until: Date?) async throws -> HealthPayload
    func fetchWorkouts(since: Date, until: Date?, includeHRTimeline: Bool) async throws -> [WorkoutItem]
    func cancelActiveQueries() async
}

protocol SyncTransport: Sendable {
    func uploadMetrics(_ payload: HealthPayload, configuration: SyncConfiguration,
                       session: SyncUploadSession?) async throws -> TransportReceipt
    func uploadWorkouts(_ payload: WorkoutsPayload, configuration: SyncConfiguration) async throws -> WorkoutTransportReceipt
    func validate(configuration: SyncConfiguration) async throws
}

struct SyncUploadSession: Sendable, Equatable {
    let id: String
    let total: Int
}

struct TransportReceipt: Sendable, Equatable {
    let id: Int64
}

struct WorkoutTransportReceipt: Sendable, Equatable {
    let id: Int64
    let ingested: Int
    let failed: Int
}

enum SyncTransportError: Error, Sendable, Equatable {
    case configuration
    case unauthorized
    case redirected
    case http(status: Int, retryAfter: Date?)
    case invalidAcknowledgement
    case partialAcknowledgement
    case cancelled
    case network
}
