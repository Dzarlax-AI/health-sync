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
    // Accessible from same-module extensions in other files (e.g. WorkoutSync.swift)
    // that issue HKSampleQueries against this actor's store.
    let store = HKHealthStore()

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

    func fetchAll(since: Date, until: Date? = nil, includeSleep: Bool = true) async throws -> [MetricData] {
        async let avg    = fetchAVGMetrics(since: since, until: until)
        async let sum    = fetchSUMMetrics(since: since, until: until)
        async let events = fetchCategoryEvents(since: since, until: until)
        var metrics = try await avg + sum + events
        if includeSleep {
            let sleep = try await fetchSleep(since: since, until: until)
            metrics += sleep
        }
        return metrics.filter { !$0.data.isEmpty }
    }

    // Public entry point for the chunked re-sync: sleep is fetched ONCE for the
    // whole re-sync window instead of per day-chunk. Per-day chunking caused
    // earlier chunks to overwrite later chunks' sleep aggregates because each
    // chunk's 12h-overlap window saw a different subset of sleep sessions
    // (one chunk: full night; next chunk: only a nap). With a single window
    // covering the entire re-sync period, every session is grouped under its
    // wake-up date exactly once and the server upserts a complete value.
    func fetchSleepOnly(since: Date, until: Date? = nil) async throws -> [MetricData] {
        return try await fetchSleep(since: since, until: until)
    }

    // MARK: - Date formatting (actor-isolated — avoids calling @MainActor formatForServer)

    // Internal so same-module extensions in other files (WorkoutSync.swift) can
    // format dates without hopping to the @MainActor `formatForServer`.
    func serverDate(_ date: Date) -> String {
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

    private func fetchAVGMetrics(since: Date, until: Date? = nil) async throws -> [MetricData] {
        return try await withThrowingTaskGroup(of: MetricData?.self) { group in
            for def in Self.avgMetrics {
                group.addTask { try await self.fetchAVGMetric(def, since: since, until: until) }
            }
            var out: [MetricData] = []
            for try await item in group { if let item { out.append(item) } }
            return out
        }
    }

    // HKUnit.percent() returns a fraction (0.0–1.0). Server expects 0–100.
    private static let percentUnit = HKUnit.percent()
    private func scaledValue(_ q: HKQuantity, def: MetricDef) -> Double {
        let v = q.doubleValue(for: def.unit)
        return def.unit == Self.percentUnit ? v * 100.0 : v
    }

    private func fetchAVGMetric(_ def: MetricDef, since: Date, until: Date? = nil) async throws -> MetricData? {
        let pred = HKQuery.predicateForSamples(withStart: since, end: until)
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
            let val  = self.scaledValue(s.quantity, def: def)
            let src  = s.sourceRevision.source.name
            let date = serverDate(s.startDate)
            return def.useAvgField
                ? .avg(date: date, value: val, source: src)
                : .qty(date: date, value: val, source: src)
        }
        return MetricData(name: def.name, units: def.serverUnits, data: data)
    }

    // MARK: - SUM metrics (hourly)

    private func fetchSUMMetrics(since: Date, until: Date? = nil) async throws -> [MetricData] {
        return try await withThrowingTaskGroup(of: MetricData?.self) { group in
            for def in Self.sumMetrics {
                group.addTask { try await self.fetchSUMMetric(def, since: since, until: until) }
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

    private func fetchSUMMetric(_ def: MetricDef, since: Date, until: Date? = nil) async throws -> MetricData? {
        var cal = Calendar.current
        cal.timeZone = .current
        let anchor = cal.date(
            from: cal.dateComponents([.year, .month, .day, .hour], from: since)
        ) ?? since
        let pred = HKQuery.predicateForSamples(withStart: since, end: until)
        let endDate = until ?? Date()

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
                collection.enumerateStatistics(from: since, to: endDate) { stats, _ in
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

    private func fetchCategoryEvents(since: Date, until: Date? = nil) async throws -> [MetricData] {
        return try await withThrowingTaskGroup(of: MetricData?.self) { group in
            for def in Self.categoryEvents {
                group.addTask { try await self.fetchCategoryEvent(def, since: since, until: until) }
            }
            var out: [MetricData] = []
            for try await item in group { if let item { out.append(item) } }
            return out
        }
    }

    private func fetchCategoryEvent(_ def: CategoryEventDef, since: Date, until: Date? = nil) async throws -> MetricData? {
        guard let sampleType = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: def.identifierRaw)) else {
            return nil
        }
        let pred = HKQuery.predicateForSamples(withStart: since, end: until)
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

    private func fetchSleep(since: Date, until: Date? = nil) async throws -> [MetricData] {
        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        // Always look back at least 7 days so any "live" sync (regular
        // foreground / background / HKObserverQuery wake) sees full sleep
        // sessions for recent nights, not just whatever sliver overlaps the
        // 24h incremental-sync window. A truncated 24h window catches only
        // the late-morning fragment of the previous night and ships
        // total=2.5h, which the server's UPSERT then locks in via the
        // inflation guard before the next chunked re-sync can correct it.
        // Sleep is low-volume (~1–10 samples/day), the extra fetch is free.
        // For long re-sync windows we still honour `since`.
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let twelveBefore = since.addingTimeInterval(-12 * 3600)
        let sleepWindowStart = min(twelveBefore, sevenDaysAgo)
        let pred = HKQuery.predicateForSamples(withStart: sleepWindowStart, end: until)
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

        // Group samples into "sessions" first, then assign a NightKey to each
        // session based on the LAST asleep-* fragment's wake-up date — that's
        // how Apple Health UI reports sleep ("4h on May 3" means woke up on
        // May 3, regardless of when the night started). Naive grouping by
        // each fragment's `endDate.startOfDay` splits a single night across
        // two days when fragments cross midnight (e.g. asleepCore ending
        // 23:55 → date 04-26; asleepREM ending 00:30 → date 04-27).
        //
        // Session = consecutive samples from the same source whose gap
        // ≤ 30 min. Inactivity longer than that = different session.
        let sessionGap: TimeInterval = 30 * 60
        let sortedBySource = samples.sorted {
            if $0.sourceRevision.source.name == $1.sourceRevision.source.name {
                return $0.startDate < $1.startDate
            }
            return $0.sourceRevision.source.name < $1.sourceRevision.source.name
        }

        struct Session {
            let source: String
            var samples: [HKCategorySample]
            var lastAsleepEnd: Date? // wake-up moment for date assignment
        }
        var sessions: [Session] = []

        for s in sortedBySource {
            let src = s.sourceRevision.source.name
            if var last = sessions.last,
               last.source == src,
               let prevEnd = last.samples.last?.endDate,
               s.startDate.timeIntervalSince(prevEnd) <= sessionGap {
                last.samples.append(s)
                if isAsleepValue(s.value) { last.lastAsleepEnd = s.endDate }
                sessions[sessions.count - 1] = last
            } else {
                sessions.append(Session(
                    source: src,
                    samples: [s],
                    lastAsleepEnd: isAsleepValue(s.value) ? s.endDate : nil
                ))
            }
        }

        // Per-session asleep duration (sum of asleep* fragments, no
        // awake/inBed) so we can classify and split into main vs
        // nap below.
        //
        // Same coarse-vs-fine guard as the aggregate loop: when the
        // session has per-stage markers (.asleepDeep/.asleepREM/
        // .asleepCore), skip the coarse `.asleepUnspecified` /
        // `.asleep` rows that overlay the same wall-clock window
        // — otherwise an 8h night with full stage breakdown reports
        // ~16h asleep, inflating main_total / nap_total.
        func asleepHours(_ session: Session) -> Double {
            let hasSpecificStages = session.samples.contains { s in
                switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                case .asleepDeep, .asleepREM, .asleepCore: return true
                default:                                   return false
                }
            }
            return session.samples.reduce(into: 0.0) { acc, s in
                guard isAsleepValue(s.value) else { return }
                let raw = HKCategoryValueSleepAnalysis(rawValue: s.value)
                if hasSpecificStages && (raw == .asleepUnspecified || raw == .asleep) {
                    return
                }
                acc += s.endDate.timeIntervalSince(s.startDate) / 3600.0
            }
        }

        // Group sessions by (source, wake-up date) to classify within each day.
        // Within a (source, day) the LONGEST asleep session is "main"; every
        // other session is a "nap". Apple's own UI uses Sleep Schedule
        // configuration to pick the main block, but HealthKit doesn't expose
        // that flag, so longest-wins is the most robust public-API heuristic.
        // No minimum threshold: even a 2h "main" night is still classified as
        // main if it's the only or longest sleep that day — better than
        // hiding it. Naps are everything else.
        struct DayKey: Hashable { let source: String; let date: String }
        var sessionsByDay: [DayKey: [Session]] = [:]
        for session in sessions {
            let wakeMoment = session.lastAsleepEnd ?? session.samples.last!.endDate
            let day = cal.startOfDay(for: wakeMoment)
            let dk = DayKey(source: session.source, date: serverDate(day))
            sessionsByDay[dk, default: []].append(session)
        }

        // Build the legacy phase aggregate per NightKey (sum of all sessions —
        // unchanged, preserves backward-compatible sleep_total / sleep_deep / …)
        // AND the new main_total / nap_total per (source, day).
        var mainTotals: [DayKey: Double] = [:]
        var napTotals:  [DayKey: Double] = [:]

        // Per-segment emission: one MetricSample per HKCategorySample, attributed
        // to the wake-up DayKey of its containing session so the dropKnownDup
        // filter (Apple Watch wins over RingConn for the same night) applies
        // uniformly across aggregate AND fragment data. Required by the
        // server-side v2.2 stress methodology (STRESS_MEASUREMENT.md) which
        // needs per-segment timestamps to derive awake-window, overnight RHR
        // baselines, and sustained-HR-load hourly z-series. The Health Auto
        // Export iOS app used to deliver this shape natively; our client
        // aggregated it away when we replaced HAE. The server's existing
        // sleepDedupClause excludes the midnight-summary rows whenever
        // per-segment fragments exist, so shipping both is safe — fragments
        // win where they exist, the nightly aggregate is kept as fallback for
        // tools that don't dedup.
        var perSegmentByPhase: [String: [(dk: DayKey, sample: HKCategorySample)]] = [
            "sleep_deep":  [],
            "sleep_rem":   [],
            "sleep_core":  [],
            "sleep_awake": [],
        ]

        for (dk, dailySessions) in sessionsByDay {
            // Identify main = the session with the largest asleep duration.
            let durations = dailySessions.map { asleepHours($0) }
            let maxDuration = durations.max() ?? 0
            let mainIndex = durations.firstIndex(of: maxDuration) ?? 0
            let withDurations = zip(dailySessions, durations)
            let key = NightKey(source: dk.source, date: dk.date)

            var p = grouped[key] ?? (deep: 0, rem: 0, core: 0, awake: 0, total: 0)
            var mainHrs = 0.0
            var napHrs  = 0.0

            for (i, (session, asleepHrs)) in withDurations.enumerated() {
                let isMain = (i == mainIndex && asleepHrs > 0)
                // Apple Watch on iOS 26 emits sleep samples in two
                // concurrent layers for the same wall-clock time:
                //
                //   1. A coarse `.asleepUnspecified` (or legacy
                //      `.asleep`) covering the whole sleep block —
                //      what older apps relied on.
                //   2. Fine-grained `.asleepCore` / `.asleepREM` /
                //      `.asleepDeep` segments breaking that block
                //      into the stage timeline that Health.app shows.
                //
                // Counting both double-bills core: a single 8h night
                // ends up as 8h "unspecified" + 6h core + 1h REM +
                // 1h deep ≈ 16h total. Detect the specific-stage
                // markers per session; when present, skip the
                // coarse layer to avoid the overlap. When only the
                // coarse layer exists (older watch, RingConn, iPhone
                // Sleep Schedule estimates) we keep using it so
                // those sources don't silently zero out.
                let hasSpecificStages = session.samples.contains { s in
                    switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                    case .asleepDeep, .asleepREM, .asleepCore: return true
                    default:                                   return false
                    }
                }
                for s in session.samples {
                    let hrs = s.endDate.timeIntervalSince(s.startDate) / 3600.0
                    switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                    case .asleepDeep:               p.deep += hrs; p.total += hrs
                    case .asleepREM:                p.rem  += hrs; p.total += hrs
                    case .asleepCore:               p.core += hrs; p.total += hrs
                    case .asleepUnspecified, .asleep:
                        if !hasSpecificStages {
                            // Fallback: source has no per-stage data,
                            // attribute coarse asleep time to core so
                            // bank/score still gets a sleep_total.
                            p.core += hrs
                            p.total += hrs
                        }
                    case .awake:                    p.awake += hrs
                    case .inBed, .none, .some(_):   break
                    }
                    // Per-segment emission for the server's v2.2
                    // hourly window — same overlap guard as the
                    // aggregate so per-stage rows on disk don't
                    // double-count either.
                    let raw = HKCategoryValueSleepAnalysis(rawValue: s.value)
                    let skipCoarseOverlap = hasSpecificStages &&
                        (raw == .asleepUnspecified || raw == .asleep)
                    if !skipCoarseOverlap, let phase = Self.sleepPhaseName(for: s.value) {
                        perSegmentByPhase[phase]?.append((dk: dk, sample: s))
                    }
                }
                if isMain { mainHrs += asleepHrs } else { napHrs += asleepHrs }
            }
            grouped[key] = p
            mainTotals[dk] = mainHrs
            napTotals[dk]  = napHrs
        }

        // Drop only known-duplicate sources (e.g. RingConn) when an Apple Watch
        // record exists for the same night. Other sources (iPhone Sleep
        // Schedule, third-party trackers without known duplication) are
        // preserved — Apple Watch sometimes only logs a short fragment while
        // the iPhone holds the rest of the night, and dropping it loses real
        // sleep time.
        let watchDates = grouped.keys.reduce(into: Set<String>()) { set, key in
            if isAppleWatch(key.source) { set.insert(key.date) }
        }
        let dropKnownDup: (String, String) -> Bool = { source, date in
            Self.isKnownDuplicateName(source) && watchDates.contains(date)
        }

        let sleepAnalysisData = grouped
            .filter { !dropKnownDup($0.key.source, $0.key.date) }
            .sorted { $0.key.date < $1.key.date }
            .map { (key, p) -> MetricSample in
                .sleep(date: key.date, deep: p.deep, rem: p.rem,
                       core: p.core, awake: p.awake, total: p.total, source: key.source)
            }

        let mainData = mainTotals
            .filter { !dropKnownDup($0.key.source, $0.key.date) }
            .sorted { $0.key.date < $1.key.date }
            .map { dk, hrs in
                MetricSample.qty(date: dk.date, value: hrs, source: dk.source)
            }
        let napData = napTotals
            .filter { !dropKnownDup($0.key.source, $0.key.date) }
            .sorted { $0.key.date < $1.key.date }
            .map { dk, hrs in
                MetricSample.qty(date: dk.date, value: hrs, source: dk.source)
            }

        // Per-segment payloads — one MetricSample.qty per HKCategorySample.
        // Same dropKnownDup filter as the aggregate path so Apple Watch
        // dominates RingConn fragments on shared nights.
        func buildSegmentData(_ phase: String) -> [MetricSample] {
            (perSegmentByPhase[phase] ?? [])
                .filter { !dropKnownDup($0.dk.source, $0.dk.date) }
                .sorted { $0.sample.startDate < $1.sample.startDate }
                .map { entry -> MetricSample in
                    let hrs = entry.sample.endDate.timeIntervalSince(entry.sample.startDate) / 3600.0
                    return MetricSample.qty(
                        date: formatForServer(entry.sample.startDate),
                        value: hrs,
                        source: entry.dk.source
                    )
                }
        }
        let deepSeg  = buildSegmentData("sleep_deep")
        let remSeg   = buildSegmentData("sleep_rem")
        let coreSeg  = buildSegmentData("sleep_core")
        let awakeSeg = buildSegmentData("sleep_awake")

        // Use names WITHOUT the `sleep_` prefix so the server-side guards on
        // `sleep_%` (zero-overwrite, ≥1.3× inflation, ≥50% deflation) don't
        // get triggered by legitimate intra-day growth — e.g. nap_total of
        // 0h → 1h → 2.5h as the user takes another nap; or night_sleep_total
        // climbing from 1h to 7h as more of the watch's sleep classifier
        // output trickles in throughout the morning.
        //
        // The per-segment sleep_deep/rem/core/awake entries DO use the
        // `sleep_` prefix and so DO hit the server inflation guards. That is
        // intentional: each per-segment row has a unique timestamped `date`
        // (e.g. "2026-05-12 04:20 +0200"), so UPSERT-by-(name,date,source)
        // never overwrites — the inflation guard only triggers on the same
        // (name,date) pair growing/shrinking, which is what we want for
        // multi-source nightly aggregates but not a concern for per-second
        // start-timestamped fragments.
        return [
            MetricData(name: "sleep_analysis",   units: "hr", data: sleepAnalysisData),
            MetricData(name: "night_sleep_total", units: "hr", data: mainData),
            MetricData(name: "nap_total",        units: "hr", data: napData),
            MetricData(name: "sleep_deep",       units: "hr", data: deepSeg),
            MetricData(name: "sleep_rem",        units: "hr", data: remSeg),
            MetricData(name: "sleep_core",       units: "hr", data: coreSeg),
            MetricData(name: "sleep_awake",      units: "hr", data: awakeSeg),
        ]
    }

    /// Maps an `HKCategoryValueSleepAnalysis` raw value to the server-side
    /// per-segment metric name. Returns nil for `.inBed` and unknown values —
    /// those are dropped from per-segment emission entirely. Pure, no
    /// HealthKit object construction — keeps the function trivially
    /// unit-testable via the `HKCategoryValueSleepAnalysis.<case>.rawValue`
    /// integer constants. Mirrors the classification in `fetchSleep`'s
    /// inner switch — the two MUST stay in lockstep.
    static func sleepPhaseName(for rawValue: Int) -> String? {
        switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
        case .asleepDeep:                                           return "sleep_deep"
        case .asleepREM:                                            return "sleep_rem"
        case .asleepCore, .asleepUnspecified, .asleep:              return "sleep_core"
        case .awake:                                                return "sleep_awake"
        case .inBed, .none, .some(_):                               return nil
        }
    }

    // MARK: - Helpers

    private func isAppleWatch(_ source: String) -> Bool {
        source.localizedCaseInsensitiveContains("Ultra")       ||
        source.localizedCaseInsensitiveContains("Apple Watch") ||
        source.localizedCaseInsensitiveContains("Watch")
    }

    private func isKnownDuplicate(_ source: String) -> Bool {
        Self.isKnownDuplicateName(source)
    }

    /// Static counterpart of isKnownDuplicate — usable from non-isolated
    /// closures (e.g. inside the actor's local computations) without
    /// triggering Swift 6 actor-isolation diagnostics on `self` capture.
    static func isKnownDuplicateName(_ source: String) -> Bool {
        source.localizedCaseInsensitiveContains("RingConn") ||
        source.localizedCaseInsensitiveContains("Ring")
    }

    /// True for HKCategoryValueSleepAnalysis values that represent actual
    /// sleep (any phase). Used to identify the "wake-up" boundary of a
    /// sleep session — the moment of the last asleep fragment, regardless
    /// of trailing awake/inBed records.
    private func isAsleepValue(_ raw: Int) -> Bool {
        switch HKCategoryValueSleepAnalysis(rawValue: raw) {
        case .asleepDeep, .asleepREM, .asleepCore, .asleepUnspecified, .asleep:
            return true
        default:
            return false
        }
    }
}
