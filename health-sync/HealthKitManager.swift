@preconcurrency import HealthKit
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


// MARK: - HealthKitManager

actor HealthKitManager {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()

    // MARK: - Metric catalogue

    static let avgMetrics: [MetricDef] =
        vitalsMetrics + bodyMetrics + gaitMetrics + runningMetrics + cyclingMetrics
        + cardioMetrics + environmentMetrics + dietaryMetrics

    static let sumMetrics: [MetricDef] = activitySumMetrics + distanceSumMetrics

    static let categoryEvents: [CategoryEventDef] = [
        .init(identifierRaw: HKCategoryTypeIdentifier.mindfulSession.rawValue,
              name: "mindful_minutes", kind: .durationMinutes),
        .init(identifierRaw: HKCategoryTypeIdentifier.highHeartRateEvent.rawValue,
              name: "high_heart_rate_event", kind: .count),
        .init(identifierRaw: HKCategoryTypeIdentifier.lowHeartRateEvent.rawValue,
              name: "low_heart_rate_event", kind: .count),
        .init(identifierRaw: HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue,
              name: "irregular_heart_rhythm_event", kind: .count),
        .init(identifierRaw: HKCategoryTypeIdentifier.lowCardioFitnessEvent.rawValue,
              name: "low_cardio_fitness_event", kind: .count),
    ]

    // MARK: Vitals

    private static let vitalsMetrics: [MetricDef] = [
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
        .init(identifier: .walkingHeartRateAverage,
              name: "walking_heart_rate_average", unit: .count().unitDivided(by: .minute()),
              serverUnits: "bpm", isSUM: false, useAvgField: false),
        .init(identifier: .heartRateRecoveryOneMinute,
              name: "heart_rate_recovery", unit: .count().unitDivided(by: .minute()),
              serverUnits: "bpm", isSUM: false, useAvgField: false),
        .init(identifier: .bloodPressureSystolic,
              name: "blood_pressure_systolic", unit: .millimeterOfMercury(),
              serverUnits: "mmHg", isSUM: false, useAvgField: false),
        .init(identifier: .bloodPressureDiastolic,
              name: "blood_pressure_diastolic", unit: .millimeterOfMercury(),
              serverUnits: "mmHg", isSUM: false, useAvgField: false),
        .init(identifier: .vo2Max,
              name: "vo2_max", unit: HKUnit(from: "ml/kg·min"),
              serverUnits: "mL/kg/min", isSUM: false, useAvgField: false),
        .init(identifier: .appleSleepingWristTemperature,
              name: "wrist_temperature", unit: .degreeCelsius(),
              serverUnits: "degC", isSUM: false, useAvgField: false),
        .init(identifier: .bloodGlucose,
              name: "blood_glucose", unit: HKUnit(from: "mg/dL"),
              serverUnits: "mg/dL", isSUM: false, useAvgField: false),
        .init(identifier: .bodyTemperature,
              name: "body_temperature", unit: .degreeCelsius(),
              serverUnits: "degC", isSUM: false, useAvgField: false),
        .init(identifier: .peripheralPerfusionIndex,
              name: "peripheral_perfusion_index", unit: .percent(),
              serverUnits: "%", isSUM: false, useAvgField: false),
        .init(identifier: .bloodAlcoholContent,
              name: "blood_alcohol_content", unit: .percent(),
              serverUnits: "%", isSUM: false, useAvgField: false),
        .init(identifier: .insulinDelivery,
              name: "insulin_delivery", unit: .internationalUnit(),
              serverUnits: "IU", isSUM: false, useAvgField: false),
        .init(identifier: .peakExpiratoryFlowRate,
              name: "peak_expiratory_flow_rate",
              unit: .liter().unitDivided(by: .minute()),
              serverUnits: "L/min", isSUM: false, useAvgField: false),
        .init(identifier: .forcedVitalCapacity,
              name: "forced_vital_capacity", unit: .liter(),
              serverUnits: "L", isSUM: false, useAvgField: false),
        .init(identifier: .forcedExpiratoryVolume1,
              name: "forced_expiratory_volume1", unit: .liter(),
              serverUnits: "L", isSUM: false, useAvgField: false),
    ]

    // MARK: Body composition

    private static let bodyMetrics: [MetricDef] = [
        .init(identifier: .bodyMass,
              name: "body_mass", unit: .gramUnit(with: .kilo),
              serverUnits: "kg", isSUM: false, useAvgField: false),
        .init(identifier: .bodyFatPercentage,
              name: "body_fat_percentage", unit: .percent(),
              serverUnits: "%", isSUM: false, useAvgField: false),
        .init(identifier: .bodyMassIndex,
              name: "body_mass_index", unit: .count(),
              serverUnits: "count", isSUM: false, useAvgField: false),
        .init(identifier: .leanBodyMass,
              name: "lean_body_mass", unit: .gramUnit(with: .kilo),
              serverUnits: "kg", isSUM: false, useAvgField: false),
        .init(identifier: .height,
              name: "height", unit: .meter(),
              serverUnits: "m", isSUM: false, useAvgField: false),
        .init(identifier: .waistCircumference,
              name: "waist_circumference", unit: .meterUnit(with: .centi),
              serverUnits: "cm", isSUM: false, useAvgField: false),
    ]

    // MARK: Gait & mobility

    private static let gaitMetrics: [MetricDef] = [
        .init(identifier: .walkingSpeed,
              name: "walking_speed", unit: .meter().unitDivided(by: .second()),
              serverUnits: "m/s", isSUM: false, useAvgField: false),
        .init(identifier: .walkingStepLength,
              name: "walking_step_length", unit: .meter(),
              serverUnits: "m", isSUM: false, useAvgField: false),
        .init(identifier: .walkingDoubleSupportPercentage,
              name: "walking_double_support_percentage", unit: .percent(),
              serverUnits: "%", isSUM: false, useAvgField: false),
        .init(identifier: .walkingAsymmetryPercentage,
              name: "walking_asymmetry_percentage", unit: .percent(),
              serverUnits: "%", isSUM: false, useAvgField: false),
        .init(identifier: .stairAscentSpeed,
              name: "stair_ascent_speed", unit: .meter().unitDivided(by: .second()),
              serverUnits: "m/s", isSUM: false, useAvgField: false),
        .init(identifier: .stairDescentSpeed,
              name: "stair_descent_speed", unit: .meter().unitDivided(by: .second()),
              serverUnits: "m/s", isSUM: false, useAvgField: false),
        .init(identifier: .appleWalkingSteadiness,
              name: "walking_steadiness", unit: .percent(),
              serverUnits: "%", isSUM: false, useAvgField: false),
        .init(identifier: .sixMinuteWalkTestDistance,
              name: "six_minute_walking_test_distance", unit: .meter(),
              serverUnits: "m", isSUM: false, useAvgField: false),
        .init(identifier: .numberOfTimesFallen,
              name: "number_of_times_fallen", unit: .count(),
              serverUnits: "count", isSUM: false, useAvgField: false),
    ]

    // MARK: Running metrics

    private static let runningMetrics: [MetricDef] = [
        .init(identifier: .runningPower,
              name: "running_power", unit: .watt(),
              serverUnits: "W", isSUM: false, useAvgField: false),
        .init(identifier: .runningSpeed,
              name: "running_speed", unit: .meter().unitDivided(by: .second()),
              serverUnits: "m/s", isSUM: false, useAvgField: false),
        .init(identifier: .runningStrideLength,
              name: "running_stride_length", unit: .meter(),
              serverUnits: "m", isSUM: false, useAvgField: false),
        .init(identifier: .runningVerticalOscillation,
              name: "running_vertical_oscillation", unit: .meterUnit(with: .centi),
              serverUnits: "cm", isSUM: false, useAvgField: false),
        .init(identifier: .runningGroundContactTime,
              name: "running_ground_contact_time", unit: .secondUnit(with: .milli),
              serverUnits: "ms", isSUM: false, useAvgField: false),
    ]

    // MARK: Cycling metrics

    private static let cyclingMetrics: [MetricDef] = [
        .init(identifier: .cyclingPower,
              name: "cycling_power", unit: .watt(),
              serverUnits: "W", isSUM: false, useAvgField: false),
        .init(identifier: .cyclingSpeed,
              name: "cycling_speed", unit: .meter().unitDivided(by: .second()),
              serverUnits: "m/s", isSUM: false, useAvgField: false),
        .init(identifier: .cyclingCadence,
              name: "cycling_cadence", unit: .count().unitDivided(by: .minute()),
              serverUnits: "rpm", isSUM: false, useAvgField: false),
        .init(identifier: .cyclingFunctionalThresholdPower,
              name: "cycling_ftp", unit: .watt(),
              serverUnits: "W", isSUM: false, useAvgField: false),
    ]

    // MARK: Cardio & fitness

    private static let cardioMetrics: [MetricDef] = [
        .init(identifier: .physicalEffort,
              name: "physical_effort", unit: HKUnit(from: "kcal/hr·kg"),
              serverUnits: "kcal/hr·kg", isSUM: false, useAvgField: false),
        .init(identifier: .underwaterDepth,
              name: "underwater_depth", unit: .meter(),
              serverUnits: "m", isSUM: false, useAvgField: false),
        .init(identifier: .waterTemperature,
              name: "water_temperature", unit: .degreeCelsius(),
              serverUnits: "degC", isSUM: false, useAvgField: false),
    ]

    // MARK: Environment & sensors

    private static let environmentMetrics: [MetricDef] = [
        .init(identifier: .environmentalAudioExposure,
              name: "environmental_audio_exposure", unit: .decibelAWeightedSoundPressureLevel(),
              serverUnits: "dBASPL", isSUM: false, useAvgField: false),
        .init(identifier: .headphoneAudioExposure,
              name: "headphone_audio_exposure", unit: .decibelAWeightedSoundPressureLevel(),
              serverUnits: "dBASPL", isSUM: false, useAvgField: false),
        .init(identifier: .uvExposure,
              name: "uv_exposure", unit: .count(),
              serverUnits: "count", isSUM: false, useAvgField: false),
    ]

    // MARK: Dietary — individual meal samples

    private static let dietaryMetrics: [MetricDef] = [
        .init(identifier: .dietaryEnergyConsumed,
              name: "dietary_energy", unit: .kilocalorie(),
              serverUnits: "kcal", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryProtein,
              name: "dietary_protein", unit: .gram(),
              serverUnits: "g", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryFatTotal,
              name: "dietary_fat", unit: .gram(),
              serverUnits: "g", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryFatSaturated,
              name: "dietary_fat_saturated", unit: .gram(),
              serverUnits: "g", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryFatPolyunsaturated,
              name: "dietary_fat_polyunsaturated", unit: .gram(),
              serverUnits: "g", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryFatMonounsaturated,
              name: "dietary_fat_monounsaturated", unit: .gram(),
              serverUnits: "g", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryCarbohydrates,
              name: "dietary_carbs", unit: .gram(),
              serverUnits: "g", isSUM: false, useAvgField: false),
        .init(identifier: .dietarySugar,
              name: "dietary_sugar", unit: .gram(),
              serverUnits: "g", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryFiber,
              name: "dietary_fiber", unit: .gram(),
              serverUnits: "g", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryCholesterol,
              name: "dietary_cholesterol", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietarySodium,
              name: "dietary_sodium", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryPotassium,
              name: "dietary_potassium", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryCalcium,
              name: "dietary_calcium", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryIron,
              name: "dietary_iron", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryPhosphorus,
              name: "dietary_phosphorus", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryMagnesium,
              name: "dietary_magnesium", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryZinc,
              name: "dietary_zinc", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryCopper,
              name: "dietary_copper", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryManganese,
              name: "dietary_manganese", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietarySelenium,
              name: "dietary_selenium", unit: .gramUnit(with: .micro),
              serverUnits: "mcg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryIodine,
              name: "dietary_iodine", unit: .gramUnit(with: .micro),
              serverUnits: "mcg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryVitaminA,
              name: "dietary_vitamin_a", unit: .gramUnit(with: .micro),
              serverUnits: "mcg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryVitaminB6,
              name: "dietary_vitamin_b6", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryVitaminB12,
              name: "dietary_vitamin_b12", unit: .gramUnit(with: .micro),
              serverUnits: "mcg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryVitaminC,
              name: "dietary_vitamin_c", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryVitaminD,
              name: "dietary_vitamin_d", unit: .gramUnit(with: .micro),
              serverUnits: "mcg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryVitaminE,
              name: "dietary_vitamin_e", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryVitaminK,
              name: "dietary_vitamin_k", unit: .gramUnit(with: .micro),
              serverUnits: "mcg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryThiamin,
              name: "dietary_thiamin", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryRiboflavin,
              name: "dietary_riboflavin", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryNiacin,
              name: "dietary_niacin", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryPantothenicAcid,
              name: "dietary_pantothenic_acid", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryFolate,
              name: "dietary_folate", unit: .gramUnit(with: .micro),
              serverUnits: "mcg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryBiotin,
              name: "dietary_biotin", unit: .gramUnit(with: .micro),
              serverUnits: "mcg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryMolybdenum,
              name: "dietary_molybdenum", unit: .gramUnit(with: .micro),
              serverUnits: "mcg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryCaffeine,
              name: "dietary_caffeine", unit: .gramUnit(with: .milli),
              serverUnits: "mg", isSUM: false, useAvgField: false),
        .init(identifier: .dietaryWater,
              name: "dietary_water", unit: .literUnit(with: .milli),
              serverUnits: "mL", isSUM: false, useAvgField: false),
        .init(identifier: .numberOfAlcoholicBeverages,
              name: "alcoholic_beverages", unit: .count(),
              serverUnits: "count", isSUM: false, useAvgField: false),
    ]

    // MARK: Activity SUM (hourly aggregates)

    private static let activitySumMetrics: [MetricDef] = [
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
        .init(identifier: .flightsClimbed,
              name: "flights_climbed", unit: .count(),
              serverUnits: "count", isSUM: true, useAvgField: false),
        .init(identifier: .timeInDaylight,
              name: "time_in_daylight", unit: .minute(),
              serverUnits: "min", isSUM: true, useAvgField: false),
        .init(identifier: .swimmingStrokeCount,
              name: "swimming_stroke_count", unit: .count(),
              serverUnits: "count", isSUM: true, useAvgField: false),
    ]

    // MARK: Distance SUM

    private static let distanceSumMetrics: [MetricDef] = [
        .init(identifier: .distanceWalkingRunning,
              name: "walking_running_distance", unit: .meterUnit(with: .kilo),
              serverUnits: "km", isSUM: true, useAvgField: false),
        .init(identifier: .distanceCycling,
              name: "distance_cycling", unit: .meterUnit(with: .kilo),
              serverUnits: "km", isSUM: true, useAvgField: false),
        .init(identifier: .distanceSwimming,
              name: "distance_swimming", unit: .meterUnit(with: .kilo),
              serverUnits: "km", isSUM: true, useAvgField: false),
    ]

    // MARK: - Read types

    static var allReadTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        for m in avgMetrics + sumMetrics {
            types.insert(HKQuantityType(m.identifier))
        }
        for e in categoryEvents {
            if let t = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: e.identifierRaw)) {
                types.insert(t)
            }
        }
        types.insert(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!)
        types.insert(HKObjectType.workoutType())
        return types
    }

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HKError(.errorHealthDataUnavailable)
        }
        try await store.requestAuthorization(toShare: [], read: Self.allReadTypes)
    }

    // MARK: - Fetch all

    func fetchAll(since: Date) async throws -> [MetricData] {
        async let avg    = fetchAVGMetrics(since: since)
        async let sum    = fetchSUMMetrics(since: since)
        async let sleep  = fetchSleep(since: since)
        async let events = fetchCategoryEvents(since: since)
        let metrics = try await avg + sum + sleep + events
        return metrics.filter { !$0.data.isEmpty }
    }

    // MARK: - Date formatting (actor-isolated — avoids calling @MainActor formatForServer)

    private func serverDate(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        let tz = TimeZone.current
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = tz.secondsFromGMT(for: date)
        let sign = offset >= 0 ? "+" : "-"
        let h = abs(offset) / 3600
        let m = (abs(offset) % 3600) / 60
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d %@%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, sign, h, m)
    }

    // MARK: - AVG metrics

    private func fetchAVGMetrics(since: Date) async throws -> [MetricData] {
        return try await withThrowingTaskGroup(of: MetricData?.self) { group in
            for def in Self.avgMetrics {
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
            let date = serverDate(s.startDate)
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

    // Raw point collected inside nonisolated closure — no HealthKit types, no formatForServer
    private struct SumPoint: Sendable {
        let date: Date; let value: Double; let source: String
    }

    private func fetchSUMMetric(_ def: MetricDef, since: Date) async throws -> MetricData? {
        var cal = Calendar.current
        cal.timeZone = .current
        let anchor = cal.date(
            from: cal.dateComponents([.year, .month, .day, .hour], from: since)
        ) ?? since
        let pred = HKQuery.predicateForSamples(withStart: since, end: nil)

        let rawPoints: [SumPoint]? = try await withCheckedThrowingContinuation { cont in
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

                var points: [SumPoint] = []
                collection.enumerateStatistics(from: since, to: Date()) { stats, _ in
                    let sources = stats.sources ?? []
                    let best = sources.first(where: {
                        $0.name.localizedCaseInsensitiveContains("Ultra") ||
                        $0.name.localizedCaseInsensitiveContains("Apple Watch") ||
                        $0.name.localizedCaseInsensitiveContains("Watch")
                    }) ?? sources.first(where: {
                        $0.name.localizedCaseInsensitiveContains("iPhone")
                    }) ?? sources.first

                    let qty = best.flatMap { stats.sumQuantity(for: $0) } ?? stats.sumQuantity()
                    guard let qty else { return }
                    let val = qty.doubleValue(for: def.unit)
                    guard val > 0 else { return }
                    points.append(SumPoint(date: stats.startDate, value: val, source: best?.name ?? "iPhone"))
                }
                cont.resume(returning: points.isEmpty ? nil : points)
            }
            store.execute(q)
        }

        guard let rawPoints else { return nil }
        // Format dates in actor-isolated context, after the await
        let samples = rawPoints.map { p in
            MetricSample.qty(date: serverDate(p.date), value: p.value, source: p.source)
        }
        return MetricData(name: def.name, units: def.serverUnits, data: samples)
    }

    // MARK: - Category events

    private func fetchCategoryEvents(since: Date) async throws -> [MetricData] {
        return try await withThrowingTaskGroup(of: MetricData?.self) { group in
            for def in Self.categoryEvents {
                group.addTask { try await self.fetchCategoryEvent(def, since: since) }
            }
            var out: [MetricData] = []
            for try await item in group { if let item { out.append(item) } }
            return out
        }
    }

    private func fetchCategoryEvent(_ def: CategoryEventDef, since: Date) async throws -> MetricData? {
        guard let sampleType = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: def.identifierRaw)) else {
            return nil
        }
        let pred = HKQuery.predicateForSamples(withStart: since, end: nil)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: sampleType,
                predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]
            ) { _, raw, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (raw as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }

        guard !samples.isEmpty else { return nil }

        let data: [MetricSample] = samples.map { s in
            let val: Double
            switch def.kind {
            case .durationMinutes:
                val = s.endDate.timeIntervalSince(s.startDate) / 60.0
            case .count:
                val = 1.0
            }
            return .qty(
                date: serverDate(s.startDate),
                value: val,
                source: s.sourceRevision.source.name
            )
        }
        // Avoid Equatable on CategoryEventDef.ValueKind — use switch instead of ==
        let units: String
        switch def.kind {
        case .durationMinutes: units = "min"
        case .count:           units = "count"
        }
        return MetricData(name: def.name, units: units, data: data)
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
        // Plain tuple — avoids @MainActor contamination that affects SleepPhases when used in this file
        typealias Accum = (deep: Double, rem: Double, core: Double, awake: Double, total: Double)

        var grouped: [NightKey: Accum] = [:]
        let cal = Calendar.current

        for s in samples {
            let src = s.sourceRevision.source.name
            let day = cal.startOfDay(for: s.endDate)
            let key = NightKey(source: src, date: serverDate(day))
            let hrs = s.endDate.timeIntervalSince(s.startDate) / 3600.0
            var p = grouped[key] ?? (deep: 0, rem: 0, core: 0, awake: 0, total: 0)
            switch s.value {
            case 5:        p.deep  += hrs; p.total += hrs
            case 6:        p.rem   += hrs; p.total += hrs
            case 1, 3, 4:  p.core  += hrs; p.total += hrs
            case 2:        p.awake += hrs
            default:       break
            }
            grouped[key] = p
        }

        let watchDates = grouped.keys.reduce(into: Set<String>()) { set, key in
            if isAppleWatch(key.source) { set.insert(key.date) }
        }

        let data = grouped
            .filter { isAppleWatch($0.key.source) || !watchDates.contains($0.key.date) }
            .sorted { $0.key.date < $1.key.date }
            .map { (key, p) -> MetricSample in
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
