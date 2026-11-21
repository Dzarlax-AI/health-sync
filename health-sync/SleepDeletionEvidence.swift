import Foundation

nonisolated struct SleepChangePage: Sendable {
    struct Addition: Sendable {
        let id: String
        let start: Date
        let end: Date
        let deviceBound: Bool
    }

    let anchor: Data
    let additions: [Addition]
    let deletedIDs: [String]

    var isEmpty: Bool { additions.isEmpty && deletedIDs.isEmpty }
}

enum SleepChangeFailure: Error { case invalidAnchor, unavailable }

/// Part of the candidate ledger, saved in the same atomic write as the packet queue.
struct SleepDeletionEvidence: Codable {
    private static let queryVersion = "sleep-anchored-v1"
    static let retention: TimeInterval = 14 * 24 * 3600
    private static let maximumProofs = 2048

    let scope: String
    let start: Date
    var anchor: Data?
    private var ready = false
    private var observed: [String: Date] = [:]

    init(fingerprint: String, now: Date) {
        scope = Self.scope(for: fingerprint)
        start = now.addingTimeInterval(-Self.retention)
    }

    func belongs(to fingerprint: String) -> Bool {
        scope == Self.scope(for: fingerprint)
    }

    private static func scope(for fingerprint: String) -> String {
        SleepCandidateCapture.digest([queryVersion, fingerprint])
    }

    mutating func prune(known: Set<String>, now: Date) {
        observed = observed.filter { known.contains($0.key) && now.timeIntervalSince($0.value) < Self.retention }
    }

    mutating func apply(_ page: SleepChangePage, known: Set<String>, now: Date) throws {
        prune(known: known, now: now)
        // The nil-anchor replay can include older tombstones. Only changes
        // after a complete baseline may prove removal of an observed sample.
        if ready {
            for id in page.deletedIDs where known.contains(id) {
                if observed[id] == nil { observed[id] = now }
            }
        }
        guard observed.count <= Self.maximumProofs else { throw SleepChangeFailure.unavailable }
        if page.isEmpty { ready = true }
        anchor = page.anchor
    }

    func confirmed(before sampleReadStartedAt: Date, known: Set<String>) -> Set<String> {
        Set(observed.compactMap { id, stamp in
            stamp < sampleReadStartedAt && known.contains(id) ? id : nil
        })
    }
}
