@preconcurrency import HealthKit
import Foundation

extension HealthKitManager {
    func authorizeSleepChangesOnly() async throws {
        guard HKHealthStore.isHealthDataAvailable(),
              let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw SleepChangeFailure.unavailable
        }
        try await store.requestAuthorization(toShare: [], read: [sleep])
    }

    func sleepChangePage(start: Date, end: Date? = nil, savedAnchor: Data?) async throws -> SleepChangePage {
        try Task.checkCancellation()
        guard HKHealthStore.isHealthDataAvailable(),
              let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw SleepChangeFailure.unavailable
        }
        let anchor: HKQueryAnchor?
        if let savedAnchor {
            guard savedAnchor.count <= 16_384 else { throw SleepChangeFailure.invalidAnchor }
            do {
                anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: savedAnchor)
                guard anchor != nil else { throw SleepChangeFailure.invalidAnchor }
            } catch {
                throw SleepChangeFailure.invalidAnchor
            }
        } else {
            anchor = nil
        }

        // Keep the predicate and its start fixed for this anchor's lifetime.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKAnchoredObjectQueryDescriptor(
            predicates: [HKSamplePredicate.categorySample(type: sleep, predicate: predicate)],
            anchor: anchor, limit: 128
        )
        let result: HKAnchoredObjectQueryDescriptor<HKCategorySample>.Result
        do {
            result = try await query.result(for: store)
        } catch {
            let failure = error as NSError
            if savedAnchor != nil, failure.domain == HKErrorDomain,
               failure.code == HKError.Code.errorInvalidArgument.rawValue {
                throw SleepChangeFailure.invalidAnchor
            }
            throw error
        }
        try Task.checkCancellation()
        let additions = result.addedSamples.map { sample in
            SleepChangePage.Addition(id: sample.uuid.uuidString.lowercased(), start: sample.startDate,
                                      end: sample.endDate,
                                      deviceBound: !(sample.device?.localIdentifier ?? "").isEmpty)
        }
        return SleepChangePage(
            anchor: try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true),
            additions: additions, deletedIDs: result.deletedObjects.map { $0.uuid.uuidString.lowercased() }
        )
    }
}
