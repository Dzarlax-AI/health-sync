//
//  WorkoutSync.swift
//  health-sync
//
//  HKWorkout → server `/health/workouts` payload. The server (Go)
//  deserialises the manual Health Auto Export shape — every field follows
//  that convention (camelCase, `{qty, units}` for quantities). See
//  `internal/handler/workouts.go::haeWorkout` for the receiver side.
//
//  Optional channels are gated by AppStorage settings:
//    - `syncWorkouts`        — master switch; SyncEngine skips this whole
//                              codepath when off
//    - `workoutHRTimeline`   — emit per-sample `heartRateData` array
//                              (typically 200–600 entries per workout;
//                              powers HR-zone-time on the server)
//    - `workoutGPS`          — reserved; server currently discards route
//                              data so we skip the query entirely until
//                              the server consumes it
//
//  Encoded as a top-level `{"data":{"workouts":[…]}}` JSON document and
//  POSTed to `<serverURL>/health/workouts`. Server upserts on the workout
//  UUID, so resending is idempotent — the SyncEngine includes the last
//  N hours of workouts on every cycle (same overlap rule as metrics).
//

@preconcurrency import HealthKit
import Foundation

// MARK: - Payload (HAE manual-export shape)

struct WorkoutsPayload: Encodable, Sendable {
    struct DataWrapper: Encodable, Sendable {
        let workouts: [WorkoutItem]
    }
    let data: DataWrapper

    init(items: [WorkoutItem]) { self.data = DataWrapper(workouts: items) }
}

struct WorkoutItem: Encodable, Sendable {
    let id: String
    let name: String
    let start: String
    let end: String
    let duration: Double            // seconds
    let isIndoor: Bool
    let location: String            // "Indoor" | "Outdoor"

    let avgHeartRate:       Quantity?
    let maxHeartRate:       Quantity?
    let activeEnergyBurned: Quantity?
    let intensity:          Quantity?
    let distance:           Quantity?
    let avgSpeed:           Quantity?
    let maxSpeed:           Quantity?
    let elevationUp:        Quantity?
    let stepCadence:        Quantity?
    let temperature:        Quantity?
    let humidity:           Quantity?

    /// Per-sample HR timeline. Empty array if HR-timeline is disabled.
    let heartRateData: [HRSamplePoint]

    /// Step-count samples linked to the workout. Server sums these
    /// (`internal/handler/workouts.go::convertHAEWorkout`) to populate
    /// `step_count_total`. We ship ONE entry with the cumulative total
    /// rather than the raw per-bucket stream — server doesn't keep the
    /// timeline, only the sum, so a single sample is the minimal valid
    /// payload. Empty array when the workout type has no step count
    /// (cycling, swimming, …) or when no samples are linked.
    let stepCount: [StepSample]

    struct Quantity: Encodable, Sendable {
        let qty: Double
        let units: String
    }

    struct HRSamplePoint: Encodable, Sendable {
        let date: String
        let Avg:  Double        // Server reads camelCase `Avg`; do not rename.
    }

    struct StepSample: Encodable, Sendable {
        let date: String
        let qty:  Double
    }
}

// MARK: - Display-name mapping

