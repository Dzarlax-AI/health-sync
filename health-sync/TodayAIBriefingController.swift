import Foundation

@MainActor
@Observable
final class TodayAIBriefingController {
    /// Latest AI briefing payload. We store the whole response so the renderer
    /// can choose between chunked fields and the legacy combined insight text.
    private(set) var response: AIBriefingResponse?
    private(set) var generating = false
    private(set) var disabled = false

    private var pollTask: Task<Void, Never>?

    /// Update local AI state from a server response. We only overwrite
    /// `response` when the new payload carries non-empty content so a polling
    /// tick that races a cold cache flush cannot replace populated UI with an
    /// empty render.
    func apply(_ response: AIBriefingResponse) {
        disabled = response.disabled
        generating = response.generating
        if disabled {
            self.response = nil
            return
        }
        if Self.hasContent(response) {
            self.response = response
        }
    }

    func reset() {
        cancelPolling()
        response = nil
        generating = false
        disabled = false
    }

    func isPlanFresh(for decisionID: String?) -> Bool {
        guard let decisionID,
              let response,
              response.decisionId == decisionID,
              response.freshForDecision == true,
              let plan = response.plan,
              Self.planHasContent(plan) else { return false }
        return true
    }

    /// Poll /api/ai-briefing while the server reports a regen in flight and
    /// the cache is still empty. Stops on first non-empty insight or after
    /// five minutes the cadence slows to once every five minutes.
    func schedulePollingIfNeeded(for decisionID: String? = nil) {
        cancelPolling()
        let alreadyHaveContent = response.map(Self.hasContent) ?? false
        let planIsFresh = isPlanFresh(for: decisionID)
        guard !disabled, !planIsFresh, (generating || !alreadyHaveContent || decisionID != nil) else { return }
        pollTask = Task { @MainActor in
            var attempts = 0
            while !Task.isCancelled {
                let delay: UInt64 = attempts < 10 ? 30 : 300
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                attempts += 1
                if Task.isCancelled { return }
                guard let response = try? await ServerClient.shared.aiBriefing() else { continue }
                guard !Task.isCancelled else { return }
                apply(response)
                let haveContent = self.response.map(Self.hasContent) ?? false
                if disabled || self.isPlanFresh(for: decisionID) || (decisionID == nil && haveContent && response.previous == nil && !response.generating) { return }
            }
        }
    }

    func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    static func hasContent(_ response: AIBriefingResponse) -> Bool {
        !(response.previous?.text ?? "").isEmpty
            || planHasContent(response.plan)
            || !response.insight.isEmpty
            || !(response.sleep ?? "").isEmpty
            || !(response.yesterday ?? "").isEmpty
            || !(response.recovery ?? "").isEmpty
            || !(response.recommendation ?? "").isEmpty
    }

    static func planHasContent(_ plan: AIBriefingPlan?) -> Bool {
        guard let plan else { return false }
        return !(plan.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(plan.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
