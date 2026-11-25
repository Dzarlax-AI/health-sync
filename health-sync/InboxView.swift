import SwiftUI

struct TodayPendingCheckinCard: View {
    let controller: TodayInboxController
    var onAnswered: (@MainActor () async -> Void)?

    private let columns = [
        GridItem(.flexible(), spacing: .dsSpacingSm),
        GridItem(.flexible(), spacing: .dsSpacingSm)
    ]

    var body: some View {
        if let prompt = controller.activePrompt {
            activeCard(prompt: prompt)
        } else if case .resolved(_, let status, let answerLabel) = controller.submissionState {
            resolvedBanner(status: status, answerLabel: answerLabel)
        }
    }

    @ViewBuilder
    private func activeCard(prompt: PendingCheckinPrompt) -> some View {
        let isSubmitting: Bool = {
            if case .submitting(let id, _) = controller.submissionState, id == prompt.promptID {
                return true
            }
            return false
        }()
        let errorMessage: String? = {
            if case .error(let id, let msg) = controller.submissionState, id == prompt.promptID {
                return msg
            }
            return nil
        }()

        VStack(alignment: .leading, spacing: .dsSpacing) {
            HStack {
                Text("Check-in")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.dsHorizonTextSecondary)
                Spacer()
                Text(verbatim: prompt.localDate)
                    .font(.caption)
                    .foregroundStyle(Color.dsHorizonTextSecondary)
            }

            Text(verbatim: prompt.title)
                .font(.headline)
                .foregroundStyle(Color.dsHorizonText)

            LazyVGrid(columns: columns, spacing: .dsSpacingSm) {
                ForEach(prompt.options) { option in
                    Button {
                        Task {
                            await controller.submit(
                                prompt: prompt,
                                optionID: option.id,
                                onAnswered: onAnswered
                            )
                        }
                    } label: {
                        Text(verbatim: option.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.dsHorizonText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 10)
                            .background(Color.dsHorizonSurfaceTint, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.6 : 1)
                    .accessibilityIdentifier("checkin-option-\(option.id)")
                }
            }

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.dsDanger)
            }
        }
        .padding(.dsSpacing)
        .horizonSurface()
        .accessibilityIdentifier("today-pending-checkin-card")
    }

    private func resolvedBanner(status: String, answerLabel: String?) -> some View {
        let text: String = {
            if status == "expired" {
                return String(localized: "This check-in is no longer active for today.")
            }
            if status == "already_answered" {
                if let answerLabel, !answerLabel.isEmpty {
                    return String(localized: "Already answered: \(answerLabel)")
                }
                return String(localized: "Already answered")
            }
            if let answerLabel, !answerLabel.isEmpty {
                return String(localized: "Saved: \(answerLabel)")
            }
            return String(localized: "Saved")
        }()

        return HStack(spacing: .dsSpacingSm) {
            Image(systemName: status == "expired" ? "clock" : "checkmark.circle.fill")
                .foregroundStyle(status == "expired" ? Color.dsHorizonTextSecondary : Color.dsGood)
            Text(verbatim: text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.dsHorizonText)
            Spacer()
        }
        .padding(.dsSpacing)
        .horizonSurface()
        .accessibilityIdentifier("today-checkin-resolved-banner")
    }
}

struct InboxView: View {
    var onPromptAnswered: (@MainActor () async -> Void)?

    @State private var items: [InboxItemSummary] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var feedGeneration = UUID()
    @State private var loadError: String?
    @State private var unavailable = false
    @State private var pendingController = TodayInboxController()

