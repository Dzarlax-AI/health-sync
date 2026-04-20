import HealthKit
import Foundation

// MARK: - Metric definition

struct MetricDef: Sendable {
    let identifier: HKQuantityTypeIdentifier
    let name: String
    let unit: HKUnit
    let serverUnits: String
    let isSUM: Bool
    let useAvgField: Bool
}

// MARK: - Sleep phase accumulator

private struct SleepPhases: Sendable {
    var deep:  Double = 0
    var rem:   Double = 0
    var core:  Double = 0
    var awake: Double = 0
    var total: Double = 0

    mutating func apply(value: Int, hours: Double) {
        if #available(iOS 16.0, *) {
            switch HKCategoryValueSleepAnalysis(rawValue: value) {
            case .asleepDeep:  deep  += hours; total += hours
            case .asleepREM:   rem   += hours; total += hours
            case .asleepCore:  core  += hours; total += hours
            case .awake:       awake += hours
            default:           break
            }
        } else {
            if value != HKCategoryValueSleepAnalysis.inBed.rawValue {
                core += hours; total += hours
            }
        }
    }
}

// MARK: - HealthKitManager

actor HealthKitManager {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()

    // MARK: - Metric catalogue

    static let avgMetrics: [MetricDef] = [
        .init(identifier: .heartRate,
              name: "heart_rate", unit: .count().unitDivided(by: .minute()),
              serverUnits: "bpm", isSUM: false, useAvgField: true),
        .init(identifier: .heartRateVariabilitySDNN,
              name: "heart_rate_variability", unit: .secondUnit(with: .milli),
              serverUnits: "ms", isSUM: false, useAvgField: false),
        .init(identifier: .oxygenSaturation,
              name: "blood_oxygen_saturation", unit: .percent(),
              serverUnits: "%", isSUM: false, useAvgField: false),
        .init(identifier: .respiratoryRate,
              name: "respiratory_rate", unit: .count().unitDivided(by: .minute()),
              serverUnits: "count/min", isSUM: false, useAvgField: false),
        .init(identifier: .restingHeartRate,
              name: "resting_heart_rate", unit: .count().unitDivided(by: .minute()),
              serverUnits: "bpm", isSUM: false, useAvgField: false),
        .init(identifier: .vo2Max,
              name: "vo2_max", unit: HKUnit(from: "ml/kg·min"),
              serverUnits: "mL/kg/min", isSUM: false, useAvgField: false),
        .init(identifier: .bodyMass,
              name: "body_mass", unit: .gramUnit(with: .kilo),
              serverUnits: "kg", isSUM: false, useAvgField: false),
        .init(identifier: .bodyFatPercentage,
              name: "body_fat_percentage", unit: .percent(),
              serverUnits: "%", isSUM: false, useAvgField: false),
    ]

    static let sumMetrics: [MetricDef] = [
        .init(identifier: .stepCount,
              name: "step_count", unit: .count(),
              serverUnits: "count", isSUM: true, useAvgField: false),
        .init(identifier: .activeEnergyBurned,
              name: "active_energy", unit: .kilocalorie(),
              serverUnits: "kcal", isSUM: true, useAvgField: false),
        .init(identifier: .basalEnergyBurned,
              name: "basal_energy_burned", unit: .kilocalorie(),
              serverUnits: "kcal", isSUM: true, useAvgField: false),
        .init(identifier: .appleExerciseTime,
              name: "apple_exercise_time", unit: .minute(),
              serverUnits: "min", isSUM: true, useAvgField: false),
        .init(identifier: .appleStandTime,
              name: "apple_stand_time", unit: .minute(),
              serverUnits: "min", isSUM: true, useAvgField: false),
        .init(identifier: .distanceWalkingRunning,
              name: "walking_running_distance", unit: .meterUnit(with: .kilo),
              serverUnits: "km", isSUM: true, useAvgField: false),
        .init(identifier: .flightsClimbed,
              name: "flights_climbed", unit: .count(),
              serverUnits: "count", isSUM: true, useAvgField: false),
    ]

    static var allReadTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        for m in avgMetrics + sumMetrics {
            types.insert(HKQuantityType(m.identifier))
        }
        types.insert(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!)
        types.insert(HKObjectType.workoutType())
        if #available(iOS 16.0, *),
           let wristTemp = HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature) {
            types.insert(wristTemp)
        }
        return types
    }

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HKError(.errorHealthDataUnavailable)
        }
        try await store.requestAuthorization(toShare: [], read: Self.allReadTypes)
    }

    // MARK: - Background delivery

    func enableBackgroundDelivery() async throws {
        for m in Self.avgMetrics + Self.sumMetrics {
            try await store.enableBackgroundDelivery(
                for: HKQuantityType(m.identifier), frequency: .immediate
            )
        }
        try await store.enableBackgroundDelivery(
            for: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            frequency: .immediate
        )
    }

    // MARK: - Fetch all

    func fetchAll(since: Date) async throws -> HealthPayload {
        async let avg   = fetchAVGMetrics(since: since)
        async let sum   = fetchSUMMetrics(since: since)
        async let sleep = fetchSleep(since: since)
        let metrics = try await avg + sum + sleep
        return HealthPayload(metrics: metrics.filter { !$0.data.isEmpty })
    }

    // MARK: - AVG metrics

    private func fetchAVGMetrics(since: Date) async throws -> [MetricData] {
        var defs = Self.avgMetrics
        if #available(iOS 16.0, *),
           HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature) != nil {
            defs.append(.init(
                identifier: .appleSleepingWristTemperature,
                name: "wrist_temperature", unit: .degreeCelsius(),
                serverUnits: "degC", isSUM: false, useAvgField: false
            ))
        }
        return try await withThrowingTaskGroup(of: MetricData?.self) { group in
            for def in defs {
                group.addTask { try await self.fetchAVGMetric(def, since: since) }
            }
            var out: [MetricData] = []
            for try await item in group { if let item { out.append(item) } }
            return out
        }
    }

    private func fetchAVGMetric(_ def: MetricDef, since: Date) async throws -> MetricData? {
        let pred = HKQuery.predicateForSamples(withStart: since, end: nil)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: HKQuantityType(def.identifier),
                predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]
            ) { _, raw, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (raw as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }

        guard !samples.isEmpty else { return nil }

        let data: [MetricSample] = samples.map { s in
            let val  = s.quantity.doubleValue(for: def.unit)
            let src  = s.sourceRevision.source.name
            let date = formatForServer(s.startDate)
            return def.useAvgField
                ? .avg(date: date, value: val, source: src)
                : .qty(date: date, value: val, source: src)
        }
        return MetricData(name: def.name, units: def.serverUnits, data: data)
    }

    // MARK: - SUM metrics (hourly)

    private func fetchSUMMetrics(since: Date) async throws -> [MetricData] {
        return try await withThrowingTaskGroup(of: MetricData?.self) { group in
            for def in Self.sumMetrics {
                group.addTask { try await self.fetchSUMMetric(def, since: since) }
            }
            var out: [MetricData] = []
            for try await item in group { if let item { out.append(item) } }
            return out
        }
    }

    private func fetchSUMMetric(_ def: MetricDef, since: Date) async throws -> MetricData? {
        var cal = Calendar.current
        cal.timeZone = .current
        let anchor = cal.date(
            from: cal.dateComponents([.year, .month, .day, .hour], from: since)
        ) ?? since
        let pred = HKQuery.predicateForSamples(withStart: since, end: nil)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(def.identifier),
                quantitySamplePredicate: pred,
                options: [.cumulativeSum, .separateBySource],
                anchorDate: anchor,
                intervalComponents: DateComponents(hour: 1)
            )
            q.initialResultsHandler = { _, collection, err in
                if let err { cont.resume(throwing: err); return }
                guard let collection else { cont.resume(returning: nil); return }

                var samples: [MetricSample] = []
                collection.enumerateStatistics(from: since, to: Date()) { stats, _ in
                    let sources = stats.sources ?? []
                    let bestSource = sources.first(where: {
                        $0.name.localizedCaseInsensitiveContains("Ultra") ||
                        $0.name.localizedCaseInsensitiveContains("Apple Watch") ||
                        $0.name.localizedCaseInsensitiveContains("Watch")
                    }) ?? sources.first(where: {
                        $0.name.localizedCaseInsensitiveContains("iPhone")
                    }) ?? sources.first

                    let quantity = bestSource.flatMap { stats.sumQuantity(for: $0) }
                                ?? stats.sumQuantity()
                    guard let quantity else { return }
                    let val = quantity.doubleValue(for: def.unit)
                    guard val > 0 else { return }
                    samples.append(.qty(
                        date: formatForServer(stats.startDate),
                        value: val,
                        source: bestSource?.name ?? "iPhone"
                    ))
                }
                guard !samples.isEmpty else { cont.resume(returning: nil); return }
                cont.resume(returning: MetricData(name: def.name, units: def.serverUnits, data: samples))
            }
            store.execute(q)
        }
    }

    // MARK: - Sleep

    private func fetchSleep(since: Date) async throws -> [MetricData] {
        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let pred = HKQuery.predicateForSamples(withStart: since, end: nil)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: sleepType,
                predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]
            ) { _, raw, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (raw as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        guard !samples.isEmpty else { return [] }

        struct NightKey: Hashable, Sendable { let source: String; let date: String }

        var grouped: [NightKey: SleepPhases] = [:]
        let cal = Calendar.current

        for s in samples {
            let src  = s.sourceRevision.source.name
            let day  = cal.startOfDay(for: s.endDate)
            let key  = NightKey(source: src, date: formatForServer(day))
            let hrs  = s.endDate.timeIntervalSince(s.startDate) / 3600.0
            grouped[key, default: SleepPhases()].apply(value: s.value, hours: hrs)
        }

        // Source filter: Apple Watch present for a date → drop RingConn for that date
        let watchDates = grouped.keys.reduce(into: Set<String>()) { set, key in
            if isAppleWatch(key.source) { set.insert(key.date) }
        }

        var filtered: [NightKey: SleepPhases] = [:]
        for (key, phases) in grouped {
            if isAppleWatch(key.source) || !watchDates.contains(key.date) {
                filtered[key] = phases
            }
        }

        let data = filtered
            .sorted { $0.key.date < $1.key.date }
            .map { key, p -> MetricSample in
                .sleep(date: key.date, deep: p.deep, rem: p.rem,
                       core: p.core, awake: p.awake, total: p.total, source: key.source)
            }

        return [MetricData(name: "sleep_analysis", units: "hr", data: data)]
    }

    // MARK: - Helpers

    private func isAppleWatch(_ source: String) -> Bool {
        source.localizedCaseInsensitiveContains("Ultra")       ||
        source.localizedCaseInsensitiveContains("Apple Watch") ||
        source.localizedCaseInsensitiveContains("Watch")
    }
}
