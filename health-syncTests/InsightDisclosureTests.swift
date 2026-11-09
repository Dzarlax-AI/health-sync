import Testing
@testable import health_sync

@MainActor
struct InsightDisclosureTests {
    @Test(arguments: ["disabled", "cold", "generating", "failed", "future-state", "ready"])
    func defaultsFollowActualVisibleContentForEverySlot(state: String) throws {
        let snapshot = try InsightFixtures.snapshot(state: state)
        for slot in ["overall", "sleep", "recovery", "energy"] {
            let disclosure = InsightDisclosureState()
            let visible = snapshot.visibleAI(for: slot).map { !$0.text.isEmpty } ?? false
            #expect(disclosure.serverExpanded(hasVisibleAI: visible) == !visible)
            #expect(disclosure.aiExpanded)
        }
    }

    @Test func retainedAIKeepsNormalDefaultAndManualChoiceSurvivesAvailabilityChanges() throws {
        let snapshot = try InsightFixtures.snapshot(state: "generating", retained: true)
        for slot in ["overall", "sleep", "recovery", "energy"] {
            let visible = snapshot.visibleAI(for: slot) != nil
            #expect(visible)
            var disclosure = InsightDisclosureState()
            #expect(!disclosure.serverExpanded(hasVisibleAI: visible))
            disclosure.toggleServer(hasVisibleAI: visible)
            #expect(disclosure.serverExpanded(hasVisibleAI: false))
            #expect(disclosure.serverExpanded(hasVisibleAI: true))
            disclosure.toggleServer(hasVisibleAI: true)
            #expect(!disclosure.serverExpanded(hasVisibleAI: false))
            disclosure.toggleAI()
            #expect(!disclosure.aiExpanded)
        }
    }

    @Test func disclosureIdentityIsStableAcrossPollingAndResetsWithContext() async throws {
        let state = DisclosureTestContext()
        let controller = TodayInsightsController(loader: { try InsightFixtures.snapshot() },
            context: { state.value }, prepare: {})
        await controller.refresh()
        let initial = controller.contentIdentity
        await controller.refresh()
        #expect(controller.contentIdentity == initial)
        state.value = "account-one-day-two"
        await controller.refresh()
        let nextDay = controller.contentIdentity
        #expect(nextDay != initial)
        state.value = "account-two-day-two"
        await controller.refresh()
        #expect(controller.contentIdentity != nextDay)
    }
}

@MainActor
private final class DisclosureTestContext {
    var value = "account-one-day-one"
}
