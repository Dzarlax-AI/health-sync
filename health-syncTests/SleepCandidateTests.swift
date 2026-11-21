import Foundation
import Testing
@testable import health_sync

@MainActor
struct SleepCandidateTests {
    private let now = Date(timeIntervalSince1970: 1_795_208_400)

    @Test func legacyEncodingOmitsCaptureAndLeavesCoverageIdentical() throws {
        let capture = capture([sample("core", .core, hours: 6)])
        let coverage = SleepPeriodCoverage(wakeDate: "2026-11-17", sourceEpoch: "legacy",
            captureCompleteness: "complete", syncGeneration: "fixture",
            coveredIntervalStart: "start", coveredIntervalEnd: "end")
        let days = [coverage]
        let baseline = HealthPayload(metrics: [], sleepPeriodCoverage: days)
        let withCapture = HealthPayload(metrics: [], sleepPeriodCoverage: days, sleepCandidateCapture: capture)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(baseline) == encoder.encode(withCapture))
        #expect(baseline.hasUploadableContent == withCapture.hasUploadableContent)
        #expect(!HealthPayload(metrics: [], sleepCandidateCapture: capture).hasUploadableContent)
    }

    @Test func distinctStreamsAndSeparatedEpisodesKeepTheirOwnIntervals() throws {
        let bundle = "example.synthetic.source"
        let first = try #require(SleepCandidateCapture.sourceID(bundle: bundle, device: "one", verifiedBundleOnly: false))
        let second = try #require(SleepCandidateCapture.sourceID(bundle: bundle, device: "two", verifiedBundleOnly: false))
        #expect(first != second)
        #expect(SleepCandidateCapture.sourceID(bundle: bundle, device: nil, verifiedBundleOnly: false) == nil)
        let rows = [
            sample("watch-short", .core, hours: 0.4, source: first),
            sample("ring", .asleepUnspecified, hours: 6, source: second),
            sample("late-fragment", .core, offset: 9, hours: 0.2, source: first),
            sample("third", .rem, hours: 6, source: "third"),
            sample("fourth", .deep, hours: 6, source: "fourth")
        ]
        var ledger = SleepCandidateLedger(enrollment: UUID())
        try ledger.collect(capture(rows))
        #expect(ledger.nights.count == 5)
        #expect(ledger.nights.filter { $0.input.sourceID == first }.count == 2)
        #expect(ledger.nights.first { $0.input.sourceID == second }?.input.candidate.stages.map(\.kind) == [.asleepUnspecified])
        let before = ledger.nights.map(\.input)
        let renamed = rows.reversed().map {
            SleepCandidateCapture.Sample(sourceID: $0.sourceID, sourceName: "Renamed", stage: $0.stage, zone: $0.zone)
        }
        try ledger.collect(capture(renamed))
        #expect(ledger.nights.map(\.input) == before)
        #expect(ledger.nights.allSatisfy { $0.sourceName == "Renamed" })
        #expect(ledger.pending.count == 1)
    }

    @Test func partialOrEmptyReadRetainsFullNightAndOnlyAFullCorrectionAdvancesRevision() throws {
        var ledger = SleepCandidateLedger(enrollment: UUID())
        let original = [sample("core", .core, hours: 4), sample("rem", .rem, offset: 4, hours: 2)]
        let amended = original + [sample("deep", .deep, offset: 6, hours: 1)]
        try ledger.collect(capture(original))
        let first = try #require(ledger.nights.first)
        try ledger.collect(.init(queryStart: now.addingTimeInterval(3 * 3600), queryEnd: now.addingTimeInterval(24 * 3600),
                                 samples: Array(amended.dropFirst())))
        try ledger.collect(capture([]))
        #expect(ledger.review.retainedNights == [first.input.candidate.id])
        try ledger.collect(capture([original[1]]))
        #expect(ledger.nights.map(\.input) == [first.input])
        #expect(ledger.pending.count == 1)
        try ledger.collect(capture(amended.reversed()))
        try ledger.collect(capture(amended))
        let corrected = try #require(ledger.nights.first)
        #expect(corrected.input.candidate.revision == 2)
        #expect(corrected.input.candidate.id == first.input.candidate.id)
        #expect(corrected.input.candidate.stages.count == 3)
        #expect(ledger.pending.count == 2)
        #expect(ledger.review.retainedNights.isEmpty)
    }

    @Test func historicalZoneControlsCoverageAndAmbiguousZoneIsDeferred() throws {
        let singapore = "Asia/Singapore"
        let stamp = ISO8601DateFormatter()
        let start = try #require(stamp.date(from: "2026-11-16T16:10:00Z"))
        let end = start.addingTimeInterval(3 * 3600)
        let later = sample("late-in-bed", .inBed, offset: 0, hours: 1, zone: nil, origin: end)
        let rows = [sample("core", .core, hours: 3, zone: singapore, origin: start), later]
        let c = SleepCandidateCapture(queryStart: start.addingTimeInterval(-86_400),
                                      queryEnd: end.addingTimeInterval(86_400), samples: rows)
        let episode = try #require(c.episodes.first)
        #expect(episode.lastAsleep == end)
        #expect(episode.coverage()?.start == stamp.date(from: "2026-11-16T04:00:00Z"))
        #expect(episode.coverage()?.end == stamp.date(from: "2026-11-17T04:00:00Z"))
        var ledger = SleepCandidateLedger(enrollment: UUID())
        try ledger.collect(c)
        #expect(ledger.nights.first?.input.candidate.wakeZone == singapore)
        let conflict = rows + [sample("awake", .awake, hours: 1, zone: "Europe/Belgrade", origin: end)]
        try ledger.collect(.init(queryStart: c.queryStart, queryEnd: c.queryEnd, samples: conflict))
        #expect(ledger.review.unknownZone == 1)
        #expect(ledger.nights.first?.input.candidate.revision == 1)
        try ledger.collect(capture([sample("unknown", .core, hours: 6, zone: nil)]))
        #expect(ledger.review.unknownZone == 1)
        #expect(ledger.nights.count == 1)
    }

    @Test func dateCorrectionRequiresBothHistoricalWindowsEvenWithStableHealthKitID() throws {
        let stamp = ISO8601DateFormatter()
        let start = try #require(stamp.date(from: "2026-11-16T16:10:00Z"))
        let old = sample("stable", .core, hours: 3, zone: "Europe/Belgrade", origin: start)
        let changed = sample("stable", .core, hours: 3, zone: "Asia/Singapore", origin: start)
        let firstRead = capture([old])
        let oldWindow = try #require(firstRead.episodes.first?.coverage())
        let newWindow = try #require(capture([changed]).episodes.first?.coverage())
        #expect(oldWindow.end > newWindow.end)
        var ledger = SleepCandidateLedger(enrollment: UUID())
        try ledger.collect(firstRead)
        let original = try #require(ledger.nights.first?.input.candidate)
        try ledger.collect(.init(queryStart: newWindow.start, queryEnd: newWindow.end, samples: [changed]))
        #expect(ledger.nights.first?.input.candidate == original)
        try ledger.collect(capture([changed]))
        #expect(ledger.nights.first?.input.candidate.id == original.id)
        #expect(ledger.nights.first?.input.candidate.wakeZone == "Asia/Singapore")
        #expect(ledger.nights.first?.input.candidate.revision == 2)
    }

    @Test func dstWindowUsesCalendarDays() throws {
        let stamp = ISO8601DateFormatter()
        let start = try #require(stamp.date(from: "2026-10-24T21:00:00Z"))
        let c = capture([sample("dst", .asleepUnspecified, hours: 8, zone: "Europe/Belgrade", origin: start)])
        let window = try #require(c.episodes.first?.coverage())
        #expect(window.duration == 25 * 3600)
    }

    @Test func restartModeHoldAndCredentialRotationKeepOriginalPartitionAndBytes() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let markers = EnrollmentMarkers()
        let a = config(key: "a")
        let b = config(key: "b")
        let aRotated = config(key: "a-rotated")
        let tokenA = authorization()
        let tokenB = authorization()
        var permissions = [a.fingerprint: tokenA, b.fingerprint: tokenB]
        let transport = CandidateTransport()
        var clock = now
        func journal() -> SleepCandidateJournal {
            SleepCandidateJournal(directory: dir, enroll: markers.check)
        }
        func delivery() -> SleepCandidateDelivery {
            SleepCandidateDelivery(journal: journal(), transport: transport) { permissions[$0.fingerprint] }
        }
        func send(_ configuration: SyncConfiguration, through sender: SleepCandidateDelivery) async {
            await sender.deliver(configuration: configuration, clock: { clock }, isCurrent: { true })
        }
        let first = delivery()
        first.capture(capture([sample("core", .core, hours: 6)]), configuration: a, authorization: tokenA)
        let original = try #require(journal().load(endpoint: a.endpoint, authorization: tokenA).pending.first?.packet)
        transport.error = SyncTransportError.network
        await send(a, through: first)
        #expect(transport.requests.map(\.packet) == [original])
        let restarted = delivery()
        await send(a, through: restarted)
        await send(b, through: restarted)
        clock.addTimeInterval(65)
        await send(aRotated, through: restarted)
        #expect(transport.requests.count == 1)
        transport.error = SleepCandidateAcknowledgementError.missing
        await send(a, through: restarted)
        clock.addTimeInterval(1000)
        await send(a, through: restarted)
        #expect(transport.requests.count == 2)
        let confirmed = authorization(profile: tokenA.profileID, enrollment: tokenA.enrollment, allowNewJournal: false)
        permissions[aRotated.fingerprint] = confirmed
        transport.error = nil
        await send(aRotated, through: restarted)
        #expect(transport.requests.map(\.key) == ["a", "a", "a-rotated"])
        #expect(transport.requests.map(\.packet) == [original, original, original])
        let accepted = try journal().load(endpoint: a.endpoint, authorization: tokenA)
        #expect(accepted.pending.isEmpty)
        #expect(accepted.lastAcceptance?.packetID == original.id)
        #expect(accepted.lastAcceptance?.serverID == 1)
        #expect(try journal().load(endpoint: b.endpoint, authorization: tokenB).nights.isEmpty)
    }

    @Test func rejectedBatchesAndJournalLossRequireReconciliation() async throws {
        for problem in [SyncTransportError.http(status: 400, retryAfter: nil), .http(status: 409, retryAfter: nil)] {
            let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let store = SleepCandidateJournal(directory: dir, enroll: EnrollmentMarkers().check)
            let uploader = CandidateTransport()
            let configuration = config(key: "a")
            var token = authorization()
            let delivery = SleepCandidateDelivery(journal: store, transport: uploader) { _ in token }
            delivery.capture(capture([sample("core", .core, hours: 6)]), configuration: configuration, authorization: token)
            uploader.error = problem
            await delivery.deliver(configuration: configuration, clock: { now }, isCurrent: { true })
            await delivery.deliver(configuration: configuration, clock: { now.addingTimeInterval(86_400) }, isCurrent: { true })
            #expect(uploader.requests.count == 1)
            token = authorization(profile: token.profileID, enrollment: token.enrollment)
            uploader.error = nil
            await delivery.deliver(configuration: configuration, clock: { now.addingTimeInterval(86_400) }, isCurrent: { true })
            #expect(uploader.requests.count == 2)
            #expect(uploader.requests.first?.packet == uploader.requests.last?.packet)
            try FileManager.default.removeItem(at: dir)
            #expect(throws: SleepCandidateJournal.Failure.requiresReconciliation) {
                try store.load(endpoint: configuration.endpoint, authorization: token)
            }
        }
    }

    @Test func missingWriterStateCannotBeRecreatedByAnExistingAuthorization() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let journal = SleepCandidateJournal(directory: dir, enroll: EnrollmentMarkers().check)
        let configuration = config(key: "a")
        let resumed = authorization(allowNewJournal: false)
        #expect(throws: SleepCandidateJournal.Failure.requiresReconciliation) {
            try journal.load(endpoint: configuration.endpoint, authorization: resumed)
        }
    }

    @Test func normalEngineSyncContinuesWithFeatureOffAndWithMissingCandidateACK() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SleepCandidateJournal(directory: dir, enroll: EnrollmentMarkers().check)
        let uploader = CandidateTransport()
        let token = authorization()
        var authorized = false
        let delivery = SleepCandidateDelivery(journal: store, transport: uploader) { _ in authorized ? token : nil }
        let legacy = SuccessTestTransport()
        let health = EmptyTestHealthData()
        health.candidateCapture = capture([sample("core", .core, hours: 6)])
        health.metrics = [.init(name: "active_energy", units: "kcal",
                            data: [.qty(date: "2026-11-20 20:00:00 +0000", value: 420, source: "Synthetic")])]
        let legacyState = InMemoryTestSyncState()
        legacyState.value.initialSleepHistoryState = .completed
        let engine = try makeTestSyncEngine(state: legacyState, health: health, transport: legacy,
                                            groups: [.sleep, .activity], candidateDelivery: delivery)
        #expect(await engine.syncNow() == .accepted(points: 1, workouts: 0))
        #expect(health.candidateFetchCount == 0)
        #expect(uploader.requests.isEmpty)

        authorized = true
        uploader.error = SleepCandidateAcknowledgementError.missing
        health.metrics = [.init(name: "active_energy", units: "kcal",
                            data: [.qty(date: "2026-11-20 20:00:00 +0000", value: 500, source: "Synthetic")])]
        #expect(await engine.syncNow() == .accepted(points: 1, workouts: 0))
        #expect(health.candidateFetchCount == 2)
        #expect(uploader.requests.count == 1)
        #expect(legacy.metricUploadCount == 2)
        #expect(legacyState.value.initialSleepHistoryState == .completed)
        #expect(legacyState.value.metrics.acceptedAt != nil)
        #expect(await engine.syncNow() == .accepted(points: 1, workouts: 0))
        #expect(legacy.metricUploadCount == 3)
        #expect(health.candidateFetchCount == 3)
        #expect(uploader.requests.count == 1)
    }

    @Test func disabledBackgroundSyncLeavesPendingSleepCandidatesAlone() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SleepCandidateJournal(directory: dir, enroll: EnrollmentMarkers().check)
        let uploader = CandidateTransport()
        let authorization = authorization()
        let delivery = SleepCandidateDelivery(journal: store, transport: uploader) { _ in authorization }
        let health = EmptyTestHealthData()
        let configuration = config(key: "a")
        delivery.capture(capture([sample("core", .core, hours: 6)]), configuration: configuration, authorization: authorization)
        let engine = try makeTestSyncEngine(health: health, groups: [.sleep], backgroundEnabled: false, candidateDelivery: delivery)
        for reason: SyncReason in [.backgroundTask, .observer, .dailyResync] {
            #expect(await engine.syncNow(reason: reason) == .disabled)
        }
        #expect(health.candidateFetchCount == 0)
        #expect(uploader.requests.isEmpty)
        #expect(try store.load(endpoint: configuration.endpoint, authorization: authorization).pending.count == 1)
    }

    @Test func backgroundExpiryDuringCandidateUploadPreservesLegacyCheckpoint() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SleepCandidateJournal(directory: dir, enroll: EnrollmentMarkers().check)
        let uploader = CandidateTransport()
        let token = authorization()
        let delivery = SleepCandidateDelivery(journal: store, transport: uploader) { _ in token }
        let health = EmptyTestHealthData()
        health.candidateCapture = capture([sample("core", .core, hours: 6)])
        health.metrics = [.init(name: "active_energy", units: "kcal",
                            data: [.qty(date: "2026-11-20 20:00:00 +0000", value: 500, source: "Synthetic")])]
        let state = InMemoryTestSyncState()
        let provider = TestSyncConfiguration()
        let engine = try makeTestSyncEngine(state: state, health: health, groups: [.sleep, .activity],
                                            provider: provider, candidateDelivery: delivery)
        let owner = UUID()
        uploader.onUpload = { engine.cancelCurrentSync(owner: owner) }
        uploader.error = SyncTransportError.cancelled

        #expect(await engine.syncNow(reason: .backgroundTask, owner: owner) == .accepted(points: 1, workouts: 0))
        #expect(state.value.metrics.failure == nil)
        #expect(state.value.metrics.scannedThrough != nil)
        #expect(state.value.completedGeneration == state.value.requestedGeneration)
        #expect(try store.load(endpoint: provider.value.endpoint, authorization: token).pending.count == 1)
    }

    @Test func fullWindowCanReplaceSamplesButASplitRequiresReconciliation() throws {
        var ledger = SleepCandidateLedger(enrollment: UUID())
        try ledger.collect(capture([sample("whole", .core, hours: 6)]))
        let first = try #require(ledger.nights.first?.input.candidate)
        let split = [sample("early", .core, hours: 2), sample("late", .rem, offset: 4, hours: 2)]
        try ledger.collect(capture(split))
        #expect(ledger.nights.count == 1)
        #expect(ledger.nights.first?.input.candidate == first)
        #expect(ledger.review.retainedNights == [first.id])
        try ledger.collect(capture([sample("overlapping-tail", .core, offset: 5.5, hours: 0.5)]))
        #expect(ledger.nights.first?.input.candidate == first)
        try ledger.collect(capture([sample("replacement", .asleepUnspecified, hours: 6)]))
        #expect(ledger.nights.first?.input.candidate.id == first.id)
        #expect(ledger.nights.first?.input.candidate.revision == 2)
        #expect(ledger.pending.count == 2)
    }

    @Test func anchoredBaselineCannotProveDeletionAndScopeSurvivesRestart() throws {
        var evidence = SleepDeletionEvidence(fingerprint: "first", now: now)
        let known: Set<String> = ["observed"]
        func page(_ number: UInt8, _ deleted: [String] = []) -> SleepChangePage {
            .init(anchor: Data([number]), additions: [], deletedIDs: deleted)
        }
        try evidence.apply(page(1, ["observed"]), known: known, now: now)
        try evidence.apply(page(2), known: known, now: now)
        #expect(evidence.confirmed(before: now.addingTimeInterval(1), known: known).isEmpty)
        try evidence.apply(page(3, ["unknown", "observed"]), known: known, now: now)
        #expect(evidence.confirmed(before: now, known: known).isEmpty)
        let bytes = try JSONEncoder().encode(evidence)
        var decoded = try JSONDecoder().decode(SleepDeletionEvidence.self, from: bytes)
        #expect(decoded.belongs(to: "first"))
        #expect(!decoded.belongs(to: "second"))
        #expect(decoded.anchor == Data([3]))
        #expect(decoded.confirmed(before: now.addingTimeInterval(1), known: known) == ["observed"])
        decoded.prune(known: known, now: now.addingTimeInterval(SleepDeletionEvidence.retention))
        #expect(decoded.confirmed(before: .distantFuture, known: known).isEmpty)
    }

    @Test func anchoredDeletionQueuesOneWithdrawalAfterRestartAndAReadableFullWindow() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let markers = EnrollmentMarkers()
        let config = config(key: "anchor-first")
        var configured = authorization()
        configured.revisionBound = true
        configured.observeConfirmedDeletions = true
        let token = configured
        let source = try #require(SleepCandidateCapture.sourceID(bundle: "example.synthetic.source", device: "test-device", verifiedBundleOnly: false))
        let asleep = sample("observed-asleep", .core, hours: 6, source: source)
        let inBed = sample("observed-in-bed", .inBed, hours: 6, source: source)
        let original = capture([asleep, inBed])
        let fullAfterDeletion = capture([inBed])
        let transport = CandidateTransport()
        let ledgerStore = SleepCandidateJournal(directory: dir, enroll: markers.check)
        var clock = now.addingTimeInterval(36 * 3600)
        var pages: [SleepChangePage] = []
        var failure: SleepChangeFailure?
        var requestedAnchors: [Data?] = []
        func page(_ number: UInt8, _ deleted: [String] = []) -> SleepChangePage {
            .init(anchor: Data([number]), additions: [], deletedIDs: deleted)
        }
        func makeDelivery() -> SleepCandidateDelivery {
            SleepCandidateDelivery(journal: SleepCandidateJournal(directory: dir, enroll: markers.check),
                                   transport: transport, readChanges: { _, anchor in
                requestedAnchors.append(anchor)
                if let failure { throw failure }
                return pages.removeFirst()
            }) { _ in token }
        }
        func run(_ input: SleepCandidateCapture, _ next: [SleepChangePage] = [],
                 error: SleepChangeFailure? = nil) async throws -> SleepCandidateLedger {
            pages = next
            failure = error
            clock = clock.addingTimeInterval(60)
            let readStart = clock
            let delivery = makeDelivery() // Reopen the persistent journal for each cycle.
            await delivery.captureWithDeletionEvidence(input, configuration: config, authorization: token,
                sampleReadStartedAt: readStart, clock: { clock }) { true }
            return try ledgerStore.load(endpoint: config.endpoint, authorization: token)
        }
        var ledger = try await run(original, [page(1)])
        let night = try #require(ledger.nights.first)
        #expect(ledger.pending.count == 1)
        ledger = try await run(fullAfterDeletion, [page(2, ["observed-asleep", "never-seen"]), page(3)])
        #expect(ledger.nights.count == 1)
        #expect(ledger.pending.count == 1)
        let partial = SleepCandidateCapture(queryStart: night.window.start.addingTimeInterval(60),
                                            queryEnd: night.window.end, samples: [inBed])
        ledger = try await run(partial, [page(4)])
        #expect(ledger.nights.count == 1)
        ledger = try await run(capture([SleepCandidateCapture.Sample]()), [page(5)])
        #expect(ledger.nights.count == 1)
        ledger = try await run(fullAfterDeletion, error: .unavailable)
        #expect(ledger.deletionEvidence?.anchor == Data([5]))
        #expect(ledger.pending.count == 1)
        ledger = try await run(fullAfterDeletion, [page(6)])
        #expect(ledger.nights.isEmpty)
        #expect(ledger.pending.count == 2)
        #expect(ledger.deletionEvidence?.anchor == Data([6]))
        #expect(requestedAnchors.last == Data([5]))
        ledger = try await run(original, [page(7)])
        #expect(ledger.pending.count == 2)
        #expect(ledger.nights.isEmpty)
    }

    @Test func anchoredReadStartsAfterOrdinaryMetricsCheckpoint() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SleepCandidateJournal(directory: dir, enroll: EnrollmentMarkers().check)
        var configured = authorization()
        configured.revisionBound = true
        configured.observeConfirmedDeletions = true
        let token = configured
        let health = EmptyTestHealthData()
        health.candidateCapture = capture([sample("stage", .core, hours: 6)])
        health.metrics = [.init(name: "active_energy", units: "kcal",
            data: [.qty(date: "2026-11-20 20:00:00 +0000", value: 500, source: "Synthetic")])]
        let state = InMemoryTestSyncState()
        var sawSavedMetrics = false
        let delivery = SleepCandidateDelivery(journal: store, transport: CandidateTransport(), readChanges: { _, _ in
            sawSavedMetrics = state.value.metrics.scannedThrough != nil &&
                state.value.completedGeneration == state.value.requestedGeneration
            throw SleepChangeFailure.unavailable
        }) { _ in token }
        let engine = try makeTestSyncEngine(state: state, health: health, groups: [.sleep, .activity],
                                            candidateDelivery: delivery)
        #expect(await engine.syncNow(reason: .backgroundTask) == .accepted(points: 1, workouts: 0))
        #expect(sawSavedMetrics)
    }

    @Test func invalidAnchorRestartsScopeWithoutReplayingDeletionProof() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledgerStore = SleepCandidateJournal(directory: dir, enroll: EnrollmentMarkers().check)
        let configuration = config(key: "last-checkpoint")
        var configured = authorization()
        configured.revisionBound = true
        configured.observeConfirmedDeletions = true
        let token = configured
        let clock = now.addingTimeInterval(36 * 3600)
        let source = try #require(SleepCandidateCapture.sourceID(bundle: "example.synthetic.source", device: "test", verifiedBundleOnly: false))
        let bed = sample("bed", .inBed, hours: 6, source: source)
        var ledger = try ledgerStore.load(endpoint: configuration.endpoint, authorization: token)
        try ledger.collect(capture([sample("sleep-to-retain", .deep, hours: 6, source: source), bed]),
                           revisionBound: true, observedAt: clock)
        var evidence = SleepDeletionEvidence(fingerprint: configuration.fingerprint, now: clock)
        let known = ledger.activeDeletionIDs(now: clock)
        try evidence.apply(.init(anchor: Data([1]), additions: [], deletedIDs: []), known: known, now: clock)
        try evidence.apply(.init(anchor: Data([2]), additions: [], deletedIDs: ["sleep-to-retain"]), known: known, now: clock)
        ledger.deletionEvidence = evidence
        try ledgerStore.save(ledger, endpoint: configuration.endpoint, authorization: token)
        let delivery = SleepCandidateDelivery(journal: ledgerStore, transport: CandidateTransport(), readChanges: { _, _ in
            throw SleepChangeFailure.invalidAnchor
        }) { _ in token }
        let after = clock.addingTimeInterval(60)
        await delivery.captureWithDeletionEvidence(capture([bed]), configuration: configuration,
            authorization: token, sampleReadStartedAt: after, clock: { after }) { true }
        let loaded = try ledgerStore.load(endpoint: configuration.endpoint, authorization: token)
        #expect(loaded.deletionEvidence?.anchor == nil)
        #expect(loaded.deletionEvidence?.confirmed(before: .distantFuture, known: known).isEmpty == true)
        #expect(loaded.pending.count == 1)
        #expect(loaded.nights.count == 1)
    }

    private func sample(_ id: String, _ kind: SleepCandidateStage.Kind, offset: Double = 0, hours: Double,
                        zone: String? = "UTC", source: String = "first", origin: Date? = nil) -> SleepCandidateCapture.Sample {
        let start = (origin ?? now).addingTimeInterval(offset * 3600)
        return .init(sourceID: source, sourceName: "Synthetic", stage: .init(id: id, kind: kind,
                     start: start, end: start.addingTimeInterval(hours * 3600)), zone: zone)
    }

    private func capture<S: Sequence>(_ samples: S) -> SleepCandidateCapture where S.Element == SleepCandidateCapture.Sample {
        .init(queryStart: now.addingTimeInterval(-40 * 86_400), queryEnd: now.addingTimeInterval(40 * 86_400),
              samples: Array(samples))
    }

    private func config(key: String) -> SyncConfiguration {
        .init(endpoint: URL(string: "https://example.test")!, apiKey: key, fingerprint: key, metricGroups: [.sleep],
              workoutsEnabled: false, backgroundEnabled: true, syncOnLaunch: false, interval: 60, workoutHRTimeline: false)
    }

    private func authorization(profile: UUID = UUID(), enrollment: UUID = UUID(),
                               allowNewJournal: Bool = true) -> SleepCandidateAuthorization {
        .init(profileID: profile, enrollment: enrollment, confirmation: UUID(),
              verifiedBundleOnly: [], allowNewJournal: allowNewJournal)
    }
}

@MainActor
private final class EnrollmentMarkers {
    var markers: [String: UUID] = [:]

    func check(_ partition: String, _ enrollment: UUID, _ create: Bool) -> Bool {
        if create {
            guard markers[partition] == nil else { return false }
            markers[partition] = enrollment
            return true
        }
        return markers[partition] == enrollment
    }
}

@MainActor
private final class CandidateTransport: SleepCandidateUploading {
    var requests: [(key: String, packet: SleepCandidatePacket)] = []
    var error: Error?
    var onUpload: (() -> Void)?

    func uploadSleepCandidates(_ packet: SleepCandidatePacket, configuration: SyncConfiguration) async throws -> TransportReceipt {
        requests.append((configuration.apiKey, packet))
        onUpload?()
        if let error { throw error }
        return .init(id: 1)
    }
}
