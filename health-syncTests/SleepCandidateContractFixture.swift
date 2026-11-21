import Foundation
#if canImport(health_sync)
@testable import health_sync
#endif

nonisolated func syntheticSleepCandidatePacket() throws -> SleepCandidatePacket {
    let date = ISO8601DateFormatter()
    func stamp(_ string: String) -> Date { date.date(from: string)! }
    let base = stamp("2026-11-16T19:00:00Z")
    let ring = SleepCandidate(id: "synthetic-ring-night", revision: 1, wakeZone: "Asia/Singapore", stages: [
        .init(id: "20000000-0000-4000-8000-000000000001", kind: .asleepUnspecified, start: base, end: base.addingTimeInterval(6 * 3600)),
        .init(id: "20000000-0000-4000-8000-000000000002", kind: .inBed, start: base, end: base.addingTimeInterval(6.5 * 3600))
    ])
    let watch = SleepCandidate(id: "synthetic-watch-fragment", revision: 1, wakeZone: "Asia/Singapore", stages: [
        .init(id: "10000000-0000-4000-8000-000000000001", kind: .core, start: base, end: base.addingTimeInterval(20 * 60))
    ])
    let lateFragment = SleepCandidate(id: "synthetic-watch-late", revision: 1, wakeZone: "Asia/Singapore", stages: [
        .init(id: "10000000-0000-4000-8000-000000000002", kind: .core, start: base.addingTimeInterval(7 * 3600),
              end: base.addingTimeInterval(7.25 * 3600))
    ])
    let nap = SleepCandidate(id: "synthetic-watch-nap", revision: 1, wakeZone: "Asia/Singapore", stages: [
        .init(id: "10000000-0000-4000-8000-000000000003", kind: .core, start: base.addingTimeInterval(12 * 3600),
              end: base.addingTimeInterval(12.5 * 3600))
    ])
    return try SleepCandidatePacket(candidates: [
        .init(sourceID: "synthetic-ring", candidate: ring),
        .init(sourceID: "synthetic-watch", candidate: watch),
        .init(sourceID: "synthetic-watch", candidate: lateFragment),
        .init(sourceID: "synthetic-watch", candidate: nap)
    ], id: UUID(uuidString: "812eed26-00b4-4075-abff-7f91bafe8d36")!)
}

#if !canImport(health_sync)
@main
struct GenerateFixture {
    static func main() throws {
        FileHandle.standardOutput.write(try syntheticSleepCandidatePacket().body)
    }
}
#endif
