import Foundation
import Observation

// MARK: - API Models

struct InboxPromptOption: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
}

struct PendingCheckinPrompt: Decodable, Identifiable, Equatable, Sendable {
    let promptID: String
    let localDate: String
    let expiresAt: String
    let title: String
    let options: [InboxPromptOption]

    var id: String { promptID }

    enum CodingKeys: String, CodingKey {
        case promptID = "prompt_id"
        case localDate = "local_date"
        case expiresAt = "expires_at"
        case title
        case options
    }
}

struct InboxPendingResponse: Decodable, Equatable, Sendable {
    let prompts: [PendingCheckinPrompt]
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
    }
}

struct InboxFeedResponse: Decodable, Equatable, Sendable {
    let items: [InboxItemSummary]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
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

    enum CodingKeys: String, CodingKey {
        case status, answer, timing
        case answeredAt = "answered_at"
    }
}

// MARK: - Today Inbox Controller

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

    private(set) var supported = false
    private(set) var pendingPrompts: [PendingCheckinPrompt] = []
    private(set) var submissionState: PromptSubmissionState = .idle

    private let fetchPending: FetchPending
    private let submitAnswer: SubmitAnswer
    private var loadGeneration = UUID()
    private var sessionGeneration = UUID()

    init(
        fetchPending: @escaping FetchPending = { try await ServerClient.shared.pendingInboxPrompts() },
        submitAnswer: @escaping SubmitAnswer = { promptID, answer in
            try await ServerClient.shared.answerInboxPrompt(promptID: promptID, answer: answer)
        }
    ) {
        self.fetchPending = fetchPending
        self.submitAnswer = submitAnswer
    }

    var activePrompt: PendingCheckinPrompt? {
        pendingPrompts.first
    }

    func reset() {
        sessionGeneration = UUID()
        loadGeneration = UUID()
        supported = false
        pendingPrompts = []
        submissionState = .idle
    }

    func refresh(clearResolved: Bool = false) async {
        let generation = UUID()
        loadGeneration = generation
        do {
            let response = try await fetchPending()
            guard generation == loadGeneration else { return }
            supported = true
            pendingPrompts = response.prompts
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
        default: return answer
        }
    }
}