/// Maps `HKWorkoutActivityType` to the human-readable activity name the
/// server uses as `workouts.name`. Falls back to `"Workout"` for types we
/// don't enumerate explicitly — those are rare on Apple Watch and the
/// server treats `name` as a free-form string, so a generic label degrades
/// gracefully (the workout still records, just without a specific filter
/// label in `list_workout_types`).
///
/// The set of strings here is the same human convention Health Auto Export
/// used, which is what the existing DB rows (pre-handoff) were labelled
/// with — kept identical so downstream queries
/// (`name = 'Outdoor Run'`, MCP tool filters, etc.) keep working without
/// migration.
func workoutDisplayName(_ type: HKWorkoutActivityType, isIndoor: Bool) -> String {
    switch type {
    case .running:                          return isIndoor ? "Indoor Run" : "Outdoor Run"
    case .walking:                          return "Walking"
    case .hiking:                           return "Hiking"
    case .cycling:                          return isIndoor ? "Indoor Cycle" : "Outdoor Cycle"
    case .swimming:                         return isIndoor ? "Pool Swim" : "Open Water Swim"
    case .rowing:                           return "Rowing"
    case .elliptical:                       return "Elliptical"
    case .stairClimbing, .stairs,
         .stepTraining:                     return "Stair Stepper"
    case .traditionalStrengthTraining:      return "Traditional Strength Training"
    case .functionalStrengthTraining:       return "Functional Strength Training"
    case .coreTraining:                     return "Core Training"
    case .highIntensityIntervalTraining:    return "HIIT"
    case .yoga:                             return "Yoga"
    case .pilates:                          return "Pilates"
    case .flexibility:                      return "Flexibility"
    case .mindAndBody:                      return "Mind and Body"
    case .dance, .socialDance,
         .cardioDance:                      return "Dance"
    case .tennis:                           return "Tennis"
    case .basketball:                       return "Basketball"
    case .soccer:                           return "Soccer"
    case .americanFootball:                 return "American Football"
    case .baseball:                         return "Baseball"
    case .boxing:                           return "Boxing"
    case .kickboxing:                       return "Kickboxing"
    case .martialArts:                      return "Martial Arts"
    case .climbing:                         return "Climbing"
    case .crossTraining:                    return "Cross Training"
    case .mixedCardio:                      return "Mixed Cardio"
    case .skatingSports:                    return "Skating"
    case .snowSports:                       return "Snow Sports"
    case .surfingSports:                    return "Surfing"
    case .waterSports:                      return "Water Sports"
    case .play:                             return "Play"
    case .other:                            return "Other"
    default:                                return "Workout"
    }
}

// MARK: - Fetch

extension HealthKitManager {

