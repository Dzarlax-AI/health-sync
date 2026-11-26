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

    @Test
    func staleInFlightRefreshCannotRestoreAnsweredPrompt() async {
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

        var releaseStaleRefresh: CheckedContinuation<InboxPendingResponse, Error>?
        var fetchCall = 0
        let controller = TodayInboxController(
            fetchPending: {
                fetchCall += 1
                if fetchCall == 1 {
                    return InboxPendingResponse(prompts: [prompt])
                }
                if fetchCall == 2 {
                    return try await withCheckedThrowingContinuation { cont in
                        releaseStaleRefresh = cont
                    }
                }
                return InboxPendingResponse(prompts: [])
            },
            submitAnswer: { _, _ in
                PromptAnswerResponse(
                    status: "saved",
                    answer: "great",
                    answeredAt: "2026-11-25T08:05:00Z",
                    timing: "on_time"
                )
            }
        )

        await controller.refresh()
        #expect(controller.activePrompt?.promptID == prompt.promptID)

        // Start a refresh before answering, hold it in flight while submit succeeds.
        let staleRefreshTask = Task { await controller.refresh() }
        while releaseStaleRefresh == nil {
            await Task.yield()
        }

        await controller.submit(prompt: prompt, optionID: "great")
        #expect(controller.activePrompt == nil)

        // Now complete the stale refresh with the pre-answer prompt list.
        releaseStaleRefresh?.resume(returning: InboxPendingResponse(prompts: [prompt]))
        await staleRefreshTask.value

        #expect(controller.activePrompt == nil)
        #expect(controller.submissionState == .resolved(promptID: prompt.promptID, status: "saved", answerLabel: "Great"))
    }

    @Test
    func submissionCompletionFromBeforeResetIsDiscarded() async {
        let promptA = PendingCheckinPrompt(
            promptID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            localDate: "2026-11-25",
            expiresAt: "2026-11-25T10:00:00Z",
            title: "How are you feeling?",
            options: [InboxPromptOption(id: "great", label: "Great")]
        )
        let promptB = PendingCheckinPrompt(
            promptID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            localDate: "2026-11-25",
            expiresAt: "2026-11-25T10:00:00Z",
            title: "How are you feeling?",
            options: [InboxPromptOption(id: "ok", label: "OK")]
        )

        var releaseSubmitA: CheckedContinuation<PromptAnswerResponse, Error>?
        var releaseSubmitB: CheckedContinuation<PromptAnswerResponse, Error>?
        var onAnsweredACalled = false

        let controller = TodayInboxController(
            fetchPending: { InboxPendingResponse(prompts: [promptB]) },
            submitAnswer: { promptID, _ in
                try await withCheckedThrowingContinuation { cont in
                    if promptID == promptA.promptID {
                        releaseSubmitA = cont
                    } else {
                        releaseSubmitB = cont
                    }
                }
            }
        )

        let submitATask = Task {
            await controller.submit(prompt: promptA, optionID: "great") {
                onAnsweredACalled = true
            }
        }
        while releaseSubmitA == nil {
            await Task.yield()
        }

        // Switch server endpoint -> reset controller and start submitting promptB.
        controller.reset()
        await controller.refresh()
        let submitBTask = Task {
            await controller.submit(prompt: promptB, optionID: "ok")
        }
        while releaseSubmitB == nil {
            await Task.yield()
        }

        // Endpoint A fails late after reset: must not overwrite endpoint B's submitting state.
        releaseSubmitA?.resume(throwing: ServerError.http(500, "endpoint changed"))
        await submitATask.value

        #expect(onAnsweredACalled == false)
        #expect(controller.submissionState == .submitting(promptID: promptB.promptID, optionID: "ok"))

        releaseSubmitB?.resume(returning: PromptAnswerResponse(
            status: "saved",
            answer: "ok",
            answeredAt: "2026-11-25T08:06:00Z",
            timing: "on_time"
        ))
        await submitBTask.value

        #expect(controller.submissionState == .resolved(promptID: promptB.promptID, status: "saved", answerLabel: "OK"))
    }

    @Test
    func decodesStage3FeedReadEndpointsAndNotificationPreferences() throws {
        let feedData = """
        {
          "items": [
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "kind": "nudge",
              "local_date": "2026-11-26",
              "created_at": "2026-11-26T09:00:00Z",
              "title": "Energy backfill ready",
              "preview": "Run backfill in Settings.",
              "action_route": "/settings"
            }
          ],
          "unread_count": 3,
          "snapshot_at": "2026-11-26T09:05:00Z"
        }
        """.data(using: .utf8)!
        let feed = try JSONDecoder().decode(InboxFeedResponse.self, from: feedData)
        #expect(feed.unreadCount == 3)
        #expect(feed.snapshotAt == "2026-11-26T09:05:00Z")
        #expect(feed.items.first?.actionRoute == "/settings")

        let readRes = try JSONDecoder().decode(
            InboxReadResponse.self,
            from: """
            {"id":"44444444-4444-4444-4444-444444444444","read_at":"2026-11-26T09:06:00Z","unread_count":2}
            """.data(using: .utf8)!
        )
        #expect(readRes.unreadCount == 2)

        let readAllRes = try JSONDecoder().decode(
            InboxReadAllResponse.self,
            from: """
            {"updated":2,"unread_count":0,"before":"2026-11-26T09:05:00Z"}
            """.data(using: .utf8)!
        )
        #expect(readAllRes.updated == 2)
        #expect(readAllRes.unreadCount == 0)

        let prefs = try JSONDecoder().decode(
            NotificationPreferencesResponse.self,
            from: """
            {
              "morning_weekday_hour": 8,
              "morning_weekend_hour": 9,
              "evening_weekday_hour": 20,
              "evening_weekend_hour": 21,
              "daytime_enabled": true,
              "daytime_start_hour": 9,
              "daytime_end_hour": 21,
              "push_morning_report": true,
              "push_evening_report": true,
              "push_checkins": true,
              "push_daytime_updates": true,
              "push_digests_nudges": true,
              "telegram_notifications_enabled": false,
              "inbox_enabled": true,
              "apns_push_enabled": true,
              "telegram_configured": true,
              "active_push_devices_count": 1
            }
            """.data(using: .utf8)!
        )
        #expect(prefs.pushDigestsNudges == true)
        #expect(prefs.telegramNotificationsEnabled == false)
        #expect(prefs.activePushDevicesCount == 1)
    }

    @Test
    func controllerSyncsLiveUnreadBadgeAcrossRefreshAnswerAndReset() async {
        var syncedBadges: [Int] = []
        let wakePrompt = PendingCheckinPrompt(
            promptID: "55555555-5555-5555-5555-555555555555",
            kind: "prompt_wake_feedback",
            localDate: "2026-11-26",
            expiresAt: "2026-11-26T16:00:00Z",
            title: "Did you wake up around 07:15?",
            options: [
                InboxPromptOption(id: "confirmed", label: "Accurate"),
                InboxPromptOption(id: "earlier", label: "Earlier")
            ]
        )

        let controller = TodayInboxController(
            fetchPending: { InboxPendingResponse(prompts: [wakePrompt], unreadCount: 4) },
            submitAnswer: { _, _ in
                PromptAnswerResponse(
                    status: "saved",
                    answer: "confirmed",
                    answeredAt: "2026-11-26T08:00:00Z",
                    timing: "on_time",
                    unreadCount: 3
                )
            },
            syncBadge: { syncedBadges.append($0) }
        )

        await controller.refresh()
        #expect(controller.unreadCount == 4)
        #expect(syncedBadges == [4])

        await controller.submit(prompt: wakePrompt, optionID: "confirmed")
        #expect(controller.unreadCount == 3)
        #expect(syncedBadges == [4, 3])

        controller.reset()
        #expect(controller.unreadCount == 0)
        #expect(syncedBadges == [4, 3, 0])
    }

    @Test
    func readCountWinsOverAnOlderPendingRefreshAndNextRefreshStillUpdates() async {
        var badges: [Int] = []
        var fetches = 0
        var replyToOldFetch: CheckedContinuation<InboxPendingResponse, Never>?
        let started = AsyncStream<Void>.makeStream()
        let controller = TodayInboxController(
            fetchPending: {
                fetches += 1
                if fetches == 1 {
                    return await withCheckedContinuation {
                        replyToOldFetch = $0
                        started.continuation.yield()
                        started.continuation.finish()
                    }
                }
                return InboxPendingResponse(prompts: [], unreadCount: 2)
            },
            syncBadge: { badges.append($0) }
        )
        let oldRefresh = Task { await controller.refresh() }
        var signals = started.stream.makeAsyncIterator()
        _ = await signals.next()
        controller.updateUnreadCount(3)
        replyToOldFetch?.resume(returning: InboxPendingResponse(prompts: [], unreadCount: 4))
        await oldRefresh.value
        #expect(controller.unreadCount == 3)
        #expect(badges == [3])

        await controller.refresh()
        #expect(controller.unreadCount == 2)
        #expect(badges == [3, 2])
    }

    @Test
    func feedFilterClearsOnlyThePreviousFiltersPageAndCursor() throws {
        let item = try JSONDecoder().decode(InboxItemSummary.self, from: Data("""
        {"id":"11111111-1111-4111-8111-111111111111","kind":"morning_report",
         "local_date":"2026-11-26","created_at":"2026-11-26T08:00:00Z","title":"Report",
         "read_at":"2026-11-26T08:05:00Z"}
        """.utf8))
        var page = InboxFeedPage()
        page.items = [item]
        page.nextCursor = "all-cursor"
        page.snapshotAt = "all-snapshot"
        let sameFilterChanged = page.select(.all)
        #expect(!sameFilterChanged)
        #expect(page.items == [item])
        #expect(page.nextCursor == "all-cursor")

        let filterChanged = page.select(.unread)
        #expect(filterChanged)
        #expect(page.filter.query == "unread")
        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
        #expect(page.snapshotAt == nil)
    }


    @Test
    func unreadRefreshKeepsInboxCountWithoutRestoringOptedOutIconBadge() async {
        var iconCounts: [Int] = []
        var pushesEnabled = true
        let controller = TodayInboxController(
            fetchPending: { InboxPendingResponse(prompts: [], unreadCount: 4) },
            syncBadge: { iconCounts.append(AppBadgeSync.iconCount(unreadCount: $0, pushesEnabled: pushesEnabled)) }
        )
        await controller.refresh()
        pushesEnabled = false
        await controller.refresh()
        #expect(controller.unreadCount == 4)
        #expect(iconCounts == [4, 0])
    }

}
