import Foundation

nonisolated struct BackgroundRetryIntent: Codable, Equatable, Sendable {
    var id = UUID()
    var fullResync: DateInterval?

    static func daily(now: Date, calendar: Calendar = .current, daysBack: Int) -> Self {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(1, daysBack) - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return Self(fullResync: DateInterval(start: start, end: end))
    }
}

/// Persists only retry intent and dates, never credentials or health payloads.
@MainActor
final class BackgroundUnlockRetry {
    private let defaults: UserDefaults
    private let key = "health-sync.background-unlock-intent.v1"
    private let legacyKey = "health-sync.background-unlock-pending"
    private(set) var pending: BackgroundRetryIntent?
    private var recovering = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pending = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BackgroundRetryIntent.self, from: $0) }
        if pending == nil, defaults.bool(forKey: legacyKey) {
            pending = BackgroundRetryIntent()
            persist()
        }
    }

    func beginRecovery(enabled: Bool, protectedDataAvailable: Bool) -> BackgroundRetryIntent? {
        guard enabled, protectedDataAvailable, !recovering, let pending else { return nil }
        recovering = true
        return pending
    }

    func finishRecovery() { recovering = false }

    func record(_ outcome: SyncOutcome, intent: BackgroundRetryIntent) {
        if outcome == .disabled {
            pending = nil
        } else if outcome.needsUnlockRetry {
            if let existing = pending, existing.id != intent.id {
                var merged = intent
                if let previous = existing.fullResync {
                    let next = intent.fullResync ?? previous
                    merged.fullResync = DateInterval(start: min(previous.start, next.start), end: max(previous.end, next.end))
                }
                pending = merged
            } else {
                pending = intent
            }
        } else if outcome.wasAccepted, pending?.id == intent.id {
            // An unrelated successful upload must not erase a full-day retry.
            pending = nil
        }
        persist()
    }

    private func persist() {
        if let pending, let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: legacyKey)
    }
}

/// HealthKit may call on an arbitrary queue. Transfer its callback once under
/// a lock; invoke outside the lock to allow reentrancy without deadlocking.
nonisolated final class HealthObserverCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) { self.action = action }

    func finish() {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}
