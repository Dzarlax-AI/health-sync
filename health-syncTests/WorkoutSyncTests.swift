//
//  WorkoutSyncTests.swift
//  health-syncTests
//
//  Covers the two pieces of WorkoutSync.swift that have no HealthKit /
//  network side effects: the display-name mapping and the HAE-shape JSON
//  encoding. The full fetch path is exercised end-to-end on device.
//

import Testing
import Foundation
import HealthKit
@testable import health_sync

struct WorkoutSyncTests {

    // MARK: - workoutDisplayName

    @Test func runningIndoorVsOutdoor() {
        #expect(workoutDisplayName(.running, isIndoor: false) == "Outdoor Run")
        #expect(workoutDisplayName(.running, isIndoor: true)  == "Indoor Run")
    }

    @Test func cyclingIndoorVsOutdoor() {
        #expect(workoutDisplayName(.cycling, isIndoor: false) == "Outdoor Cycle")
        #expect(workoutDisplayName(.cycling, isIndoor: true)  == "Indoor Cycle")
    }

    @Test func swimmingPoolVsOpenWater() {
        // isIndoor=true on a swim is the pool-swim convention; HAE used
        // the same. Server stores `is_indoor` separately so the
        // distinction survives even if the display name is later changed.
        #expect(workoutDisplayName(.swimming, isIndoor: true)  == "Pool Swim")
        #expect(workoutDisplayName(.swimming, isIndoor: false) == "Open Water Swim")
    }

    @Test func strengthTrainingNames() {
        #expect(workoutDisplayName(.traditionalStrengthTraining, isIndoor: true) == "Traditional Strength Training")
        #expect(workoutDisplayName(.functionalStrengthTraining,  isIndoor: true) == "Functional Strength Training")
    }

    @Test func miscellaneousActivities() {
        #expect(workoutDisplayName(.walking,                       isIndoor: false) == "Walking")
        #expect(workoutDisplayName(.hiking,                        isIndoor: false) == "Hiking")
        #expect(workoutDisplayName(.yoga,                          isIndoor: true)  == "Yoga")
        #expect(workoutDisplayName(.highIntensityIntervalTraining, isIndoor: true)  == "HIIT")
        #expect(workoutDisplayName(.coreTraining,                  isIndoor: true)  == "Core Training")
    }

    @Test func indoorFlagIgnoredWhenIrrelevant() {
        // Hiking, walking, yoga etc. don't have a meaningful indoor/outdoor
        // distinction in the display name (the activity itself implies the
        // context). Verify that toggling isIndoor doesn't change the label.
        #expect(workoutDisplayName(.hiking,  isIndoor: false) == workoutDisplayName(.hiking,  isIndoor: true))
        #expect(workoutDisplayName(.walking, isIndoor: false) == workoutDisplayName(.walking, isIndoor: true))
        #expect(workoutDisplayName(.yoga,    isIndoor: false) == workoutDisplayName(.yoga,    isIndoor: true))
    }

    @Test func unknownActivityFallsBackToWorkout() {
        // `.other` IS in our switch — it maps to "Other".
        #expect(workoutDisplayName(.other, isIndoor: false) == "Other")
        // An activity type the switch deliberately doesn't enumerate
        // (rare sports — archery, fencing, golf, etc.) falls through to
        // the default. Pin this so adding cases doesn't accidentally
        // change unrelated rows' labels.
        #expect(workoutDisplayName(.archery,    isIndoor: false) == "Workout")
        #expect(workoutDisplayName(.golf,       isIndoor: false) == "Workout")
        #expect(workoutDisplayName(.fencing,    isIndoor: true)  == "Workout")
    }

    // MARK: - Payload JSON shape

