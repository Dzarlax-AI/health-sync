import Foundation

/// A trusted operator confirms the endpoint, server profile and eligible key
/// on this installation before delivering managed app configuration.
struct SleepCandidateAuthorization: Equatable {
    let profileID: UUID
    let enrollment: UUID
    let confirmation: UUID
    let verifiedBundleOnly: Set<String>
    let allowNewJournal: Bool
    var revisionBound = false
    var observeConfirmedDeletions = false
    var earlyObservations = false

    static func managed(for config: SyncConfiguration, defaults: UserDefaults) -> Self? {
        guard let managed = defaults.dictionary(forKey: "com.apple.configuration.managed"),
              let entries = managed["healthSleepCandidatesV1"] as? [[String: Any]] else { return nil }
        return matchingEntry(entries, for: config)
    }

#if DEBUG
    static func development(for config: SyncConfiguration, defaults: UserDefaults,
                            directory: URL = .applicationSupportDirectory) -> Self? {
        guard defaults.dictionary(forKey: "com.apple.configuration.managed")?["healthSleepCandidatesV1"] == nil,
              config.endpoint.scheme == "https" else { return nil }
        let url = directory.appending(path: "health-sync/development-sleep-candidate-pilot.json")
        guard let data = try? Data(contentsOf: url), data.count <= 16_384,
              let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return matchingEntry([entry], for: config)
    }
#endif

