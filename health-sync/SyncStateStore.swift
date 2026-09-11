import Foundation

struct ChannelSyncState: Codable, Equatable {
    var lastAttemptStatus: SyncStatus?
    var acceptedAt: Date?
    var scannedThrough: Date?
    var pendingSince: Date?
    var retryAttempt: Int
    var retryAt: Date?
    var acceptedCount: Int
    var failure: SyncFailure?

    static let empty = ChannelSyncState(lastAttemptStatus: nil, acceptedAt: nil, scannedThrough: nil,
                                        pendingSince: nil, retryAttempt: 0,
                                        retryAt: nil, acceptedCount: 0, failure: nil)
}

struct SyncPersistedState: Codable, Equatable {
    static let schemaVersion = 1
    var version: Int = SyncPersistedState.schemaVersion
    var fingerprint: String
    var metrics: ChannelSyncState
    var workouts: ChannelSyncState
    var requestedGeneration: Int
    var completedGeneration: Int
    var followUpMetricsSince: Date?
    var followUpWorkoutsSince: Date?
    var fullResyncStart: Date?
    var fullResyncEnd: Date?
    var fullResyncRevision: Int? = nil
    var enabledMetricGroups: Set<MetricGroup>?
    var workoutsEnabled: Bool?
    var workoutHRTimeline: Bool?
    /// Start bounds held for data groups that were disabled while they still
    /// had pending/full-resync work. Keeping them outside the aggregate metric
    /// checkpoint prevents another enabled group from erasing this intent.
    var deferredMetricGroupSince: [String: Date]? = nil

    static func empty(fingerprint: String) -> SyncPersistedState {
        SyncPersistedState(fingerprint: fingerprint, metrics: .empty, workouts: .empty,
                           requestedGeneration: 0, completedGeneration: 0,
                           followUpMetricsSince: nil, followUpWorkoutsSince: nil,
                           fullResyncStart: nil, fullResyncEnd: nil)
    }
}

protocol SyncStateStoring: AnyObject {
    func load(fingerprint: String) throws -> SyncPersistedState
    func save(_ state: SyncPersistedState) throws
}

/// A single account-scoped metadata file. Replacing it on fingerprint change
/// intentionally prevents pending work for an old server/account from being
/// resumed if a user changes credentials and later changes them back.
final class SyncStateStore: SyncStateStoring {
    private let lock = NSLock()
    private let fileURL: URL

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask).first!
            .appendingPathComponent("health-sync", isDirectory: true)
        self.fileURL = root.appendingPathComponent("sync-state-v1.json")
    }

    func load(fingerprint: String) throws -> SyncPersistedState {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty(fingerprint: fingerprint)
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(SyncPersistedState.self, from: data)
        guard decoded.version == SyncPersistedState.schemaVersion,
              decoded.fingerprint == fingerprint else {
            return .empty(fingerprint: fingerprint)
        }
        return decoded
    }

    func save(_ state: SyncPersistedState) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}
