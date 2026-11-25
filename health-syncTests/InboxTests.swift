import Foundation
import Testing
@testable import health_sync

@MainActor
struct InboxTests {
    @Test
    func decodesPendingPromptInServerOrder() throws {
        let data = """
        {
          "prompts": [
            {
              "prompt_id": "11111111-1111-1111-1111-111111111111",
              "local_date": "2026-11-25",
              "expires_at": "2026-11-25T10:00:00Z",
              "title": "How are you feeling?",
              "options": [
                { "id": "great", "label": "Great" },
                { "id": "ok", "label": "OK" },
                { "id": "meh", "label": "Meh" },
                { "id": "sick", "label": "Sick" }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(InboxPendingResponse.self, from: data)
        #expect(decoded.prompts.count == 1)
        #expect(decoded.prompts[0].promptID == "11111111-1111-1111-1111-111111111111")
        #expect(decoded.prompts[0].options.map(\.id) == ["great", "ok", "meh", "sick"])
    }

    @Test
    func decodesInboxFeedAndReportDetailAsPlainText() throws {
        let feedData = """
        {
          "items": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "kind": "morning_report",
              "local_date": "2026-11-25",
              "created_at": "2026-11-25T08:00:00Z",
              "title": "Morning Report",
              "preview": "Sleep: 7h 30m",
              "report_id": "33333333-3333-3333-3333-333333333333"
            }
          ],
          "next_cursor": "opaque-cursor"
        }
        """.data(using: .utf8)!

        let feed = try JSONDecoder().decode(InboxFeedResponse.self, from: feedData)
        #expect(feed.items.count == 1)
        #expect(feed.items[0].kind == "morning_report")
        #expect(feed.nextCursor == "opaque-cursor")

        let detailData = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "kind": "morning_report",
          "local_date": "2026-11-25",
          "created_at": "2026-11-25T08:00:00Z",
          "title": "Morning Report",
          "body": "Sleep: 7h 30m\\nRecovery: Good"
        }
        """.data(using: .utf8)!

        let detail = try JSONDecoder().decode(InboxDetailResponse.self, from: detailData)
        #expect(detail.body == "Sleep: 7h 30m\nRecovery: Good")
    }

    @Test
    func controllerHidesInboxOnLegacy404Server() async {
        let controller = TodayInboxController(
            fetchPending: { throw ServerError.http(404, "not found") },
            submitAnswer: { _, _ in throw ServerError.missingConfig }
        )

        await controller.refresh()

        #expect(controller.supported == false)
        #expect(controller.pendingPrompts.isEmpty)
    }

    @Test
    func controllerHandlesSavedRaceErrorAnd409Expired() async {
        let prompt = PendingCheckinPrompt(
            promptID: "11111111-1111-1111-1111-111111111111",
            localDate: "2026-11-25",
            expiresAt: "2026-11-25T10:00:00Z",
            title: "How are you feeling?",
            options: [
                InboxPromptOption(id: "great", label: "Great"),
                InboxPromptOption(id: "sick", label: "Sick")
            ]
        )

        // 1. Network error keeps card retryable without marking resolved.
        let failing = TodayInboxController(
            fetchPending: { InboxPendingResponse(prompts: [prompt]) },
            submitAnswer: { _, _ in throw ServerError.http(503, "down") }
        )
        await failing.refresh()
        await failing.submit(prompt: prompt, optionID: "great")
        #expect(failing.activePrompt?.promptID == prompt.promptID)
        if case .error(let id, _) = failing.submissionState {
            #expect(id == prompt.promptID)
        } else {
            Issue.record("expected error submission state")
        }

        // 2. Race mismatch already_answered surfaces canonical server option label.
        let raced = TodayInboxController(
            fetchPending: { InboxPendingResponse(prompts: [prompt]) },
            submitAnswer: { _, _ in
                PromptAnswerResponse(
                    status: "already_answered",
                    answer: "sick",
                    answeredAt: "2026-11-25T08:01:00Z",
                    timing: "on_time"
                )
            }
        )
        await raced.refresh()
        await raced.submit(prompt: prompt, optionID: "great")
        #expect(raced.activePrompt == nil)
        #expect(raced.submissionState == .resolved(promptID: prompt.promptID, status: "already_answered", answerLabel: "Sick"))

        // 3. 409 expired removes prompt and stops retrying.
        let expired = TodayInboxController(
            fetchPending: { InboxPendingResponse(prompts: [prompt]) },
            submitAnswer: { _, _ in throw ServerError.http(409, "{\"status\":\"expired\"}") }
        )
        await expired.refresh()
        await expired.submit(prompt: prompt, optionID: "great")
        #expect(expired.activePrompt == nil)
        #expect(expired.submissionState == .resolved(promptID: prompt.promptID, status: "expired", answerLabel: nil))
    }

    @Test
    func controllerClearsPromptOnForegroundRefreshAfterExternalAnswer() async {
        let prompt = PendingCheckinPrompt(
            promptID: "11111111-1111-1111-1111-111111111111",
            localDate: "2026-11-25",
            expiresAt: "2026-11-25T10:00:00Z",
            title: "How are you feeling?",
            options: [
                InboxPromptOption(id: "great", label: "Great"),
                InboxPromptOption(id: "ok", label: "OK")
            ]
        )
        var serverPrompts: [PendingCheckinPrompt] = [prompt]
        let controller = TodayInboxController(
            fetchPending: { InboxPendingResponse(prompts: serverPrompts) },
            submitAnswer: { _, _ in throw ServerError.missingConfig }
        )

        await controller.refresh()
        #expect(controller.activePrompt?.promptID == prompt.promptID)

        // Answered in Web or Telegram while Health Sync was backgrounded.
        serverPrompts = []
        await controller.refresh(clearResolved: true)

        #expect(controller.supported == true)
        #expect(controller.activePrompt == nil)
        #expect(controller.submissionState == .idle)
    }
}
