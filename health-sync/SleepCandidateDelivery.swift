import Foundation
import OSLog

@MainActor
final class SleepCandidateDelivery {
    private let journal: SleepCandidateJournal
    private let transport: any SleepCandidateUploading
    private let authorization: (SyncConfiguration) -> SleepCandidateAuthorization?
    typealias ReadChanges = (Date, Data?) async throws -> SleepChangePage

    private let readChanges: ReadChanges?
    private var journalBusy = false
    private let log = Logger(subsystem: "health-sync", category: "sleep-candidates")

    init(journal: SleepCandidateJournal, transport: any SleepCandidateUploading,
         readChanges: ReadChanges? = nil, authorization: @escaping (SyncConfiguration) -> SleepCandidateAuthorization?) {
        self.journal = journal
        self.transport = transport
        self.readChanges = readChanges
        self.authorization = authorization
    }

    func authorized(for config: SyncConfiguration) -> SleepCandidateAuthorization? {
        guard config.metricGroups.contains(.sleep) else { return nil }
        return authorization(config)
    }

    func capture(_ capture: SleepCandidateCapture?, configuration: SyncConfiguration,
                 authorization: SleepCandidateAuthorization?, initial: Bool = false, notBefore: Date? = nil) {
        guard !journalBusy, let capture, let authorization,
              authorized(for: configuration) == authorization else { return }
        do {
            var ledger = try journal.load(endpoint: configuration.endpoint, authorization: authorization)
            try storeCapture(capture, ledger: &ledger, configuration: configuration,
                             authorization: authorization, initial: initial, notBefore: notBefore)
        } catch {
            log.error("Sleep candidate journal requires access or reconciliation")
        }
    }

    func captureWithDeletionEvidence(_ capture: SleepCandidateCapture?, configuration: SyncConfiguration,
                                     authorization: SleepCandidateAuthorization, sampleReadStartedAt: Date,
                                     initial: Bool = false, notBefore: Date? = nil,
                                     clock: () -> Date = Date.init, isCurrent: () -> Bool) async {
        guard let capture else { return }
        guard authorization.revisionBound, authorization.observeConfirmedDeletions, let readChanges else {
            self.capture(capture, configuration: configuration, authorization: authorization,
                         initial: initial, notBefore: notBefore)
            return
        }
        guard !journalBusy, authorized(for: configuration) == authorization, isCurrent() else { return }
        journalBusy = true
        defer { journalBusy = false }

        do {
            var ledger = try journal.load(endpoint: configuration.endpoint, authorization: authorization)
            var captured = capture
            let scope = configuration.fingerprint
            let fresh = SleepDeletionEvidence(fingerprint: scope, now: sampleReadStartedAt)
            var evidence = ledger.deletionEvidence.flatMap { $0.belongs(to: scope) ? $0 : nil } ?? fresh
            do {
                let known = ledger.activeDeletionIDs(now: sampleReadStartedAt)
                var caughtUp = false
                // An incomplete drain preserves cursor progress without acting on
                // a partial view of changes. The next sync continues the drain.
                for _ in 0..<4 {
                    let page = try await readChanges(evidence.start, evidence.anchor)
                    try Task.checkCancellation()
                    guard isCurrent(), authorized(for: configuration) == authorization else { return }
                    try evidence.apply(page, known: known, now: clock())
                    if page.isEmpty {
                        caughtUp = true
                        break
                    }
                }
                if caughtUp, capture.ambiguousSourceCount == 0 {
                    let readable = ledger.activeDeletionIDs(now: sampleReadStartedAt,
                                                            readableSources: capture.observedSourceIDs)
                    captured.confirmedDeletedIntervalIDs.formUnion(
                        evidence.confirmed(before: sampleReadStartedAt, known: readable)
                    )
                }
                ledger.deletionEvidence = evidence
            } catch SleepChangeFailure.invalidAnchor {
                ledger.deletionEvidence = fresh
            } catch is CancellationError {
                return
            } catch {
                // Keep the existing cursor. Missing or failed reads add no evidence.
                log.notice("Sleep deletion observation unavailable")
            }
            guard !Task.isCancelled, isCurrent(), authorized(for: configuration) == authorization else { return }
            try storeCapture(captured, ledger: &ledger, configuration: configuration,
                             authorization: authorization, initial: initial, notBefore: notBefore,
                             observedAt: clock())
        } catch {
            log.error("Sleep candidate journal requires access or reconciliation")
        }
    }

