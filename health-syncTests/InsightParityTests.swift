import Foundation
import Testing
@testable import health_sync

@MainActor
struct InsightParityTests {
    @Test func freshSlotsRenderIndependently() throws {
        let value = try InsightFixtures.snapshot(staleSlot: "recovery")
        #expect(value.aiInsight?.stance == "qualify")
        #expect(value.aiInsight?.factIDs == ["synthetic"])
        #expect(value.generation.narrativeMode == "preview")
        #expect(value.visibleAI(for: "overall") != nil)
        #expect(value.visibleAI(for: "sleep") != nil)
        #expect(value.visibleAI(for: "recovery") == nil)
        #expect(value.visibleAI(for: "energy")?.alternativeAction != nil)
    }

    @Test func failedOrDisabledOpinionsNeverReplaceServerFacts() throws {
        for state in ["cold", "generating", "failed", "disabled", "future-state"] {
            let value = try InsightFixtures.snapshot(state: state)
            #expect(value.visibleAI(for: "overall") == nil)
            #expect(!value.primary.observation.isEmpty)
            #expect(value.domains.count == 3)
        }
        #expect(try InsightFixtures.snapshot(mode: "disabled").visibleAI(for: "sleep") == nil)
    }

    @Test func routesUseDomainInsteadOfLegacyEnergyDestination() throws {
        let value = try InsightFixtures.snapshot()
        #expect(InsightDestination.resolve(domain: value.domain("sleep")!) == .sleep)
        #expect(value.domain("sleep")?.destination.kind == "sleep")
        #expect(value.domain("energy")?.destination.id == "activity")
        #expect(InsightDestination.resolve(domain: value.domain("energy")!) == .energy)
        #expect(InsightDestination.resolve(domain: value.domain("recovery")!) == .section("recovery"))
    }