    var body: some View {
        ZStack(alignment: .top) {
            DomainBackdrop(appearance: .recovery)

            ScrollView {
                VStack(alignment: .leading, spacing: .dsSpacing) {
                    if pendingController.activePrompt != nil ||
                        pendingController.submissionState != .idle {
                        TodayPendingCheckinCard(
                            controller: pendingController,
                            onAnswered: {
                                await loadFeed()
                                if let onPromptAnswered {
                                    await onPromptAnswered()
                                }
                            }
                        )
                    }

                    if isLoading && items.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, .dsSpacingXl)
                    } else if unavailable {
                        emptyState(String(localized: "Inbox is not enabled on this server."))
                    } else if let loadError, items.isEmpty {
                        VStack(spacing: .dsSpacingSm) {
                            emptyState(loadError)
                            Button("Try again") {
                                Task { await reloadAll() }
                            }
                            .buttonStyle(DSPrimaryButtonStyle())
                        }
                    } else if items.isEmpty {
                        emptyState(String(localized: "Morning reports and check-ins will appear here."))
                    } else {
                        ForEach(items) { item in
                            NavigationLink {
                                InboxDetailView(
                                    itemID: item.id,
                                    onPromptAnswered: {
                                        await reloadAll()
                                        if let onPromptAnswered {
                                            await onPromptAnswered()
                                        }
                                    }
                                )
                            } label: {
                                InboxItemRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }

                        if nextCursor != nil {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                if isLoadingMore {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Load older")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(DSPrimaryButtonStyle())
                            .disabled(isLoading || isLoadingMore)
                        }
                    }
                }
                .padding(.horizontal, .dsSpacing)
                .padding(.vertical, .dsSpacing)
            }
            .refreshable {
                await reloadAll()
            }
        }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await reloadAll()
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(verbatim: message)
            .font(.subheadline)
            .foregroundStyle(Color.dsHorizonTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.dsSpacing)
            .horizonSurface()
    }

    private func reloadAll() async {
        async let pending: Void = pendingController.refresh()
        async let feed: Void = loadFeed()
        _ = await (pending, feed)
    }

    private func loadFeed() async {
        let generation = UUID()
        feedGeneration = generation
        isLoading = true
        isLoadingMore = false
        loadError = nil
        unavailable = false
        do {
            let feed = try await ServerClient.shared.inbox(limit: 20)
            guard generation == feedGeneration else { return }
            items = feed.items
            nextCursor = (feed.nextCursor?.isEmpty == false) ? feed.nextCursor : nil
        } catch let error as ServerError {
            guard generation == feedGeneration else { return }
            if case .http(404, _) = error {
                unavailable = true
                items = []
                nextCursor = nil
            } else {
                loadError = error.localizedDescription
            }
        } catch {
            guard generation == feedGeneration else { return }
            loadError = error.localizedDescription
        }
        if generation == feedGeneration {
            isLoading = false
        }
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore, let cursor = nextCursor else { return }
        let generation = feedGeneration
        isLoadingMore = true
        do {
            let more = try await ServerClient.shared.inbox(limit: 20, cursor: cursor)
            guard generation == feedGeneration else { return }
            items.append(contentsOf: more.items)
            nextCursor = (more.nextCursor?.isEmpty == false) ? more.nextCursor : nil
        } catch {
            // Keep loaded items visible for retry.
        }
        if generation == feedGeneration {
            isLoadingMore = false
        }
    }
}

private struct InboxItemRow: View {
    let item: InboxItemSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: item.title)
                    .font(.headline)
                    .foregroundStyle(Color.dsHorizonText)
                Spacer()
                Text(verbatim: item.localDate)
                    .font(.caption)
                    .foregroundStyle(Color.dsHorizonTextSecondary)
            }

            if item.kind == "morning_report", let preview = item.preview, !preview.isEmpty {
                Text(verbatim: preview)
                    .font(.subheadline)
                    .foregroundStyle(Color.dsHorizonTextSecondary)
                    .lineLimit(3)
            } else if item.kind == "prompt_checkin" {
                Text(verbatim: checkinSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.dsHorizonTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dsSpacing)
        .horizonSurface()
    }

    private var checkinSubtitle: String {
        let statusLabel: String
        switch item.status {
        case "answered": statusLabel = String(localized: "Answered")
        case "late_answered": statusLabel = String(localized: "Answered late")
        case "expired": statusLabel = String(localized: "Expired")
        case "prompted": statusLabel = String(localized: "Waiting for answer")
        default: statusLabel = item.status ?? ""
        }
        if let answer = item.answer, !answer.isEmpty {
            return "\(statusLabel) · \(CheckinAnswerLabel.localized(answer))"
        }
        return statusLabel
    }
}

struct InboxDetailView: View {
    let itemID: String
    var onPromptAnswered: (@MainActor () async -> Void)?

    @State private var detail: InboxDetailResponse?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var submitting = false
    @State private var actionNotice: String?

    private let columns = [
        GridItem(.flexible(), spacing: .dsSpacingSm),
        GridItem(.flexible(), spacing: .dsSpacingSm)
    ]