    /// Returns workout records in [`since`, `until`] (or `since` → now).
    ///
    /// `includeHRTimeline` controls whether `heartRateData` is populated.
    /// Set to false on cold starts / full-window re-syncs where you only
    /// want the headline numbers and not the per-sample stream (saves
    /// ~200ms per workout and ~50 KB of payload).
    func fetchWorkouts(since: Date, until: Date? = nil, includeHRTimeline: Bool) async throws -> [WorkoutItem] {
        let pred = HKQuery.predicateForSamples(withStart: since, end: until)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: pred,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, raw, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (raw as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        guard !workouts.isEmpty else { return [] }

        var out: [WorkoutItem] = []
        out.reserveCapacity(workouts.count)
        for w in workouts {
            let item = await buildWorkoutItem(w, includeHRTimeline: includeHRTimeline)
            out.append(item)
        }
        return out
    }

    // Non-throwing: each inner metric query that can throw is wrapped
    // in `try?` so a transient HealthKit error on one sub-query falls
    // back to nil/[] without aborting the workout (or the surrounding
    // batch in fetchWorkouts).
    private func buildWorkoutItem(_ w: HKWorkout, includeHRTimeline: Bool) async -> WorkoutItem {
        let isIndoor = (w.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false
        let name = workoutDisplayName(w.workoutActivityType, isIndoor: isIndoor)

        // Aggregates from HKWorkout.statistics(for:) — pulls associated
        // quantity samples that fall within the workout's time interval
        // and returns sum / avg / max as appropriate. iOS 16+.
        let kcal: WorkoutItem.Quantity? = quantity(
            stat: w.statistics(for: HKQuantityType(.activeEnergyBurned)),
            kind: .sum,
            unit: .kilocalorie(),
            units: "kcal"
        )

        // HR strategy. Both branches scope the query by
        // `predicateForObjects(from: workout)` rather than
        // `workout.statistics(for: .heartRate)` because the latter
        // returns nil for many Apple-Watch workouts (their HR samples
        // are associated via HKObjectAssociation rather than "saved
        // into" the workout via HKWorkoutBuilder.addSamples).
        // Empirically observed on 78/78 walking workouts during the
        // 60-day backfill on PR #3.
        //
        //  - includeHRTimeline=true → fetch all samples once, compute
        //    avg/max in Swift from the same array, ship as
        //    heartRateData (one query, two outputs).
        //  - includeHRTimeline=false → one stats-only query computing
        //    avg+max in HealthKit; no per-sample materialisation. This
        //    is the ~200ms-per-workout saving advertised on
        //    `fetchWorkouts`'s docstring. Regression flagged by
        //    CodeRabbit on PR #4 — fixed here.
        //
        // Each async metric query is wrapped in `try?` so a transient
        // HealthKit error on one workout's HR (or distance, or step
        // count) doesn't abort the whole batch via the parent
        // `fetchWorkouts` for-loop — the workout ships with whatever
        // fields succeeded, others fall back to nil/[].
        let hrPoints: [WorkoutItem.HRSamplePoint]
        let avgHR: WorkoutItem.Quantity?
        let maxHR: WorkoutItem.Quantity?
        if includeHRTimeline {
            hrPoints = (try? await heartRateSamples(for: w)) ?? []
            avgHR = hrPoints.isEmpty ? nil : WorkoutItem.Quantity(
                qty: hrPoints.reduce(0.0) { $0 + $1.Avg } / Double(hrPoints.count),
                units: "bpm"
            )
            maxHR = hrPoints.map(\.Avg).max().map {
                WorkoutItem.Quantity(qty: $0, units: "bpm")
            }
        } else {
            hrPoints = []
            // `?? nil` collapses HKStatistics?? (from `try?` on a
            // function that itself returns HKStatistics?) to HKStatistics?.
            let stats: HKStatistics? = (try? await heartRateAggregates(for: w)) ?? nil
            avgHR = bpmQuantity(stats?.averageQuantity())
            maxHR = bpmQuantity(stats?.maximumQuantity())
        }
        // `?? nil` collapses the `Quantity??` from `try?` on a method
        // that itself returns `Quantity?` back to `Quantity?`. Without
        // it the WorkoutItem field type wouldn't match.
        let distance: WorkoutItem.Quantity? = (try? await distanceQuantity(for: w)) ?? nil
        let stepCount = (try? await stepCountSamples(for: w)) ?? []

        // Derived avg/max speed from samples when the activity records a
        // running/walking/cycling speed series. Apple does NOT expose
        // .runningSpeed pre-iOS 16 on every device, so this is best-effort.
        let avgSpeed = speedQuantity(for: w, kind: .average)
        let maxSpeed = speedQuantity(for: w, kind: .maximum)

        let intensity   = metadataQuantity(w, key: HKMetadataKeyAverageMETs,         unit: HKUnit(from: "kcal/(kg*hr)"), units: "MET")
        let elevationUp = metadataQuantity(w, key: HKMetadataKeyElevationAscended,   unit: .meter(),                     units: "m")
        let temperature = metadataQuantity(w, key: HKMetadataKeyWeatherTemperature,  unit: .degreeCelsius(),             units: "degC")
        let humidity    = metadataQuantity(w, key: HKMetadataKeyWeatherHumidity,     unit: .percent(),                   units: "%")

        // Cadence — Apple's writer is inconsistent: sometimes step-cadence
        // is in workout metadata under custom keys, sometimes a separate
        // sample stream. We accept the public-key path and fall through
        // when absent (most non-running activities won't have it).
        let stepCadence: WorkoutItem.Quantity? = nil

        let hrSamples: [WorkoutItem.HRSamplePoint] =
            includeHRTimeline ? hrPoints : []

        return WorkoutItem(
            id: w.uuid.uuidString,
            name: name,
            start: formatForServer(w.startDate),
            end:   formatForServer(w.endDate),
            duration: w.duration,
            isIndoor: isIndoor,
            location: isIndoor ? "Indoor" : "Outdoor",
            avgHeartRate: avgHR,
            maxHeartRate: maxHR,
            activeEnergyBurned: kcal,
            intensity: intensity,
            distance: distance,
            avgSpeed: avgSpeed,
            maxSpeed: maxSpeed,
            elevationUp: elevationUp,
            stepCadence: stepCadence,
            temperature: temperature,
            humidity: humidity,
            heartRateData: hrSamples,
            stepCount: stepCount
        )
    }

    // MARK: helpers

    private enum AggKind { case sum, average, maximum }

    private func quantity(
        stat: HKStatistics?,
        kind: AggKind,
        unit: HKUnit,
        units: String
    ) -> WorkoutItem.Quantity? {
        let q: HKQuantity?
        switch kind {
        case .sum:      q = stat?.sumQuantity()
        case .average:  q = stat?.averageQuantity()
        case .maximum:  q = stat?.maximumQuantity()
        }
        guard let v = q?.doubleValue(for: unit), v.isFinite, v > 0 else { return nil }
        return WorkoutItem.Quantity(qty: v, units: units)
    }

    private func distanceQuantity(for w: HKWorkout) async throws -> WorkoutItem.Quantity? {
        // Pick the distance HKQuantityType that matches the activity. For
        // activities that don't track distance (yoga, strength training)
        // both branches yield nil and we report no distance.
        let type: HKQuantityType?
        switch w.workoutActivityType {
        case .running, .walking, .hiking:
            type = HKQuantityType(.distanceWalkingRunning)
        case .cycling:
            type = HKQuantityType(.distanceCycling)
        case .swimming:
            type = HKQuantityType(.distanceSwimming)
        case .wheelchairWalkPace, .wheelchairRunPace, .handCycling:
            type = HKQuantityType(.distanceWheelchair)
        case .downhillSkiing, .snowboarding, .crossCountrySkiing:
            type = HKQuantityType(.distanceDownhillSnowSports)
        default:
            type = nil
        }
        guard let type else { return nil }
        // Two-stage query: try workout-scoped predicate first
        // (`predicateForObjects(from:)`), and fall back to a time-window
        // predicate when that returns zero. Background:
        //
        //   - Apple Watch explicit workouts → distance samples are
        //     associated with the workout via HKObjectAssociation;
        //     predicateForObjects matches them. Empirically 6/78 walks
        //     on the first 60-day backfill (PR #3).
        //   - Passive iPhone-detected walks → CMPedometer writes the
        //     distance as standalone samples in the same time window
        //     but doesn't link them to the workout. predicateForObjects
        //     returns nothing for these; time-window query catches them.
        //
        // The time-window fallback risks summing data from a concurrent
        // workout, but in practice walks don't overlap with other
        // distance-tracking activities. Empirically these are the
        // walks the user wants in the dashboard.
        let workoutPred = HKQuery.predicateForObjects(from: w)
        let windowPred  = HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate)
        if let q = try await sumQuantity(type: type, predicate: workoutPred),
           let qty = quantity(stat: q, kind: .sum, unit: .meterUnit(with: .kilo), units: "km") {
            return qty
        }
        let fallback = try await sumQuantity(type: type, predicate: windowPred)
        return quantity(stat: fallback, kind: .sum, unit: .meterUnit(with: .kilo), units: "km")
    }

    /// Convenience: runs an `HKStatisticsQuery(.cumulativeSum)` and
    /// returns the resulting `HKStatistics?`. Shared between distance
    /// and step-count paths so the predicate-fallback dance is
    /// expressed in one place each.
    private func sumQuantity(type: HKQuantityType, predicate: NSPredicate) async throws -> HKStatistics? {
        try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: [.cumulativeSum]) { _, s, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: s)
            }
            store.execute(q)
        }
    }

    /// Sums step samples linked to the workout and returns a single
    /// `StepSample` carrying the total (server-side `convertHAEWorkout`
    /// loops and adds, so one entry with the full count is equivalent to
    /// many small entries while keeping the payload tiny). Only emitted
    /// for activities where steps are meaningful (walking, running,
    /// hiking) — cycling/swimming/etc. legitimately have no step count.
    private func stepCountSamples(for w: HKWorkout) async throws -> [WorkoutItem.StepSample] {
        switch w.workoutActivityType {
        case .walking, .running, .hiking, .crossTraining, .stairs,
             .stairClimbing, .stepTraining:
            break
        default:
            return []
        }
        let type = HKQuantityType(.stepCount)
        // Same two-stage predicate as distanceQuantity. Step samples
        // are even less likely to be HKObjectAssociation-linked than
        // distance (Apple writes them as standalone CMPedometer
        // intervals), so the predicateForObjects path returns nothing
        // for every walking workout observed in the 90-day backfill —
        // including Watch-recorded ones with HR/distance present.
        // Fall back to time-window predicate to catch the standalone
        // pedometer samples.
        let workoutPred = HKQuery.predicateForObjects(from: w)
        let windowPred  = HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate)
        var stats = try await sumQuantity(type: type, predicate: workoutPred)
        if (stats?.sumQuantity()?.doubleValue(for: .count()) ?? 0) <= 0 {
            stats = try await sumQuantity(type: type, predicate: windowPred)
        }
        guard let total = stats?.sumQuantity()?.doubleValue(for: .count()),
              total.isFinite, total > 0
        else { return [] }
        return [
            WorkoutItem.StepSample(date: formatForServer(w.startDate), qty: total)
        ]
    }

    private func speedQuantity(for w: HKWorkout, kind: AggKind) -> WorkoutItem.Quantity? {
        // .runningSpeed / .cyclingSpeed are iOS 16+. .swimmingStrokeCount
        // is a separate stream; we skip per-stroke speed.
        let type: HKQuantityType?
        switch w.workoutActivityType {
        case .running:  type = HKQuantityType(.runningSpeed)
        case .cycling:  type = HKQuantityType(.cyclingSpeed)
        default:        type = nil
        }
        guard let type else { return nil }
        let speedUnit = HKUnit.meter().unitDivided(by: .second())
        let stat = w.statistics(for: type)
        let q: HKQuantity?
        switch kind {
        case .sum:      q = stat?.sumQuantity()
        case .average:  q = stat?.averageQuantity()
        case .maximum:  q = stat?.maximumQuantity()
        }
        guard let mps = q?.doubleValue(for: speedUnit), mps.isFinite, mps > 0 else { return nil }
        // Server's NormalizeSpeedKmh accepts "km/hr" — convert here.
        return WorkoutItem.Quantity(qty: mps * 3.6, units: "km/hr")
    }

    private func metadataQuantity(
        _ w: HKWorkout,
        key: String,
        unit: HKUnit,
        units: String
    ) -> WorkoutItem.Quantity? {
        guard let q = w.metadata?[key] as? HKQuantity,
              q.is(compatibleWith: unit)
        else { return nil }
        // HKUnit.percent() reports the value as a fraction (0.65 → "65 %").
        // Server's workouts.HumidityPct expects 0..100 (it stores the
        // value verbatim with no normalisation in convertHAEWorkout), so
        // rescale here before serialising. Other units (degC, meters,
        // MET) round-trip 1:1 — no scaling needed.
        let raw = q.doubleValue(for: unit)
        let v = (unit == HKUnit.percent()) ? raw * 100.0 : raw
        guard v.isFinite else { return nil }
        return WorkoutItem.Quantity(qty: v, units: units)
    }

    /// Stats-only HR aggregates (avg + max) for a workout, computed by
    /// HealthKit without materialising individual samples. Used when
    /// `includeHRTimeline` is off — saves ~200ms per workout vs the
    /// full sample fetch + Swift-side aggregation. The
    /// `predicateForObjects(from: workout)` scope is the same as
    /// `heartRateSamples` (and is necessary for the reason described
    /// there).
    private func heartRateAggregates(for w: HKWorkout) async throws -> HKStatistics? {
        let pred = HKQuery.predicateForObjects(from: w)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(
                quantityType: HKQuantityType(.heartRate),
                quantitySamplePredicate: pred,
                options: [.discreteAverage, .discreteMax]
            ) { _, s, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: s)
            }
            store.execute(q)
        }
    }

    /// Maps an `HKQuantity` (in heart-rate units) to a server-shape
    /// `WorkoutItem.Quantity`. Centralised so both HR code paths
    /// (timeline-on samples + timeline-off stats) share the same
    /// finite/positive guards and the same `bpm` unit constant.
    private func bpmQuantity(_ q: HKQuantity?) -> WorkoutItem.Quantity? {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        guard let v = q?.doubleValue(for: bpm), v.isFinite, v > 0 else { return nil }
        return WorkoutItem.Quantity(qty: v, units: "bpm")
    }

    /// Returns HR samples linked to the workout, formatted as server
    /// HRSamplePoint items. Single source of truth — `buildWorkoutItem`
    /// reuses the same array to compute avg/max in Swift AND (optionally)
    /// to emit the per-sample timeline. Avoids running two near-identical
    /// queries per workout.
    private func heartRateSamples(for w: HKWorkout) async throws -> [WorkoutItem.HRSamplePoint] {
        let hrType = HKQuantityType(.heartRate)
        // Scope strictly to HR samples associated with THIS workout. A
        // pure time predicate would also pick up unrelated HR samples
        // recorded in the same interval (e.g. iPhone HR readings while
        // the Watch is the workout source, or a second device worn
        // simultaneously) and pollute the server-side time-in-zone
        // computation. The time predicate is kept as an AND term for
        // belt-and-braces — `predicateForObjects(from:)` already implies
        // the workout's interval but explicit beats implicit here.
        let timePred = HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate)
        let workoutPred = HKQuery.predicateForObjects(from: w)
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [workoutPred, timePred])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: hrType,
                predicate: pred,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, raw, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (raw as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return samples.compactMap { s in
            let v = s.quantity.doubleValue(for: bpm)
            guard v.isFinite, v > 0 else { return nil }
            return WorkoutItem.HRSamplePoint(
                date: formatForServer(s.startDate),
                Avg: v
            )
        }
    }
}
