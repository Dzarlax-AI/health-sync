import Foundation
import SwiftData
import Testing
@testable import health_sync

@MainActor
struct SyncHistoryStoreTests {
    @Test func migratesLegacyHistoryOnceAndSortsNewestFirst() throws {
        let defaults = try makeDefaults()
        let older = SyncEntry(date: Date(timeIntervalSince1970: 100), points: 1, success: true, error: nil)
        let newer = SyncEntry(date: Date(timeIntervalSince1970: 200), points: 2, success: false, error: "failed")
        defaults.set(try JSONEncoder().encode([older, newer]), forKey: "health-sync.history")

        let store = try makeStore(defaults: defaults)
        let migrated = store.loadHistory()

        #expect(migrated.map(\.id) == [newer.id, older.id])
        #expect(migrated.first?.error == "failed")

        let loadedAgain = store.loadHistory()
        #expect(loadedAgain.map(\.id) == [newer.id, older.id])
    }

    @Test func appendTrimsToMostRecentFiftyEntries() throws {
        let defaults = try makeDefaults()
        let store = try makeStore(defaults: defaults)

        for offset in 0..<60 {
            _ = store.append(SyncEntry(
                date: Date(timeIntervalSince1970: TimeInterval(offset)),
                points: offset,
                success: true,
                error: nil
            ))
        }

        let history = store.loadHistory()
        #expect(history.count == 50)
        #expect(history.first?.points == 59)
        #expect(history.last?.points == 10)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "health-sync-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) throws -> SyncHistoryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SyncHistoryRecord.self, configurations: config)
        return SyncHistoryStore(defaults: defaults, container: container)
    }
}
