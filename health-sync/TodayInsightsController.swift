import Foundation

/// Owns the optional, server-authored Today snapshot separately from the
/// legacy briefing and narrative endpoints. A failed optional refresh never
/// discards the last factual snapshot or blocks the core dashboard.
@MainActor
@Observable
final class TodayInsightsController {
    private(set) var response: TodayInsightsResponse?
    private var pollTask: Task<Void, Never>?

    func apply(_ response: TodayInsightsResponse) {
        self.response = response
    }

    func reset() {
        cancelPolling()
        response = nil
    }

    func schedulePollingIfNeeded() {
        cancelPolling()
        guard let response, Self.shouldPoll(response) else { return }

        pollTask = Task { @MainActor in
            var current = response
            for _ in 0..<10 {
                let retryAfter = max(30, current.generation.retryAfterSeconds ?? 30)
                try? await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000_000)
                if Task.isCancelled { return }
                guard let updated = try? await ServerClient.shared.todayInsights() else { continue }
                apply(updated)
                if !Self.shouldPoll(updated) { return }
                current = updated
            }
        }
    }

    func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    static func shouldPoll(_ response: TodayInsightsResponse) -> Bool {
        let state = response.generation.state.lowercased()
        return state == "cold" || state == "generating" || !response.generation.freshForSnapshot
    }
}