    private func storeCapture(_ capture: SleepCandidateCapture, ledger: inout SleepCandidateLedger,
                              configuration: SyncConfiguration, authorization: SleepCandidateAuthorization,
                              initial: Bool, notBefore: Date?, observedAt: Date = Date()) throws {
        try ledger.collect(capture, notBefore: notBefore, revisionBound: authorization.revisionBound,
                           boundedWithdrawals: authorization.revisionBound && authorization.observeConfirmedDeletions,
                           observedAt: observedAt, earlyObservations: authorization.earlyObservations)
        let activeIDs = ledger.activeDeletionIDs(now: observedAt)
        ledger.deletionEvidence?.prune(known: activeIDs, now: observedAt)
        // A read that yields no accepted episode can be an authorization gap.
        if initial {
            let nights = ledger.nights
            ledger.initialReadComplete = capture.episodes.contains { episode in
                guard let window = episode.coverage(), capture.contains(window),
                      notBefore.map({ window.start >= $0 }) ?? true else { return false }
                return nights.contains {
                    $0.input.sourceID == episode.sourceID &&
                        $0.input.candidate.wakeZone == episode.zone &&
                        $0.input.candidate.stages == episode.stages
                }
            }
        }
        try journal.save(ledger, endpoint: configuration.endpoint, authorization: authorization)
        let review = ledger.review
        if review.unknownZone + review.incomplete + review.ambiguousSource + review.oversized + review.retainedNights.count > 0 {
            log.notice("Sleep candidate review: unknown zone \(review.unknownZone), incomplete window \(review.incomplete), ambiguous streams \(review.ambiguousSource), oversized \(review.oversized), retained nights \(review.retainedNights.count)")
        }
    }

    func needsInitialRead(_ configuration: SyncConfiguration, authorization: SleepCandidateAuthorization) -> Bool {
        do {
            return try !journal.load(endpoint: configuration.endpoint, authorization: authorization).initialReadComplete
        } catch {
            log.error("Sleep candidate journal requires access or reconciliation")
            return false
        }
    }

    func deliver(configuration: SyncConfiguration, clock: () -> Date,
                 isCurrent: () -> Bool) async {
        guard !journalBusy, let authorization = authorized(for: configuration) else { return }
        journalBusy = true
        defer { journalBusy = false }
        // Each lane keeps FIFO. An early failure cannot hold full coverage or
        // withdrawals behind it.
        for _ in 0..<4 {
            guard isCurrent(), !Task.isCancelled, authorized(for: configuration) == authorization else { return }
            do {
                var ledger = try journal.load(endpoint: configuration.endpoint, authorization: authorization)
                guard let index = ledger.nextPendingIndex(allowEarly: authorization.earlyObservations,
                                                          confirmation: authorization.confirmation, now: clock()) else { return }
                var next = ledger.pending[index]
                // A fresh operator confirmation allows rechecking the same
                // immutable bytes. Persist that decision before the request.
                next.hold = nil
                next.reconciliationConfirmation = nil
                next.attempts = min(next.attempts + 1, 10)
                next.retryAt = clock().addingTimeInterval(min(6 * 3600, pow(2, Double(next.attempts - 1)) * 60))
                ledger.pending[index] = next
                try journal.save(ledger, endpoint: configuration.endpoint, authorization: authorization)
                do {
                    let receipt = try await transport.uploadSleepCandidates(next.packet, configuration: configuration)
                    ledger.pending.remove(at: index)
                    ledger.lastAcceptance = .init(packetID: next.packet.id, serverID: receipt.id, acceptedAt: clock())
                } catch SleepCandidateAcknowledgementError.missing {
                    ledger.pending[index].hold = .awaitingMode(confirmation: authorization.confirmation)
                    log.notice("Sleep candidate delivery is waiting for confirmation of prepare mode")
                } catch SleepCandidateAcknowledgementError.mismatched {
                    ledger.pending[index].hold = .recheckAcknowledgement
                    ledger.pending[index].reconciliationConfirmation = authorization.confirmation
                    log.error("Sleep candidate delivery requires acknowledgement reconciliation")
                } catch let SyncTransportError.http(status, retryAfter) {
                    if status == 408 || status == 429 || (500...599).contains(status) {
                        if let retryAfter, let retryAt = next.retryAt {
                            ledger.pending[index].retryAt = max(retryAt, retryAfter)
                        }
                    } else {
                        ledger.pending[index].hold = .rejected(status: status)
                    ledger.pending[index].reconciliationConfirmation = authorization.confirmation
                        log.error("Sleep candidate request requires reconciliation after HTTP \(status)")
                    }
                } catch SyncTransportError.unauthorized {
                    ledger.pending[index].hold = .awaitingMode(confirmation: authorization.confirmation)
                } catch SyncTransportError.network, SyncTransportError.cancelled, is CancellationError {
                    // The already-persisted packet and retry date survive cancellation.
                } catch {
                    ledger.pending[index].hold = .recheckAcknowledgement
                    ledger.pending[index].reconciliationConfirmation = authorization.confirmation
                    log.error("Sleep candidate delivery requires receipt reconciliation")
                }
                try journal.save(ledger, endpoint: configuration.endpoint, authorization: authorization)
                if ledger.pending.indices.contains(index), ledger.pending[index].packet.id == next.packet.id { return }
            } catch {
                log.error("Sleep candidate journal requires access or reconciliation")
                return
            }
        }
    }
}
