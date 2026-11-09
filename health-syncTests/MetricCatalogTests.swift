import Foundation
import Testing
@testable import health_sync

@MainActor
struct MetricCatalogTests {
    @Test func metadataRemainsCompatibleWithBothLegacyShapes() throws {
        for payload in [
            #"{"name":"heart_rate","display_name":"Heart rate","units":"bpm","count":2,"min":"2026-01-01","max":"2026-01-02"}"#,
            #"{"Name":"heart_rate","Units":"bpm","Count":2,"Min":"2026-01-01","Max":"2026-01-02"}"#,
        ] {
            let metric = try JSONDecoder().decode(MetricSummary.self, from: Data(payload.utf8))
            #expect(metric.unitStatus == nil)
            #expect(metric.unitMetadata.displayUnit == "bpm")
            #expect(metric.variantDescription(hasNameCollision: false) == nil)
            #expect(metric.variantDescription(hasNameCollision: true)?.contains("heart_rate") == true)
        }
    }

    @Test(arguments: ["unknown", "mixed", "future-status"])
    func explicitUntrustedStatusNeverDisplaysAnUnverifiedUnit(status: String) throws {
        let data = Data(#"{"name":"sleep_total","units":"incorrect","count":1,"min":"","max":"","unit_status":"\#(status)"}"#.utf8)
        let metric = try JSONDecoder().decode(MetricSummary.self, from: data)
        #expect(metric.unitMetadata.displayUnit == nil)
        #expect(metric.unitMetadata.notice != nil)
    }

    @Test func malformedMetadataDoesNotSilentlyTrustLegacyUnits() throws {
        for invalid in ["null", "123", "{}"] {
            let data = Data(#"{"name":"active_energy","units":"kcal","count":1,"min":"","max":"","unit_status":\#(invalid)}"#.utf8)
            let metric = try JSONDecoder().decode(MetricSummary.self, from: data)
            #expect(metric.unitMetadata.displayUnit == nil)
        }
    }

    @Test func serverVariantLabelIsPreservedAndSeriesRemainSeparate() throws {
        let json = #"[{"name":"walk_a","display_name":"Walk","units":"m","count":2,"min":"","max":"","unit_status":"known","variant_label":"Server variant A"},{"name":"walk_b","display_name":"Walk","units":"m","count":3,"min":"","max":"","unit_status":"known","variant_label":"Server variant B"}]"#
        let rows = try JSONDecoder().decode([MetricSummary].self, from: Data(json.utf8))
        #expect(rows.map(\.id) == ["walk_a", "walk_b"])
        #expect(rows.map { $0.variantDescription(hasNameCollision: true) } == ["Server variant A", "Server variant B"])
        #expect(rows.map(\.count) == [2, 3])
        #expect(rows.allSatisfy { $0.unitMetadata.displayUnit == "m" })
    }

    @Test func unitPresentationPreservesOnlyEstablishedLegacySleepFallback() {
        #expect(MetricUnitMetadata(metric: "sleep_total", units: "", status: nil).displayUnit != nil)
        #expect(MetricUnitMetadata(metric: "active_energy", units: "", status: nil).displayUnit == nil)
        #expect(MetricUnitMetadata(metric: "sleep_total", units: "", status: "unknown").displayUnit == nil)
        #expect(MetricUnitMetadata(metric: "active_energy", units: "  kcal  ", status: "known").displayUnit == "kcal")
        #expect(MetricUnitMetadata(metric: "active_energy", units: " ", status: "known").displayUnit == nil)
    }

    @Test func fixtureRespectsBothRequestedRangeBounds() {
        let range = MetricCatalogFixtures.metricRange()
        let response = MetricCatalogFixtures.data(name: "active_energy", from: range.max, to: range.max)
        #expect(response.points?.map(\.date) == [range.max])
        let empty = MetricCatalogFixtures.data(name: "active_energy", from: "1900-01-01", to: "1900-01-02")
        #expect(empty.points?.isEmpty == true)
    }
}
