import Foundation

/// Presentation of server unit evidence. Values are never converted here.
struct MetricUnitMetadata {
    let metric: String
    let units: String
    let status: String?

    var displayUnit: String? {
        let trimmed = units.trimmingCharacters(in: .whitespacesAndNewlines)
        if let status {
            return status == "known" && !trimmed.isEmpty ? trimmed : nil
        }
        if !trimmed.isEmpty { return trimmed }
        // Legacy sleep endpoints have an established hours contract. Explicit
        // new metadata, including an unknown future status, always wins.
        return metric.hasPrefix("sleep_") ? String(localized: "hrs") : nil
    }

    var notice: String? {
        guard displayUnit == nil else { return nil }
        return status == "mixed" ? String(localized: "Units vary") : String(localized: "Unit not specified")
    }
}
