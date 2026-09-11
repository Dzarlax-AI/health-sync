import Foundation
import SwiftData

struct SyncEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    let date: Date
    let points: Int
    let success: Bool
    let error: String?
}

@Model
final class SyncHistoryRecord {
    @Attribute(.unique) var id: UUID
    var date: Date
    var points: Int
    var success: Bool
    var error: String?

    init(id: UUID = UUID(), date: Date, points: Int, success: Bool, error: String?) {
        self.id = id
        self.date = date
        self.points = points
        self.success = success
        self.error = error
    }

    convenience init(entry: SyncEntry) {
        self.init(
            id: entry.id,
            date: entry.date,
            points: entry.points,
            success: entry.success,
            error: entry.error
        )
    }

    var entry: SyncEntry {
        SyncEntry(id: id, date: date, points: points, success: success, error: error)
    }
}

@MainActor
final class SyncHistoryStore {
    private let legacyHistoryKey = "health-sync.history"
    private let migrationKey = "health-sync.history-migrated-to-swiftdata.v1"
    private let limit = 50

    private let defaults: UserDefaults
    private let context: ModelContext?

    init(defaults: UserDefaults = .standard, container: ModelContainer? = nil) {
        self.defaults = defaults
        if let container {
            self.context = ModelContext(container)
        } else if let container = try? ModelContainer(for: SyncHistoryRecord.self) {
            self.context = ModelContext(container)
        } else {
            self.context = nil
        }
    }

    func loadHistory() -> [SyncEntry] {
        guard let context else {
            return loadLegacyHistory()
        }
        migrateLegacyHistoryIfNeeded(context: context)
        return fetchEntries(context: context, limit: limit)
    }

    func append(_ entry: SyncEntry) -> [SyncEntry] {
        guard let context else {
            return appendLegacy(entry)
        }
        migrateLegacyHistoryIfNeeded(context: context)
        context.insert(SyncHistoryRecord(entry: entry))
        save(context)
        trim(context)
        return fetchEntries(context: context, limit: limit)
    }

    private func migrateLegacyHistoryIfNeeded(context: ModelContext) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        let legacy = loadLegacyHistory()
        for entry in legacy {
            context.insert(SyncHistoryRecord(entry: entry))
        }
        save(context)
        trim(context)
        defaults.set(true, forKey: migrationKey)
        defaults.synchronize()
    }

    private func fetchEntries(context: ModelContext, limit: Int? = nil) -> [SyncEntry] {
        var descriptor = FetchDescriptor<SyncHistoryRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        if let limit {
            descriptor.fetchLimit = limit
        }
        guard let records = try? context.fetch(descriptor) else { return [] }
        return records.map(\.entry)
    }

    private func trim(_ context: ModelContext) {
        let entries = fetchRecords(context: context)
        guard entries.count > limit else { return }
        for record in entries.dropFirst(limit) {
            context.delete(record)
        }
        save(context)
    }

    private func fetchRecords(context: ModelContext) -> [SyncHistoryRecord] {
        let descriptor = FetchDescriptor<SyncHistoryRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            assertionFailure("Failed to save sync history: \(error.localizedDescription)")
        }
    }

    private func loadLegacyHistory() -> [SyncEntry] {
        guard let data = defaults.data(forKey: legacyHistoryKey),
              let saved = try? JSONDecoder().decode([SyncEntry].self, from: data)
        else { return [] }
        return Array(saved.sorted { $0.date > $1.date }.prefix(limit))
    }

    private func appendLegacy(_ entry: SyncEntry) -> [SyncEntry] {
        var history = loadLegacyHistory()
        history.insert(entry, at: 0)
        history = Array(history.sorted { $0.date > $1.date }.prefix(limit))
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: legacyHistoryKey)
            defaults.synchronize()
        }
        return history
    }
}
