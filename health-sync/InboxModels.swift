import Foundation
import Observation

// MARK: - API Models

struct InboxPromptOption: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
}

struct PendingCheckinPrompt: Decodable, Identifiable, Equatable, Sendable {
    let promptID: String
    let kind: String?
    let localDate: String
    let expiresAt: String
    let title: String
    let options: [InboxPromptOption]

    var id: String { promptID }

    init(
        promptID: String,
        kind: String? = nil,
        localDate: String,
        expiresAt: String,
        title: String,
        options: [InboxPromptOption]
    ) {
        self.promptID = promptID
        self.kind = kind
        self.localDate = localDate
        self.expiresAt = expiresAt
        self.title = title
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case promptID = "prompt_id"
        case kind
        case localDate = "local_date"
        case expiresAt = "expires_at"
        case title
        case options
    }
}

struct InboxPendingResponse: Decodable, Equatable, Sendable {
    let prompts: [PendingCheckinPrompt]
    let unreadCount: Int?

    init(prompts: [PendingCheckinPrompt], unreadCount: Int? = nil) {
        self.prompts = prompts
        self.unreadCount = unreadCount
    }

    enum CodingKeys: String, CodingKey {
        case prompts
        case unreadCount = "unread_count"
    }
}

struct InboxItemSummary: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let localDate: String
    let createdAt: String
    let title: String
    let preview: String?
    let reportID: String?
    let promptID: String?
    let status: String?
    let answer: String?
    let answeredAt: String?
    let expiresAt: String?
    let timing: String?
    let answeredChannel: String?
    let readAt: String?
    let actionRoute: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, preview, status, answer, timing
        case localDate = "local_date"
        case createdAt = "created_at"
        case reportID = "report_id"
        case promptID = "prompt_id"
        case answeredAt = "answered_at"
        case expiresAt = "expires_at"
        case answeredChannel = "answered_channel"
        case readAt = "read_at"
        case actionRoute = "action_route"
    }
}

struct InboxFeedResponse: Decodable, Equatable, Sendable {
    let items: [InboxItemSummary]
    let nextCursor: String?
    let unreadCount: Int?
    let snapshotAt: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case unreadCount = "unread_count"
        case snapshotAt = "snapshot_at"
    }
}

struct InboxDetailResponse: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let localDate: String
    let createdAt: String
    let title: String
    let reportID: String?
    let body: String?
    let language: String?
    let preparedAt: String?
    let promptID: String?
    let status: String?
    let answer: String?
    let answeredAt: String?
    let expiresAt: String?
    let timing: String?
    let answeredChannel: String?
    let options: [InboxPromptOption]?
    let readAt: String?
    let actionRoute: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, language, status, answer, timing, options
        case localDate = "local_date"
        case createdAt = "created_at"
        case reportID = "report_id"
        case preparedAt = "prepared_at"
        case promptID = "prompt_id"
        case answeredAt = "answered_at"
        case expiresAt = "expires_at"
        case answeredChannel = "answered_channel"
        case readAt = "read_at"
        case actionRoute = "action_route"
    }
}

struct PromptAnswerRequest: Encodable, Equatable, Sendable {
    let answer: String
    let channel: String
}

struct PromptAnswerResponse: Decodable, Equatable, Sendable {
    let status: String
    let answer: String
    let answeredAt: String
    let timing: String
    let unreadCount: Int?

    init(
        status: String,
        answer: String,
        answeredAt: String,
        timing: String,
        unreadCount: Int? = nil
    ) {
        self.status = status
        self.answer = answer
        self.answeredAt = answeredAt
        self.timing = timing
        self.unreadCount = unreadCount
    }

    enum CodingKeys: String, CodingKey {
        case status, answer, timing
        case answeredAt = "answered_at"
        case unreadCount = "unread_count"
    }
}

struct InboxReadResponse: Decodable, Equatable, Sendable {
    let id: String
    let readAt: String
    let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case readAt = "read_at"
        case unreadCount = "unread_count"
    }
}

struct InboxReadAllRequest: Encodable, Equatable, Sendable {
    let before: String?
}

struct InboxReadAllResponse: Decodable, Equatable, Sendable {
    let updated: Int
    let unreadCount: Int
    let before: String

    enum CodingKeys: String, CodingKey {
        case updated, before
        case unreadCount = "unread_count"
    }
}

struct NotificationPreferencesResponse: Codable, Equatable, Sendable {
    let morningWeekdayHour: Int
    let morningWeekendHour: Int
    let eveningWeekdayHour: Int
    let eveningWeekendHour: Int
    let daytimeEnabled: Bool
    let daytimeStartHour: Int
    let daytimeEndHour: Int
    let pushMorningReport: Bool
    let pushEveningReport: Bool
    let pushCheckins: Bool
    let pushDaytimeUpdates: Bool
    let pushDigestsNudges: Bool
    let telegramNotificationsEnabled: Bool
    let inboxEnabled: Bool
    let apnsPushEnabled: Bool
    let telegramConfigured: Bool
    let activePushDevicesCount: Int