    var body: some View {
        ZStack(alignment: .top) {
            DomainBackdrop(appearance: .recovery)

            ScrollView {
                VStack(alignment: .leading, spacing: .dsSpacing) {
                    if isLoading && detail == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, .dsSpacingXl)
                    } else if let loadError, detail == nil {
                        VStack(spacing: .dsSpacingSm) {
                            Text(verbatim: loadError)
                                .font(.subheadline)
                                .foregroundStyle(Color.dsHorizonTextSecondary)
                            Button("Try again") {
                                Task { await load() }
                            }
                            .buttonStyle(DSPrimaryButtonStyle())
                        }
                        .padding(.dsSpacing)
                        .horizonSurface()
                    } else if let detail {
                        VStack(alignment: .leading, spacing: .dsSpacing) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: detail.title)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Color.dsHorizonText)
                                Spacer()
                                Text(verbatim: detail.localDate)
                                    .font(.caption)
                                    .foregroundStyle(Color.dsHorizonTextSecondary)
                            }

                            if detail.kind == "morning_report" {
                                Text(verbatim: detail.body ?? "")
                                    .font(.body)
                                    .foregroundStyle(Color.dsHorizonText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                checkinDetailSection(detail)
                            }
                        }
                        .padding(.dsSpacing)
                        .horizonSurface()
                    }
                }
                .padding(.horizontal, .dsSpacing)
                .padding(.vertical, .dsSpacing)
            }
        }
        .navigationTitle(detail?.title ?? String(localized: "Inbox"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: itemID) {
            await load()
        }
    }

    @ViewBuilder
    private func checkinDetailSection(_ detail: InboxDetailResponse) -> some View {
        let statusText: String = {
            switch detail.status {
            case "answered": return String(localized: "Answered")
            case "late_answered": return String(localized: "Answered late")
            case "expired": return String(localized: "Expired")
            case "prompted": return String(localized: "Waiting for answer")
            default: return detail.status ?? ""
            }
        }()

        let answerLabel = detail.answer.map { raw in
            detail.options?.first(where: { $0.id == raw })?.label ?? CheckinAnswerLabel.localized(raw)
        }
        Text(verbatim: answerLabel.map { "\(statusText): \($0)" } ?? statusText)
            .font(.subheadline)
            .foregroundStyle(Color.dsHorizonTextSecondary)

        if (detail.status == "prompted" || detail.status == "expired"),
           let promptID = detail.promptID,
           let options = detail.options,
           !options.isEmpty {
            LazyVGrid(columns: columns, spacing: .dsSpacingSm) {
                ForEach(options) { option in
                    Button {
                        Task { await answerFromDetail(promptID: promptID, option: option, options: options) }
                    } label: {
                        Text(verbatim: option.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.dsHorizonText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 10)
                            .background(Color.dsHorizonSurfaceTint, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(submitting)
                    .opacity(submitting ? 0.6 : 1)
                }
            }
        }

        if let actionNotice {
            Text(verbatim: actionNotice)
                .font(.footnote)
                .foregroundStyle(Color.dsHorizonTextSecondary)
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            detail = try await ServerClient.shared.inboxItem(id: itemID)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func answerFromDetail(
        promptID: String,
        option: InboxPromptOption,
        options: [InboxPromptOption]
    ) async {
        guard !submitting else { return }
        submitting = true
        actionNotice = nil
        do {
            let res = try await ServerClient.shared.answerInboxPrompt(promptID: promptID, answer: option.id)
            let label = options.first(where: { $0.id == res.answer })?.label ?? res.answer
            if res.status == "already_answered" {
                actionNotice = String(localized: "Already answered: \(label)")
            } else {
                actionNotice = String(localized: "Saved: \(label)")
            }
            await load()
            if let onPromptAnswered {
                await onPromptAnswered()
            }
        } catch let error as ServerError {
            if case .http(409, _) = error {
                actionNotice = String(localized: "This check-in is no longer active for today.")
                await load()
                if let onPromptAnswered {
                    await onPromptAnswered()
                }
            } else {
                actionNotice = String(localized: "Could not save your answer. Try again.")
            }
        } catch {
            actionNotice = String(localized: "Could not save your answer. Try again.")
        }
        submitting = false
    }
}
