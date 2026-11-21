import Foundation

nonisolated struct SleepCandidateStage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case core, deep, rem, asleepUnspecified = "asleep_unspecified", awake, inBed = "in_bed"

        var isAsleep: Bool { self != .awake && self != .inBed }
    }

    let id: String
    let kind: Kind
    let start: Date
    let end: Date

    func overlaps(_ other: Self) -> Bool {
        start < other.end && end > other.start
    }

    enum CodingKeys: String, CodingKey {
        case id, kind
        case start = "start_at"
        case end = "end_at"
    }
}

nonisolated struct SleepCandidateCoverage: Codable, Equatable, Sendable {
    let sourceID: String
    let revision: Int
    let start: Date
    let end: Date
    let observedAt: Date

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case revision
        case start = "start_at"
        case end = "end_at"
        case observedAt = "observed_at"
    }
}

nonisolated struct SleepCandidateWithdrawal: Codable, Equatable, Sendable {
    let wakeDate: String
    let previousRevision: Int

    enum CodingKeys: String, CodingKey {
        case wakeDate = "wake_date"
        case previousRevision = "previous_revision"
    }
}

nonisolated struct SleepCandidateObservation: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
    let observedAt: Date
    var deletedStageIDs: [String]? = nil
    var wakeDate: String? = nil

    enum CodingKeys: String, CodingKey {
        case start = "start_at"
        case end = "end_at"
        case observedAt = "observed_at"
        case deletedStageIDs = "deleted_stage_ids"
        case wakeDate = "wake_date"
    }
}

nonisolated struct SleepCandidate: Codable, Equatable, Sendable {
    let id: String
    let revision: Int
    let wakeZone: String
    let stages: [SleepCandidateStage]
    var coverage: SleepCandidateCoverage? = nil
    var withdrawal: SleepCandidateWithdrawal? = nil
    var observation: SleepCandidateObservation? = nil

    enum CodingKeys: String, CodingKey {
        case id, revision, stages, coverage, withdrawal, observation
        case wakeZone = "wake_zone"
    }
}

nonisolated struct SourcedSleepCandidate: Codable, Equatable, Sendable {
    let sourceID: String
    let candidate: SleepCandidate

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case candidate
    }
}

nonisolated struct SleepCandidatePacket: Codable, Equatable, Sendable {
    static let maximumCount = 32
    static let maximumStages = 4096
    static let maximumBytes = 16 * 1024 * 1024

    let id: String
    let body: Data

    init(candidates: [SourcedSleepCandidate], id: UUID = UUID()) throws {
        struct Payload: Encodable {
            let data: Content
        }
        struct Content: Encodable {
            let metrics: [String] = []
            let sleep_candidates_v1: Batch
        }
        struct Batch: Encodable {
            let batch_id: String
            let candidates: [SourcedSleepCandidate]
        }

        guard (1...Self.maximumCount).contains(candidates.count),
              candidates.allSatisfy({ entry in
                  let candidate = entry.candidate
                  if candidate.withdrawal != nil {
                      return candidate.stages.isEmpty && candidate.coverage != nil
                  }
                  if let deleted = candidate.observation?.deletedStageIDs {
                      return candidate.stages.isEmpty && (1...Self.maximumStages).contains(deleted.count)
                  }
                  return (1...Self.maximumStages).contains(candidate.stages.count)
              }) else {
            throw EncodingError.invalidValue(candidates.count, .init(codingPath: [], debugDescription: "Sleep candidate packet limits exceeded"))
        }
        let id = id.uuidString.lowercased()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp.format(date))
        }
        let body = try encoder.encode(Payload(data: Content(sleep_candidates_v1: Batch(batch_id: id, candidates: candidates))))
        guard body.count <= Self.maximumBytes else {
            throw EncodingError.invalidValue(body.count, .init(codingPath: [], debugDescription: "Sleep candidate body exceeds 16 MiB"))
        }
        self.id = id
        self.body = body
    }
}