    private static func matchingEntry(_ entries: [[String: Any]], for config: SyncConfiguration) -> Self? {
        let matching = entries.filter { $0["credentialFingerprint"] as? String == config.fingerprint }
        guard matching.count == 1, let entry = matching.first,
              entry["enabled"] as? Bool == true,
              entry["endpoint"] as? String == config.endpoint.absoluteString,
              let profile = (entry["profileID"] as? String).flatMap(UUID.init(uuidString:)),
              let enrollment = (entry["enrollment"] as? String).flatMap(UUID.init(uuidString:)),
              let confirmation = (entry["confirmation"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return Self(profileID: profile, enrollment: enrollment, confirmation: confirmation,
                    verifiedBundleOnly: Set(entry["verifiedBundleOnly"] as? [String] ?? []),
                    allowNewJournal: entry["allowNewJournal"] as? Bool == true,
                    revisionBound: entry["revisionBound"] as? Bool == true,
                    observeConfirmedDeletions: entry["observeConfirmedDeletions"] as? Bool == true,
                    earlyObservations: entry["earlyObservations"] as? Bool == true)
    }
}

struct SleepCandidateLedger: Codable {
    struct Night: Codable {
        let input: SourcedSleepCandidate
        let sourceName: String
        let window: DateInterval

        var intervalIDs: Set<String> { Set(input.candidate.stages.map(\.id)) }
    }

    enum Hold: Codable, Equatable {
        case awaitingMode(confirmation: UUID)
        case recheckAcknowledgement
        case rejected(status: Int)
    }

    struct Pending: Codable {
        let packet: SleepCandidatePacket
        var early: Bool? = nil
        var attempts = 0
        var retryAt: Date?
        var hold: Hold?
        var reconciliationConfirmation: UUID?

        func canSend(confirmation: UUID, now: Date) -> Bool {
            switch hold {
            case .awaitingMode(let previous): return previous != confirmation
            case .recheckAcknowledgement, .rejected:
                return reconciliationConfirmation.map { $0 != confirmation } ?? false
            case nil: return retryAt.map { $0 <= now } ?? true
            }
        }
    }

    struct Review: Codable {
        var unknownZone = 0
        var incomplete = 0
        var ambiguousSource = 0
        var oversized = 0
        var retainedNights: Set<String> = []
    }

    struct Acceptance: Codable {
        let packetID: String
        let serverID: Int64
        let acceptedAt: Date
    }

    let enrollment: UUID
    var lastAcceptance: Acceptance?
    var initialReadComplete = false
    var nights: [Night] = []
    var pending: [Pending] = []
    var review = Review()
    private var withdrawnIntervalIDs: Set<String>?
    var deletionEvidence: SleepDeletionEvidence?
    private var recentWithdrawnProofs: [String: Date]?

    init(enrollment: UUID) { self.enrollment = enrollment }

    func activeDeletionIDs(now: Date, readableSources: Set<String>? = nil) -> Set<String> {
        let floor = now.addingTimeInterval(-SleepDeletionEvidence.retention)
        return Set(nights.flatMap { night -> [String] in
            guard night.window.start >= floor,
                  SleepCandidateCapture.isDeviceBound(night.input.sourceID),
                  readableSources?.contains(night.input.sourceID) ?? true,
                  (night.input.candidate.coverage != nil || night.input.candidate.observation != nil) else { return [] }
            return night.input.candidate.stages.filter { $0.end >= floor }.map(\.id)
        })
    }

    func nextPendingIndex(allowEarly: Bool, confirmation: UUID, now: Date) -> Int? {
        if let index = pending.firstIndex(where: { $0.early != true }),
           pending[index].canSend(confirmation: confirmation, now: now) { return index }
        if allowEarly, let index = pending.firstIndex(where: { $0.early == true }),
           pending[index].canSend(confirmation: confirmation, now: now) { return index }
        return nil
    }

    // A successful read that omits samples does not establish deletion.
    mutating func collect(_ capture: SleepCandidateCapture, notBefore: Date? = nil,
                          revisionBound: Bool = false, boundedWithdrawals: Bool = false,
                          observedAt: Date = Date(), earlyObservations: Bool = false) throws {
        let floor = observedAt.addingTimeInterval(-SleepDeletionEvidence.retention)
        if boundedWithdrawals {
            recentWithdrawnProofs = recentWithdrawnProofs?.filter { $0.value >= floor }
        }
        func covered(_ window: DateInterval) -> Bool {
            capture.contains(window) && (notBefore.map { window.start >= $0 } ?? true) &&
                (!boundedWithdrawals || window.start >= floor)
        }
        let previous = nights
        let episodes = capture.episodes.filter { episode in
            guard withdrawnIntervalIDs?.isDisjoint(with: episode.intervalIDs) ?? true else { return false }
            guard let recentWithdrawnProofs, !recentWithdrawnProofs.isEmpty else { return true }
            return !episode.intervalIDs.contains { recentWithdrawnProofs[Self.withdrawalProof($0)] != nil }
        }
        let observedIDs = episodes.map(\.intervalIDs)
        let previousIDs = previous.map(\.intervalIDs)
        let matches = episodes.indices.map { index in
            previous.indices.filter {
                let night = previous[$0]
                guard night.input.sourceID == episodes[index].sourceID else { return false }
                if !previousIDs[$0].isDisjoint(with: observedIDs[index]) { return true }
                return night.input.candidate.stages.contains { old in
                    old.kind.isAsleep && episodes[index].stages.contains {
                        $0.kind.isAsleep && $0.overlaps(old)
                    }
                }
            }
        }
        let matchCounts = Dictionary(grouping: matches.flatMap { $0 }, by: { $0 }).mapValues(\.count)
        var issues = Review(retainedNights: review.retainedNights)
        issues.ambiguousSource = capture.ambiguousSourceCount
        for index in previous.indices where matchCounts[index] == nil && covered(previous[index].window) {
            issues.retainedNights.insert(previous[index].input.candidate.id)
        }

        let canObserveEarly = revisionBound && earlyObservations
        let readStart = max(capture.queryStart, notBefore ?? .distantPast, observedAt.addingTimeInterval(-72 * 3600))
        let readEnd = min(capture.queryEnd, observedAt)
        var changed: [SourcedSleepCandidate] = []
        var observations: [SourcedSleepCandidate] = []
        for index in episodes.indices {
            let episode = episodes[index]
            let matched = matches[index]
            let matchedIDs = matched.map { previous[$0].input.candidate.id }
            // Multiple matches indicate a split or merge. The v1 endpoint
            // cannot atomically replace the affected candidates.
            guard matched.count <= 1, matched.allSatisfy({ matchCounts[$0] == 1 }) else {
                issues.retainedNights.formUnion(matchedIDs)
                continue
            }
            guard let zone = episode.zone, let window = episode.coverage() else {
                issues.unknownZone += 1
                continue
            }
            let old = matched.first.map { previous[$0] }
            let fullWindow = covered(window) && matched.allSatisfy({ covered(previous[$0].window) })
            if !fullWindow, canObserveEarly, SleepCandidateCapture.isDeviceBound(episode.sourceID),
               capture.ambiguousSourceCount == 0, old?.input.candidate.coverage == nil,
               readStart < readEnd, episode.stages.count <= SleepCandidatePacket.maximumStages,
               episode.stages.allSatisfy({ $0.start >= readStart && $0.end <= readEnd }) {
                let prior = old?.input.candidate
                // An incomplete read can extend an observation. Removing an
                // asleep interval requires independent deletion evidence.
                guard prior?.stages.filter({ $0.kind.isAsleep }).allSatisfy({ episode.stages.contains($0) }) ?? true,
                      prior?.observation.map({ observedAt > $0.observedAt }) ?? true else { continue }
                if prior?.stages == episode.stages && prior?.wakeZone == zone { continue }
                let proof = SleepCandidateObservation(start: readStart, end: readEnd, observedAt: observedAt)
                let input = SourcedSleepCandidate(sourceID: episode.sourceID,
                    candidate: .init(id: prior?.id ?? UUID().uuidString.lowercased(),
                                     revision: (prior?.revision ?? 0) + 1, wakeZone: zone,
                                     stages: episode.stages, observation: proof))
                let night = Night(input: input, sourceName: episode.sourceName, window: window)
                if let oldIndex = matched.first { nights[oldIndex] = night }
                else { nights.append(night) }
                observations.append(input)
                continue
            }
            guard fullWindow,
                  !previous.indices.contains(where: {
                      let old = previous[$0]
                      return old.input.sourceID == episode.sourceID && matchCounts[$0] == nil &&
                          old.window.start < window.end && window.start < old.window.end
                  }) else {
                issues.incomplete += 1
                continue
            }
            guard episode.stages.count <= SleepCandidatePacket.maximumStages else {
                issues.oversized += 1
                continue
            }
            if let oldIndex = matched.first {
                let old = previous[oldIndex]
                // HealthKit can hide samples without exposing read authorization.
                // Require positive replacement evidence for each removed interval.
                guard old.input.candidate.stages.allSatisfy({ stage in
                    if observedIDs[index].contains(stage.id) { return true }
                    if revisionBound, SleepCandidateCapture.isDeviceBound(episode.sourceID),
                       capture.ambiguousSourceCount == 0, capture.confirmedDeletedIntervalIDs.contains(stage.id) {
                        return true
                    }
                    let midpoint = stage.start.addingTimeInterval(stage.end.timeIntervalSince(stage.start) / 2)
                    return episode.stages.contains {
                        !previousIDs[oldIndex].contains($0.id) && $0.start <= midpoint && midpoint < $0.end &&
                        ($0.kind == stage.kind || ($0.kind.isAsleep && stage.kind.isAsleep))
                    }
                }) else {
                    issues.retainedNights.insert(old.input.candidate.id)
                    continue
                }
            }
            let prior = old?.input.candidate
            guard !revisionBound || SleepCandidateCapture.isDeviceBound(episode.sourceID) else {
                issues.incomplete += 1
                continue
            }
            guard revisionBound || (prior?.coverage == nil && prior?.observation == nil) else { continue }
            let id = prior?.id ?? UUID().uuidString.lowercased()
            issues.retainedNights.remove(id)
            let identical = prior?.stages == episode.stages && prior?.wakeZone == zone &&
                (!revisionBound || prior?.coverage != nil)
            if identical {
                if let oldIndex = matched.first, let old, old.sourceName != episode.sourceName {
                    nights[oldIndex] = Night(input: old.input, sourceName: episode.sourceName, window: old.window)
                }
                continue
            }
            let version = (prior?.revision ?? 0) + 1
            let proofWindow = old.map {
                DateInterval(start: min(window.start, $0.window.start), end: max(window.end, $0.window.end))
            } ?? window
            let proof = revisionBound ? coverage(episode.sourceID, version, proofWindow, observedAt) : nil
            guard !revisionBound || (proof != nil && (prior?.coverage.map { observedAt > $0.observedAt } ?? true)) else {
                issues.incomplete += 1
                continue
            }
            let input = SourcedSleepCandidate(sourceID: episode.sourceID,
                candidate: SleepCandidate(id: id, revision: version, wakeZone: zone, stages: episode.stages, coverage: proof))
            let night = Night(input: input, sourceName: episode.sourceName, window: window)
            if let oldIndex = matched.first { nights[oldIndex] = night }
            else { nights.append(night) }
            changed.append(input)
        }
        if revisionBound {
            var withdrawnCandidates: Set<String> = []
            for index in previous.indices where matchCounts[index] == nil {
                let night = previous[index]
                let candidate = night.input.candidate
                let ids = Set(candidate.stages.filter { $0.kind.isAsleep }.map(\.id))
                guard SleepCandidateCapture.isDeviceBound(night.input.sourceID),
                      !ids.isEmpty, ids.isSubset(of: capture.confirmedDeletedIntervalIDs),
                      capture.ambiguousSourceCount == 0,
                      let end = candidate.stages.filter({ $0.kind.isAsleep }).map(\.end).max(),
                      let zone = TimeZone(identifier: candidate.wakeZone) else { continue }
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = zone
                formatter.dateFormat = "yyyy-MM-dd"
                let wakeDate = formatter.string(from: end)
                let revision = candidate.revision + 1
                if let seen = candidate.observation {
                    guard canObserveEarly, observedAt > seen.observedAt, readStart < readEnd else { continue }
                    let proof = SleepCandidateObservation(start: readStart, end: readEnd, observedAt: observedAt,
                                                         deletedStageIDs: ids.sorted(), wakeDate: wakeDate)
                    observations.append(.init(sourceID: night.input.sourceID,
                        candidate: .init(id: candidate.id, revision: revision, wakeZone: candidate.wakeZone,
                                         stages: [], observation: proof)))
                } else {
                    guard covered(night.window),
                          let proof = coverage(night.input.sourceID, revision, night.window, observedAt),
                          candidate.coverage.map({ observedAt > $0.observedAt }) ?? true else { continue }
                    let withdrawal = SleepCandidateWithdrawal(wakeDate: wakeDate, previousRevision: candidate.revision)
                    changed.append(.init(sourceID: night.input.sourceID,
                        candidate: .init(id: candidate.id, revision: revision, wakeZone: candidate.wakeZone,
                                         stages: [], coverage: proof, withdrawal: withdrawal)))
                }
                issues.retainedNights.remove(candidate.id)
                withdrawnCandidates.insert(candidate.id)
                if boundedWithdrawals {
                    var proofs = recentWithdrawnProofs ?? [:]
                    for id in ids { proofs[Self.withdrawalProof(id)] = night.window.start }
                    guard proofs.count <= 4096 else { throw SleepChangeFailure.unavailable }
                    recentWithdrawnProofs = proofs
                } else {
                    withdrawnIntervalIDs = (withdrawnIntervalIDs ?? []).union(ids)
                }
            }
            nights.removeAll { withdrawnCandidates.contains($0.input.candidate.id) }
        }
        review = issues
        try enqueue(changed)
        try enqueue(observations, early: true)
    }

    private static func withdrawalProof(_ id: String) -> String {
        SleepCandidateCapture.digest(["withdrawn-sleep-v1", id])
    }

    private func coverage(_ sourceID: String, _ revision: Int, _ window: DateInterval,
                          _ observedAt: Date) -> SleepCandidateCoverage? {
        guard window.duration > 0, window.duration <= 72 * 3600, observedAt >= window.end else { return nil }
        return .init(sourceID: sourceID, revision: revision, start: window.start, end: window.end,
                     observedAt: observedAt)
    }

    private mutating func enqueue(_ candidates: [SourcedSleepCandidate], early: Bool = false) throws {
        var cursor = candidates.startIndex
        while cursor < candidates.endIndex {
            var end = min(cursor + SleepCandidatePacket.maximumCount, candidates.endIndex)
            while true {
                do {
                    let packet = try SleepCandidatePacket(candidates: Array(candidates[cursor..<end]))
                    pending.append(Pending(packet: packet, early: early ? true : nil))
                    break
                } catch where end - cursor > 1 {
                    end = cursor + (end - cursor) / 2
                }
            }
            cursor = end
        }
    }
}

final class SleepCandidateJournal {
    enum Failure: Error, Equatable { case requiresReconciliation }

    private let directory: URL
    private let enroll: @MainActor (String, UUID, Bool) throws -> Bool

    init(directory: URL? = nil, enroll: @escaping @MainActor (String, UUID, Bool) throws -> Bool = KeychainStore.confirmSleepCandidateEnrollment) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "health-sync/sleep-candidates-v1")
        self.enroll = enroll
    }

    func load(endpoint: URL, authorization: SleepCandidateAuthorization) throws -> SleepCandidateLedger {
        let name = partition(endpoint, authorization.profileID)
        let url = directory.appending(path: name + ".json")
        do {
            let ledger = try JSONDecoder().decode(SleepCandidateLedger.self, from: Data(contentsOf: url))
            guard ledger.enrollment == authorization.enrollment,
                  try enroll(name, authorization.enrollment, false) else { throw Failure.requiresReconciliation }
            return ledger
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard authorization.allowNewJournal, try enroll(name, authorization.enrollment, true) else { throw Failure.requiresReconciliation }
            let ledger = SleepCandidateLedger(enrollment: authorization.enrollment)
            try save(ledger, endpoint: endpoint, authorization: authorization)
            return ledger
        }
    }

    func save(_ ledger: SleepCandidateLedger, endpoint: URL, authorization: SleepCandidateAuthorization) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let name = partition(endpoint, authorization.profileID)
        try JSONEncoder().encode(ledger).write(to: directory.appending(path: name + ".json"),
                                                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func partition(_ endpoint: URL, _ profileID: UUID) -> String {
        SleepCandidateCapture.digest([endpoint.absoluteString, profileID.uuidString])
    }
}
