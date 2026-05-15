//
//  SleepPhaseNameTests.swift
//  health-syncTests
//
//  Covers HealthKitManager.sleepPhaseName(for:), the pure classifier that
//  maps an HKCategoryValueSleepAnalysis raw value to the per-segment metric
//  name shipped to the server. The function MUST stay in lockstep with the
//  inner switch in fetchSleep — if one is edited, the other should be too.
//
//  Tests use raw Int values directly (not HKCategoryValueSleepAnalysis.X)
//  so the test target does NOT need HealthKit.framework linked. The raw
//  values are stable Apple API:
//  https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis
//
//      inBed              = 0
//      asleepUnspecified  = 1  (a.k.a. legacy `.asleep`)
//      awake              = 2
//      asleepCore         = 3
//      asleepDeep         = 4
//      asleepREM          = 5
//

import Testing
@testable import health_sync

struct SleepPhaseNameTests {

    @Test func deepMapsToSleepDeep() {
        #expect(HealthKitManager.sleepPhaseName(for: 4) == "sleep_deep")
    }

    @Test func remMapsToSleepRem() {
        #expect(HealthKitManager.sleepPhaseName(for: 5) == "sleep_rem")
    }

    @Test func coreMapsToSleepCore() {
        #expect(HealthKitManager.sleepPhaseName(for: 3) == "sleep_core")
    }

    @Test func unspecifiedMapsToSleepUnspecified() {
        // Coarse "just asleep" marker from sources without stage tracking
        // (RingConn, iPhone Sleep Schedule, older Apple Watch). Pre-v2.3
        // this was folded into sleep_core; the v2.3 rollout (server PR #73)
        // gives it its own metric so sleep_core only carries real Core
        // Sleep stage time. The aggregate path drops the coarse marker
        // entirely when stage markers exist in the same session (overlap
        // dedup, PR #10) and routes its hours into `total` only — never
        // a phase field. This test pins the per-segment mapping.
        //
        // Note: `.asleep` (deprecated pre-iOS-16 case) is an alias for the
        // same raw value 1, so this test covers both.
        #expect(HealthKitManager.sleepPhaseName(for: 1) == "sleep_unspecified")
    }

    @Test func awakeMapsToSleepAwake() {
        #expect(HealthKitManager.sleepPhaseName(for: 2) == "sleep_awake")
    }

    @Test func inBedReturnsNil() {
        // `.inBed` (raw=0) is duration-in-bed, not sleep stage. Dropped
        // from per-segment emission to mirror the aggregate switch's `break`.
        #expect(HealthKitManager.sleepPhaseName(for: 0) == nil)
    }

    @Test func unknownRawValueReturnsNil() {
        // 99 is not a real HKCategoryValueSleepAnalysis value. Function
        // must not crash and must not classify it. Guards against future
        // Apple additions silently entering the wrong bucket.
        #expect(HealthKitManager.sleepPhaseName(for: 99) == nil)
    }

    @Test func negativeRawValueReturnsNil() {
        #expect(HealthKitManager.sleepPhaseName(for: -1) == nil)
    }
}
