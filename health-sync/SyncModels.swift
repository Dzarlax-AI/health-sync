import Foundation

// MARK: - Category event definition (no HealthKit types — avoids @MainActor inference)

struct CategoryEventDef: Sendable {
    enum ValueKind: Sendable, Equatable {
        case durationMinutes
        case count
    }
    let identifierRaw: String
    let name: String
    let kind: ValueKind
}

// MARK: - Sleep phase accumulator
// Raw values of HKCategoryValueSleepAnalysis (no HealthKit import needed):
//   0=inBed  1=asleep(legacy)  2=awake  3=asleepUnspecified  4=asleepCore  5=asleepDeep  6=asleepREM

struct SleepPhases: Sendable {
    var deep:  Double = 0
    var rem:   Double = 0
    var core:  Double = 0
    var awake: Double = 0
    var total: Double = 0

    mutating func apply(value: Int, hours: Double) {
        switch value {
        case 5:        deep  += hours; total += hours
        case 6:        rem   += hours; total += hours
        case 1, 3, 4:  core  += hours; total += hours
        case 2:        awake += hours
        default:       break
        }
    }
}