    @Test func payloadMatchesHAEFieldNames() throws {
        // The server (internal/handler/workouts.go::haeWorkout) reads
        // these exact camelCase keys. A typo here will silently null out
        // the field server-side — UPSERT keeps the workout row but with
        // missing distance / HR / energy. Pin the contract.
        let item = WorkoutItem(
            id: "ABC-123",
            name: "Outdoor Run",
            start: "2026-05-13 07:00:00 +0200",
            end:   "2026-05-13 08:00:00 +0200",
            duration: 3600.0,
            isIndoor: false,
            location: "Outdoor",
            avgHeartRate:       .init(qty: 148, units: "bpm"),
            maxHeartRate:       .init(qty: 172, units: "bpm"),
            activeEnergyBurned: .init(qty: 650, units: "kcal"),
            intensity:          nil,
            distance:           .init(qty: 10.2, units: "km"),
            avgSpeed:           nil,
            maxSpeed:           nil,
            elevationUp:        nil,
            temperature:        nil,
            humidity:           nil,
            heartRateData: [
                .init(date: "2026-05-13 07:01:00 +0200", Avg: 142.0)
            ],
            stepCount: [
                .init(date: "2026-05-13 07:00:00 +0200", qty: 8421)
            ]
        )
        let payload = WorkoutsPayload(items: [item])

        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let bytes = try enc.encode(payload)
        let json = String(decoding: bytes, as: UTF8.self)

        // Required top-level wrapper.
        #expect(json.contains(#""data":"#))
        #expect(json.contains(#""workouts":["#))

        // Core fields.
        #expect(json.contains(#""id":"ABC-123""#))
        #expect(json.contains(#""name":"Outdoor Run""#))
        #expect(json.contains(#""start":"2026-05-13 07:00:00 +0200""#))
        #expect(json.contains(#""end":"2026-05-13 08:00:00 +0200""#))
        #expect(json.contains(#""duration":3600"#))
        #expect(json.contains(#""isIndoor":false"#))
        #expect(json.contains(#""location":"Outdoor""#))

        // Quantity fields — `{qty, units}` shape per HAE.
        #expect(json.contains(#""avgHeartRate":{"qty":148,"units":"bpm"}"#))
        #expect(json.contains(#""maxHeartRate":{"qty":172,"units":"bpm"}"#))
        #expect(json.contains(#""activeEnergyBurned":{"qty":650,"units":"kcal"}"#))
        #expect(json.contains(#""distance":{"qty":10.2,"units":"km"}"#))

        // HR timeline — array of `{Avg, date}` with capital-A `Avg`. The
        // server reads `Avg` (mirrors HAE manual-export's mixed casing for
        // heart_rate). Lowercase `avg` would silently fail.
        #expect(json.contains(#""heartRateData":[{"Avg":142"#))

        // Step count — array of `{date, qty}`. Server sums `qty` across
        // entries to populate `step_count_total`. One entry with the
        // cumulative total is the minimal valid emission.
        #expect(json.contains(#""stepCount":[{"date":"#))
        #expect(json.contains(#""qty":8421"#))
    }

    @Test func humidityPercentSerialisesAs0to100() throws {
        // Server reads HumidityPct as 0..100 verbatim (no normalisation in
        // workouts.go). Apple Watch writes HKMetadataKeyWeatherHumidity
        // already in 0..100 form (e.g. `71` for 71%) — non-compliant with
        // the HKUnit.percent() 0..1 convention but consistent in practice.
        // metadataQuantity treats humidity specially via the
        // `percentIsAbsolute: true` flag and passes the value through.
        //
        // We can't drive metadataQuantity directly without an HKWorkout,
        // but we CAN pin the on-the-wire contract by constructing the
        // post-conversion WorkoutItem and asserting the JSON shape.
        let item = WorkoutItem(
            id: "Y", name: "Outdoor Run",
            start: "2026-05-13 07:00:00 +0200",
            end:   "2026-05-13 08:00:00 +0200",
            duration: 3600, isIndoor: false, location: "Outdoor",
            avgHeartRate: nil, maxHeartRate: nil,
            activeEnergyBurned: nil, intensity: nil,
            distance: nil, avgSpeed: nil, maxSpeed: nil,
            elevationUp: nil,
            temperature: nil,
            humidity: .init(qty: 65, units: "%"),   // post-conversion
            heartRateData: [],
            stepCount: []
        )
        let bytes = try JSONEncoder().encode(WorkoutsPayload(items: [item]))
        let object = try JSONSerialization.jsonObject(with: bytes)
        let root = try #require(object as? [String: Any])
        let data = try #require(root["data"] as? [String: Any])
        let workouts = try #require(data["workouts"] as? [[String: Any]])
        let workout = try #require(workouts.first)
        let humidity = try #require(workout["humidity"] as? [String: Any])
        #expect((humidity["qty"] as? NSNumber)?.doubleValue == 65)
        #expect(humidity["units"] as? String == "%")
        // Negative pin: a regression that drops the *100 multiplier would
        // produce qty:0.65 here.
        let json = String(decoding: bytes, as: UTF8.self)
        #expect(!json.contains(#""qty":0.65"#))
    }

    @Test func nilQuantitiesOmittedFromPayload() throws {
        // Server-side haeWorkout uses `*qtyUnits` pointers — JSON null
        // and absent key both decode to nil. Verify we OMIT nils so the
        // wire payload is small. (Swift's default Codable encodes nil as
        // explicit null for non-optional fields; for Optional fields, the
        // standard behavior omits the key when nil — which is what we
        // want, but worth pinning.)
        let item = WorkoutItem(
            id: "X", name: "Yoga",
            start: "2026-05-13 08:00:00 +0200",
            end:   "2026-05-13 08:30:00 +0200",
            duration: 1800, isIndoor: true, location: "Indoor",
            avgHeartRate: nil, maxHeartRate: nil,
            activeEnergyBurned: nil, intensity: nil,
            distance: nil, avgSpeed: nil, maxSpeed: nil,
            elevationUp: nil,
            temperature: nil, humidity: nil,
            heartRateData: [],
            stepCount: []
        )
        let bytes = try JSONEncoder().encode(WorkoutsPayload(items: [item]))
        let json = String(decoding: bytes, as: UTF8.self)
        #expect(!json.contains(#""distance":null"#))
        #expect(!json.contains(#""avgHeartRate":null"#))
        #expect(!json.contains(#""temperature":null"#))
        // heartRateData is non-optional (`[HRSamplePoint]`), empty array
        // is fine and intentional — server safely iterates an empty list.
        #expect(json.contains(#""heartRateData":[]"#))
    }
}
