import CryptoKit
import Foundation

nonisolated struct SleepCandidateCapture: Sendable {
    struct Sample: Sendable {
        let sourceID: String
        let sourceName: String
        let stage: SleepCandidateStage
        let zone: String?
    }

    struct Episode: Sendable {
        let sourceID: String
        let sourceName: String
        let stages: [SleepCandidateStage]
        let zone: String?

        var intervalIDs: Set<String> { Set(stages.map(\.id)) }

        var lastAsleep: Date {
            stages.filter { $0.kind.isAsleep }.map(\.end).max()!
        }

        func coverage() -> DateInterval? {
            guard let zone, let timeZone = TimeZone(identifier: zone) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            // Include every local noon-to-noon window touched by the episode,
            // as well as the window for the date assigned by the wire contract.
            let first = min(stages.map(\.start).min()!, lastAsleep)
            let last = max(stages.map(\.end).max()!, lastAsleep)
            func noon(on date: Date) -> Date? {
                calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)
            }
            guard let firstNoon = noon(on: first), let lastNoon = noon(on: last),
                  let wakeNoon = noon(on: lastAsleep),
                  let wakeStart = calendar.date(byAdding: .day, value: -1, to: wakeNoon),
                  let previousNoon = calendar.date(byAdding: .day, value: -1, to: firstNoon),
                  let nextNoon = calendar.date(byAdding: .day, value: 1, to: lastNoon) else { return nil }
            let start = min(wakeStart, first < firstNoon ? previousNoon : firstNoon)
            let end = max(wakeNoon, last >= lastNoon ? nextNoon : lastNoon)
            return DateInterval(start: start, end: end)
        }
    }

    let queryStart: Date
    let queryEnd: Date
    let episodes: [Episode]
    let ambiguousSourceCount: Int
    let observedSourceIDs: Set<String>
    var confirmedDeletedIntervalIDs: Set<String>

    init(queryStart: Date, queryEnd: Date, samples: [Sample], ambiguousSourceCount: Int = 0,
         confirmedDeletedIntervalIDs: Set<String> = []) {
        self.queryStart = queryStart
        self.queryEnd = queryEnd
        self.ambiguousSourceCount = ambiguousSourceCount
        observedSourceIDs = Set(samples.map(\.sourceID))
        self.confirmedDeletedIntervalIDs = confirmedDeletedIntervalIDs
        episodes = Dictionary(grouping: samples, by: \.sourceID).sorted { $0.key < $1.key }.flatMap { _, source in
            let sorted = source.sorted { ($0.stage.start, $0.stage.id) < ($1.stage.start, $1.stage.id) }
            var result: [Episode] = []
            var session: [Sample] = []
            var latestEnd = Date.distantPast
            func finishSession() {
                guard let lastAsleep = session.filter({ $0.stage.kind.isAsleep }).max(by: {
                    ($0.stage.end, $0.stage.id) < ($1.stage.end, $1.stage.id)
                }) else { return }
                let zones = Set(session.compactMap(\.zone))
                let zone = zones.count == 1 ? Self.historicalZone(lastAsleep.zone ?? zones.first) : nil
                result.append(.init(sourceID: lastAsleep.sourceID, sourceName: lastAsleep.sourceName,
                                    stages: session.map(\.stage).sorted { $0.id < $1.id }, zone: zone))
            }
            for sample in sorted {
                if sample.stage.start.timeIntervalSince(latestEnd) > 30 * 60 {
                    finishSession()
                    session.removeAll(keepingCapacity: true)
                    latestEnd = .distantPast
                }
                session.append(sample)
                latestEnd = max(latestEnd, sample.stage.end)
            }
            finishSession()
            return result
        }
    }

    func contains(_ window: DateInterval) -> Bool {
        queryStart <= window.start && queryEnd >= window.end
    }

    static func historicalZone(_ name: String?) -> String? {
        guard let name, name == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(name) else { return nil }
        return name
    }

    static func isDeviceBound(_ sourceID: String) -> Bool {
        sourceID.hasPrefix("hk-device-v1-")
    }

    static func sourceID(bundle: String, device: String?, verifiedBundleOnly: Bool) -> String? {
        guard !bundle.isEmpty else { return nil }
        if let device, !device.isEmpty { return "hk-device-v1-" + digest([bundle, device]) }
        guard verifiedBundleOnly else { return nil }
        return "hk-source-v1-" + digest([bundle])
    }

    static func digest(_ values: [String]) -> String {
        var bytes = Data()
        for value in values {
            let utf8 = Data(value.utf8)
            var length = UInt64(utf8.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(utf8)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
