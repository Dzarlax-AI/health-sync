import Foundation

// The standalone fixture exercises the real ledger without managed
// enrollment or Keychain access on this Mac.
// The candidate transport never encodes workout or quantity payloads.
nonisolated enum HealthKitIngress { static let liveGrains: [String: String] = [:] }
struct WorkoutItem: Encodable, Sendable {}
struct WorkoutsPayload: Encodable, Sendable {
    struct Content: Encodable, Sendable { let workouts: [WorkoutItem] }
    let data: Content
}
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {}
enum KeychainStore {
    nonisolated static func confirmSleepCandidateEnrollment(_: String, _: UUID, _: Bool) throws -> Bool { false }
}

@main
struct RevisionFixture {
    static func main() async throws {
        if CommandLine.arguments[1] == "--send" {
            try await send()
            return
        }
        let formatter = ISO8601DateFormatter()
        let day = formatter.date(from: "2026-08-30T00:00:00Z")!
        let start = day.addingTimeInterval(-8 * 86400)
        let noon = day.addingTimeInterval(12 * 3600)
        let main = SleepCandidateStage(id: "fixture-main", kind: .core, start: day,
                                       end: day.addingTimeInterval(332 * 60))
        let nap = SleepCandidateStage(id: "fixture-nap", kind: .asleepUnspecified,
                                      start: day.addingTimeInterval(8 * 3600),
                                      end: day.addingTimeInterval(8 * 3600 + 136 * 60))
        let watch = SleepCandidateStage(id: "fixture-watch", kind: .core, start: day,
                                        end: day.addingTimeInterval(120 * 60))
        func sample(_ stage: SleepCandidateStage, _ source: String) -> SleepCandidateCapture.Sample {
            let id = SleepCandidateCapture.sourceID(bundle: "fixture", device: source, verifiedBundleOnly: false)!
            return .init(sourceID: id, sourceName: source, stage: stage, zone: "UTC")
        }
        let history = (1...7).map { offset in
            let time = day.addingTimeInterval(-Double(offset) * 86400)
            return sample(.init(id: "fixture-history-\(offset)", kind: .core,
                                start: time, end: time.addingTimeInterval(7 * 3600)), "fixture-ring")
        }
        let inBed = SleepCandidateStage(id: "retained-in-bed", kind: .inBed, start: main.start, end: main.end)
        let same = [sample(nap, "fixture-ring"), sample(watch, "fixture-watch"), sample(inBed, "fixture-ring")]
        let original = SleepCandidateCapture(queryStart: start, queryEnd: noon,
                                             samples: history + same + [sample(main, "fixture-ring")])
        let completeWithoutMain = SleepCandidateCapture(queryStart: start, queryEnd: noon, samples: history + same)
        let partialWithoutMain = SleepCandidateCapture(queryStart: day, queryEnd: noon, samples: same,
                                                       confirmedDeletedIntervalIDs: [main.id])
        let confirmedWithoutMain = SleepCandidateCapture(queryStart: start, queryEnd: noon, samples: history + same,
                                                         confirmedDeletedIntervalIDs: [main.id])
        let fallback = SleepCandidateCapture.sourceID(bundle: "fixture", device: nil, verifiedBundleOnly: true)!
        let fallbackCapture = SleepCandidateCapture(queryStart: start, queryEnd: noon,
            samples: [.init(sourceID: fallback, sourceName: "fixture", stage: main, zone: "UTC")])
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var ledger = SleepCandidateLedger(enrollment: UUID())
        try ledger.collect(original, revisionBound: true, observedAt: noon.addingTimeInterval(60))
        precondition(ledger.pending.count == 1 && ledger.nights.count == 10)
        try ledger.pending[0].packet.body.write(to: directory.appendingPathComponent("initial.json"))
        try ledger.collect(completeWithoutMain, revisionBound: true, observedAt: noon.addingTimeInterval(120))
        try ledger.collect(partialWithoutMain, revisionBound: true, observedAt: noon.addingTimeInterval(180))
        try ledger.collect(fallbackCapture, revisionBound: true, observedAt: noon.addingTimeInterval(190))
        precondition(ledger.pending.count == 1 && ledger.nights.count == 10)
        try ledger.collect(confirmedWithoutMain, revisionBound: true, observedAt: noon.addingTimeInterval(240))
        precondition(ledger.pending.count == 2 && ledger.nights.count == 9)
        try ledger.pending[1].packet.body.write(to: directory.appendingPathComponent("withdrawal.json"))
        ledger = try JSONDecoder().decode(SleepCandidateLedger.self, from: JSONEncoder().encode(ledger))
        try ledger.collect(original, revisionBound: true, observedAt: noon.addingTimeInterval(300))
        precondition(ledger.pending.count == 2 && ledger.nights.count == 9)
        // Use the same producer and journal to exercise the normal 15:00 sync.
        let afternoon = SleepCandidateStage(id: "fixture-afternoon", kind: .core,
            start: day.addingTimeInterval(14 * 3600), end: day.addingTimeInterval(14 * 3600 + 40 * 60))
        let samples = history + [sample(main, "fixture-ring"), sample(afternoon, "fixture-ring")]
        let earlyEnd = day.addingTimeInterval(15 * 3600)
        let lateEnd = day.addingTimeInterval(36 * 3600 + 60)
        let earlyCapture = SleepCandidateCapture(queryStart: start, queryEnd: earlyEnd, samples: samples)
        var earlyLedger = SleepCandidateLedger(enrollment: UUID())
        try earlyLedger.collect(earlyCapture, revisionBound: true, observedAt: earlyEnd, earlyObservations: true)
        precondition(earlyLedger.pending.count == 2 && earlyLedger.pending[1].early == true)
        let earlyNap = earlyLedger.nights.first { $0.intervalIDs.contains(afternoon.id) }!.input.candidate
        precondition(earlyNap.observation != nil && earlyNap.coverage == nil)
        try earlyLedger.pending[0].packet.body.write(to: directory.appendingPathComponent("early-baseline.json"))
        try earlyLedger.pending[1].packet.body.write(to: directory.appendingPathComponent("early-observation.json"))
        earlyLedger = try JSONDecoder().decode(SleepCandidateLedger.self, from: JSONEncoder().encode(earlyLedger))
        try earlyLedger.collect(earlyCapture, revisionBound: true, observedAt: earlyEnd.addingTimeInterval(30), earlyObservations: true)
        precondition(earlyLedger.pending.count == 2)
        var deletionLedger = earlyLedger
        let empty = SleepCandidateCapture(queryStart: start, queryEnd: earlyEnd,
            samples: history + [sample(main, "fixture-ring")])
        try deletionLedger.collect(empty, revisionBound: true, observedAt: earlyEnd.addingTimeInterval(90), earlyObservations: true)
        precondition(deletionLedger.pending.count == 2)
        let deleted = SleepCandidateCapture(queryStart: start, queryEnd: earlyEnd,
            samples: history + [sample(main, "fixture-ring")], confirmedDeletedIntervalIDs: [afternoon.id])
        try deletionLedger.collect(deleted, revisionBound: true, boundedWithdrawals: true,
            observedAt: earlyEnd.addingTimeInterval(120), earlyObservations: true)
        precondition(deletionLedger.pending.count == 3 && deletionLedger.pending[2].early == true)
        try deletionLedger.pending[2].packet.body.write(to: directory.appendingPathComponent("early-delete.json"))
        let lateCapture = SleepCandidateCapture(queryStart: start, queryEnd: lateEnd, samples: samples)
        try earlyLedger.collect(lateCapture, revisionBound: true, observedAt: lateEnd, earlyObservations: true)
        precondition(earlyLedger.pending.count == 3)
        let fullNap = earlyLedger.nights.first { $0.intervalIDs.contains(afternoon.id) }!.input.candidate
        precondition(fullNap.id == earlyNap.id && fullNap.revision == earlyNap.revision + 1 && fullNap.coverage != nil)
        try earlyLedger.pending[2].packet.body.write(to: directory.appendingPathComponent("early-confirmed.json"))
        earlyLedger.pending.removeFirst()
        let confirmation = UUID()
        earlyLedger.pending[0].hold = .rejected(status: 400)
        earlyLedger.pending[0].reconciliationConfirmation = confirmation
        precondition(earlyLedger.nextPendingIndex(allowEarly: true, confirmation: confirmation, now: lateEnd) == 1)
        precondition(!earlyLedger.pending[0].canSend(confirmation: confirmation, now: lateEnd))
        precondition(earlyLedger.pending[0].canSend(confirmation: UUID(), now: lateEnd))
    }
    private static func send() async throws {
        let args = CommandLine.arguments
        let environment = ProcessInfo.processInfo.environment
        let body = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        struct Envelope: Decodable {
            struct Content: Decodable {
                struct Batch: Decodable { let batch_id: String }
                let sleep_candidates_v1: Batch
            }
            let data: Content
        }
        struct PersistedPacket: Encodable { let id: String; let body: Data }
        let batch = try JSONDecoder().decode(Envelope.self, from: body).data.sleep_candidates_v1
        let persisted = try JSONEncoder().encode(PersistedPacket(id: batch.batch_id, body: body))
        let packet = try JSONDecoder().decode(SleepCandidatePacket.self, from: persisted)
        let configuration = SyncConfiguration(endpoint: URL(string: args[3])!, apiKey: environment["FIXTURE_AUTH"]!,
                                              fingerprint: "fixture", metricGroups: [.sleep], workoutsEnabled: false,
                                              backgroundEnabled: false, syncOnLaunch: false, interval: 0,
                                              workoutHRTimeline: false)
        let expectedStatus = Int(args[4])!
        let transport = URLSessionSyncTransport(session: .shared)
        do {
            _ = try await transport.uploadSleepCandidates(packet, configuration: configuration)
            precondition(expectedStatus == 200)
        } catch SyncTransportError.http(let status, _) where expectedStatus != 200 && status == expectedStatus {
            return
        }
    }

}