    enum CodingKeys: String, CodingKey {
        case morningWeekdayHour = "morning_weekday_hour"
        case morningWeekendHour = "morning_weekend_hour"
        case eveningWeekdayHour = "evening_weekday_hour"
        case eveningWeekendHour = "evening_weekend_hour"
        case daytimeEnabled = "daytime_enabled"
        case daytimeStartHour = "daytime_start_hour"
        case daytimeEndHour = "daytime_end_hour"
        case pushMorningReport = "push_morning_report"
        case pushEveningReport = "push_evening_report"
        case pushCheckins = "push_checkins"
        case pushDaytimeUpdates = "push_daytime_updates"
        case pushDigestsNudges = "push_digests_nudges"
        case telegramNotificationsEnabled = "telegram_notifications_enabled"
        case inboxEnabled = "inbox_enabled"
        case apnsPushEnabled = "apns_push_enabled"
        case telegramConfigured = "telegram_configured"
        case activePushDevicesCount = "active_push_devices_count"
    }
}

struct NotificationPreferencesRequest: Encodable, Equatable, Sendable {
    var morningWeekdayHour: Int?
    var morningWeekendHour: Int?
    var eveningWeekdayHour: Int?
    var eveningWeekendHour: Int?
    var daytimeEnabled: Bool?
    var daytimeStartHour: Int?
    var daytimeEndHour: Int?
    var pushMorningReport: Bool?
    var pushEveningReport: Bool?
    var pushCheckins: Bool?
    var pushDaytimeUpdates: Bool?
    var pushDigestsNudges: Bool?
    var telegramNotificationsEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case morningWeekdayHour = "morning_weekday_hour"
        case morningWeekendHour = "morning_weekend_hour"
        case eveningWeekdayHour = "evening_weekday_hour"
        case eveningWeekendHour = "evening_weekend_hour"
        case daytimeEnabled = "daytime_enabled"
        case daytimeStartHour = "daytime_start_hour"
        case daytimeEndHour = "daytime_end_hour"
        case pushMorningReport = "push_morning_report"
        case pushEveningReport = "push_evening_report"
        case pushCheckins = "push_checkins"
        case pushDaytimeUpdates = "push_daytime_updates"
        case pushDigestsNudges = "push_digests_nudges"
        case telegramNotificationsEnabled = "telegram_notifications_enabled"
    }
}

// MARK: - Kind & Answer Helpers

enum InboxKindHelper {
    static func isPrompt(_ kind: String) -> Bool {
        kind == "prompt_checkin" || kind == "prompt_wake_feedback" || kind == "prompt_context"
    }

    static func localizedTitle(for kind: String) -> String {
        switch kind {
        case "morning_report": return String(localized: "Morning report")
        case "evening_report": return String(localized: "Evening report")
        case "sleep_update": return String(localized: "Sleep update")
        case "guidance_change": return String(localized: "Guidance update")
        case "weekly_digest": return String(localized: "Weekly digest")
        case "nudge": return String(localized: "Notice")
        case "prompt_checkin": return String(localized: "Check-in")
        case "prompt_wake_feedback": return String(localized: "Wake time")
        case "prompt_context": return String(localized: "Sleep context")
        default: return String(localized: "Inbox")
        }
    }
}

// MARK: - Today Inbox Controller

struct InboxFeedPage {
    enum Filter: String, CaseIterable {
        case all
        case unread

        var query: String? { self == .unread ? rawValue : nil }
    }

    private(set) var filter: Filter = .all
    var items: [InboxItemSummary] = []
    var nextCursor: String?
    var snapshotAt: String?

    @discardableResult
    mutating func select(_ nextFilter: Filter) -> Bool {
        guard filter != nextFilter else { return false }
        self = InboxFeedPage(filter: nextFilter)
        return true
    }
}

enum PromptSubmissionState: Equatable {
    case idle
    case submitting(promptID: String, optionID: String)
    case error(promptID: String, message: String)
    case resolved(promptID: String, status: String, answerLabel: String?)
}

@MainActor
@Observable
final class TodayInboxController {
    typealias FetchPending = @MainActor () async throws -> InboxPendingResponse
    typealias SubmitAnswer = @MainActor (String, String) async throws -> PromptAnswerResponse
    typealias BadgeSync = @MainActor (Int) -> Void

    private(set) var supported = false
    private(set) var pendingPrompts: [PendingCheckinPrompt] = []
    private(set) var unreadCount: Int = 0
    private(set) var submissionState: PromptSubmissionState = .idle