    @Test func energyHistoryPreservesNegativeValuesAndRejectsHourlyContract() throws {
        #expect(try InsightFixtures.energyHistory().points.first { $0.date == "2026-09-24" }?.currentEOD == -12)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EnergyHistoryResponse.self, from: Data(#"{"granularity":"hour","points":[]}"#.utf8))
        }
        #expect(try JSONDecoder().decode(EnergyHistoryResponse.self, from: Data(#"{"granularity":"day","points":null}"#.utf8)).points.isEmpty)
    }

    @Test func pollingHonorsProviderBackoffAndBudget() throws {
        let value = try response(state: "failed", retry: 900)
        #expect(TodayInsightsController.pollDelay(value, attempts: 0) == 900)
        #expect(TodayInsightsController.pollDelay(value, attempts: 10) == nil)
        #expect(TodayInsightsController.pollDelay(try response(state: "disabled"), attempts: 100) == 60)
        #expect(TodayInsightsController.pollDelay(try response(state: "ready"), attempts: 0) == nil)
        #expect(TodayInsightsController.pollDelay(try response(state: "unknown", fresh: false), attempts: 0) == 60)
        #expect(TodayInsightsController.pollDelay(try InsightFixtures.snapshot(staleSlot: "sleep"), attempts: 0) == 60)
    }

    @Test func resetRejectsUncooperativeLateResponse() async throws {
        let gate = SnapshotGate()
        let controller = TodayInsightsController(loader: { await gate.load() }, context: { "account" }, prepare: {})
        let task = Task { await controller.refresh() }
        await gate.waitForRequest()
        controller.reset()
        gate.finish(try InsightFixtures.snapshot())
        await task.value
        #expect(controller.response == nil)
    }

    @Test func changedAccountLocaleOrDayRejectsLateResponse() async throws {
        for change in ["other-account", "other-locale", "next-day"] {
            let gate = SnapshotGate()
            let state = InsightTestState()
            state.identity = "original"
            let controller = TodayInsightsController(loader: { await gate.load() }, context: { state.identity }, prepare: {})
            let task = Task { await controller.refresh() }
            await gate.waitForRequest()
            state.identity = change
            gate.finish(try InsightFixtures.snapshot())
            await task.value
            #expect(controller.response == nil)
        }
    }

    @Test func cancellationRejectsLateResponse() async throws {
        let gate = SnapshotGate()
        let controller = TodayInsightsController(loader: { await gate.load() }, context: { "account" }, prepare: {})
        let task = Task { await controller.refresh() }
        await gate.waitForRequest()
        task.cancel()
        gate.finish(try InsightFixtures.snapshot())
        await task.value
        #expect(controller.response == nil)
    }

    @Test func transientErrorKeepsMarkedFactsButUnauthorizedClearsThem() async throws {
        let state = InsightTestState()
        let controller = TodayInsightsController(loader: {
            if let failure = state.failure { throw failure }
            return try InsightFixtures.snapshot()
        }, context: { "account" }, prepare: {})
        await controller.refresh()
        state.failure = URLError(.notConnectedToInternet)
        await controller.refresh()
        #expect(controller.response != nil)
        #expect(controller.isStale)
        state.failure = ServerError.http(401, nil)
        await controller.refresh()
        #expect(controller.response == nil)
        #expect(controller.unavailable)
    }

    @Test func changedContextClearsPreviousFactsEvenWhenRefreshFails() async throws {
        let state = InsightTestState()
        let controller = TodayInsightsController(loader: {
            if state.fail { throw URLError(.notConnectedToInternet) }
            return try InsightFixtures.snapshot()
        }, context: { state.identity }, prepare: {})
        await controller.refresh()
        state.identity = "new"
        state.fail = true
        await controller.refresh()
        #expect(controller.response == nil)
    }

    @Test func disabledPollsDoNotSpendGenerationBudget() async throws {
        var requests = 0
        var waits = 0
        let controller = TodayInsightsController(loader: {
            requests += 1
            return try response(state: requests <= 12 ? "disabled" : "generating")
        }, context: { "account" }, prepare: {}, sleep: { seconds in
            #expect(seconds == 60)
            waits += 1
            if waits > 25 { throw CancellationError() }
        })
        await controller.run()
        // 12 disabled responses, discovery of generation, then 10 budgeted retries.
        #expect(requests == 23)
    }

    @Test func missingSnapshotFailuresHaveBoundedRetries() async throws {
        var requests = 0
        var waits = 0
        let controller = TodayInsightsController(loader: {
            requests += 1
            throw URLError(.timedOut)
        }, context: { "account" }, prepare: {}, sleep: { _ in
            waits += 1
            if waits > 15 { throw CancellationError() }
        })
        await controller.run()
        #expect(requests == 11)
    }

    @Test func energyHistoryFailureDoesNotDiscardCurrentEnergy() async throws {
        let controller = EnergyDataController(loadBriefing: { try InsightFixtures.briefing() },
            loadHistory: { throw URLError(.timedOut) }, context: { "fixture" })
        await controller.refresh()
        #expect(controller.briefing?.energyBank?.current == 58)
        #expect(controller.historyFailed)
    }

    @Test func slowEnergyHistoryDoesNotBlockCurrentEnergy() async throws {
        var continuation: CheckedContinuation<EnergyHistoryResponse, Never>?
        let controller = EnergyDataController(loadBriefing: { try InsightFixtures.briefing() },
            loadHistory: { await withCheckedContinuation { continuation = $0 } }, context: { "fixture" })
        let task = Task { await controller.refresh() }
        while continuation == nil || controller.briefing == nil { await Task.yield() }
        #expect(controller.briefing?.energyBank != nil)
        #expect(controller.history == nil)
        continuation?.resume(returning: try InsightFixtures.energyHistory())
        await task.value
        #expect(controller.history?.points.count == 14)
    }

    @Test func pendingSlotUsesBudgetEvenIfAggregateIsReady() async throws {
        var requests = 0
        var waits = 0
        let controller = TodayInsightsController(loader: {
            requests += 1
            return try InsightFixtures.snapshot(staleSlot: "recovery")
        }, context: { "account" }, prepare: {}, sleep: { _ in
            waits += 1
            if waits > 15 { throw CancellationError() }
        })
        await controller.run()
        #expect(requests == 11)
    }

    @Test func missingConfigurationShowsEnergyErrorsInsteadOfEndlessLoading() async {
        let controller = EnergyDataController(loadBriefing: { throw ServerError.missingConfig },
            loadHistory: { throw ServerError.missingConfig }, context: { throw ServerError.missingConfig })
        await controller.refresh()
        #expect(controller.briefingFailed)
        #expect(controller.historyFailed)
    }

    @Test func malformedOptionalAIPreservesFactsAndFailsClosed() throws {
        let fact: [String: Any] = ["state": "context", "title": "Facts", "observation": "Available",
                                  "meaning": "", "evidence_ids": [], "fallback": false]
        for badAI: Any in [["stance": "qualify"], ["text": "Unvalidated"], "invalid"] {
            let payload: [String: Any] = ["date": "2026-09-26", "decision_id": "test", "snapshot_version": "test",
                "generation": ["state": "ready", "fresh_for_snapshot": true], "primary": fact, "ai_insight": badAI,
                "domains": [["key": "sleep", "band": "fair", "data_state": "partial", "summary": "Sleep",
                             "insight": fact, "ai_insight": badAI, "destination": ["kind": "sleep", "id": "sleep"]]]]
            let value = try JSONDecoder().decode(TodayInsightsResponse.self, from: JSONSerialization.data(withJSONObject: payload))
            #expect(value.primary.observation == "Available")
            #expect(value.domain("sleep")?.insight.observation == "Available")
            #expect(value.visibleAI(for: "overall") == nil)
            #expect(value.visibleAI(for: "sleep") == nil)
        }
    }

    @Test func malformedSlotsDoNotAuthorizeAIThroughAggregateFallback() throws {
        let fact: [String: Any] = ["state": "context", "title": "Facts", "observation": "Available",
                                  "meaning": "", "evidence_ids": [], "fallback": false]
        for slots: Any in [[["key": "overall", "state": "ready"]], "invalid", [["state": "ready"]]] {
            let payload: [String: Any] = ["date": "2026-09-26", "decision_id": "test", "snapshot_version": "test",
                "generation": ["state": "ready", "fresh_for_snapshot": true, "slots": slots],
                "primary": fact, "ai_insight": ["text": "Opinion", "stance": "qualify"]]
            let value = try JSONDecoder().decode(TodayInsightsResponse.self, from: JSONSerialization.data(withJSONObject: payload))
            #expect(value.primary.observation == "Available")
            #expect(value.visibleAI(for: "overall") == nil)
        }
    }

    @Test func energyLifecycleLoadsOnceAndReloadsOnDayAccountOrLanguageChange() async throws {
        var identity = "day-one"
        var waits = 0
        var briefingLoads = 0
        var historyLoads = 0
        let controller = EnergyDataController(loadBriefing: {
            briefingLoads += 1
            return try InsightFixtures.briefing()
        }, loadHistory: {
            historyLoads += 1
            return try InsightFixtures.energyHistory()
        }, context: { identity }, sleep: {
            waits += 1
            if waits == 2 { identity = "day-two" }
            if waits == 4 { identity = "other-account" }
            if waits == 6 { identity = "other-language" }
            if waits == 8 { throw CancellationError() }
        })
        await controller.run()
        #expect(briefingLoads == 4)
        #expect(historyLoads == 4)
        #expect(controller.briefing?.energyBank != nil)
    }

    private func response(state: String, retry: Int = 0, fresh: Bool = true) throws -> TodayInsightsResponse {
        let object: [String: Any] = ["date": "2026-09-26", "decision_id": "test", "snapshot_version": "test",
            "generation": ["state": state, "fresh_for_snapshot": fresh, "retry_after_seconds": retry],
            "primary": ["state": "context", "title": "Test", "observation": "Test", "meaning": "", "evidence_ids": [], "fallback": true]]
        return try JSONDecoder().decode(TodayInsightsResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@MainActor
private final class SnapshotGate {
    var continuation: CheckedContinuation<TodayInsightsResponse, Never>?
    func load() async -> TodayInsightsResponse {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForRequest() async { while continuation == nil { await Task.yield() } }
    func finish(_ value: TodayInsightsResponse) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor
private final class InsightTestState {
    var identity = "old"
    var failure: Error?
    var fail = false
}