    private let fetchPending: FetchPending
    private let submitAnswer: SubmitAnswer
    private let syncBadge: BadgeSync
    private var loadGeneration = UUID()
    private var unreadGeneration = UUID()
    private var sessionGeneration = UUID()

    init(
        fetchPending: @escaping FetchPending = { try await ServerClient.shared.pendingInboxPrompts() },
        submitAnswer: @escaping SubmitAnswer = { promptID, answer in
            try await ServerClient.shared.answerInboxPrompt(promptID: promptID, answer: answer)
        },
        syncBadge: @escaping BadgeSync = { AppBadgeSync.update(unreadCount: $0) }
    ) {
        self.fetchPending = fetchPending
        self.submitAnswer = submitAnswer
        self.syncBadge = syncBadge
    }

    var activePrompt: PendingCheckinPrompt? {
        pendingPrompts.first
    }

    func updateUnreadCount(_ count: Int) {
        unreadGeneration = UUID()
        let clamped = max(0, count)
        unreadCount = clamped
        syncBadge(clamped)
    }

    func reset() {
        sessionGeneration = UUID()
        loadGeneration = UUID()
        supported = false
        pendingPrompts = []
        unreadCount = 0
        submissionState = .idle
        syncBadge(0)
    }

    func refresh(clearResolved: Bool = false) async {
        let generation = UUID()
        loadGeneration = generation
        let unreadSnapshot = unreadGeneration
        do {
            let response = try await fetchPending()
            guard generation == loadGeneration else { return }
            supported = true
            pendingPrompts = response.prompts
            if unreadSnapshot == unreadGeneration {
                updateUnreadCount(response.unreadCount ?? 0)
            }
            switch submissionState {
            case .resolved(let resolvedID, _, _):
                if clearResolved || response.prompts.contains(where: { $0.promptID != resolvedID }) {
                    submissionState = .idle
                }
            case .error(let errID, _):
                if !response.prompts.contains(where: { $0.promptID == errID }) {
                    submissionState = .idle
                }
            case .idle, .submitting:
                break
            }
        } catch let error as ServerError {
            guard generation == loadGeneration else { return }
            if case .http(404, _) = error {
                supported = false
                pendingPrompts = []
                submissionState = .idle
                if unreadSnapshot == unreadGeneration {
                    updateUnreadCount(0)
                }
            }
        } catch {
            // Non-404 errors keep current Inbox state without disrupting Today.
        }
    }

    func submit(
        prompt: PendingCheckinPrompt,
        optionID: String,
        onAnswered: (@MainActor () async -> Void)? = nil
    ) async {
        if case .submitting = submissionState { return }
        let session = sessionGeneration
        submissionState = .submitting(promptID: prompt.promptID, optionID: optionID)
        do {
            let response = try await submitAnswer(prompt.promptID, optionID)
            guard session == sessionGeneration else { return }
            let canonicalLabel = prompt.options.first(where: { $0.id == response.answer })?.label
                ?? CheckinAnswerLabel.localized(response.answer)
            loadGeneration = UUID()
            pendingPrompts.removeAll { $0.promptID == prompt.promptID }
            if let nextUnread = response.unreadCount {
                updateUnreadCount(nextUnread)
            }
            submissionState = .resolved(
                promptID: prompt.promptID,
                status: response.status,
                answerLabel: canonicalLabel
            )
            if let onAnswered {
                await onAnswered()
            }
        } catch let error as ServerError {
            guard session == sessionGeneration else { return }
            if case .http(409, _) = error {
                loadGeneration = UUID()
                pendingPrompts.removeAll { $0.promptID == prompt.promptID }
                submissionState = .resolved(
                    promptID: prompt.promptID,
                    status: "expired",
                    answerLabel: nil
                )
                return
            }
            submissionState = .error(
                promptID: prompt.promptID,
                message: String(localized: "Could not save your answer. Try again.")
            )
        } catch {
            guard session == sessionGeneration else { return }
            submissionState = .error(
                promptID: prompt.promptID,
                message: String(localized: "Could not save your answer. Try again.")
            )
        }
    }
}

enum CheckinAnswerLabel {
    static func localized(_ answer: String) -> String {
        switch answer {
        case "great": return String(localized: "Great")
        case "ok": return String(localized: "OK")
        case "meh": return String(localized: "Meh")
        case "sick": return String(localized: "Sick")
        case "confirmed": return String(localized: "Accurate")
        case "earlier": return String(localized: "Earlier")
        case "later": return String(localized: "Later")
        case "returned_to_sleep": return String(localized: "Went back to sleep")
        case "poor_sleep_context": return String(localized: "Poor sleep")
        case "stress_context": return String(localized: "Stress")
        case "travel_context": return String(localized: "Travel")
        case "unknown_context": return String(localized: "Not sure")
        case "skip_context": return String(localized: "Skip")
        default: return answer
        }
    }
}
