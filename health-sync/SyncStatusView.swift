import SwiftUI

/// The single user-facing home for delivery state. It renders the engine's
/// typed snapshot and does not infer delivery or completeness from timestamps.
struct SyncStatusView: View {
    private let engine = SyncEngine.shared
    private let onConfigure: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var customDays = 7
    @State private var showCustomResync = false

    init(onConfigure: (() -> Void)? = nil) {
        self.onConfigure = onConfigure
    }

    private var visibleState: SyncUIState {
        SyncUIFixtures.state ?? engine.uiState
    }

    var body: some View {
        ScrollView {
            VStack(spacing: .dsSpacingLg) {
                overallCard
                channelCard(title: "Metrics", channel: visibleState.metrics,
                            icon: "waveform.path.ecg", tint: .dsHeart, isWorkout: false)
                channelCard(title: "Workouts", channel: visibleState.workouts,
                            icon: "figure.strengthtraining.traditional", tint: .dsActivity, isWorkout: true)
                historyAndResync
            }
            .padding(.dsSpacing)
        }
        .background(Color.dsBackground)
        .navigationTitle("Data & sync")
        .navigationBarTitleDisplayMode(.inline)
        .task { engine.refreshConfiguration() }
    }

    private var overallCard: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            overallHeader

            // Keep the one contextual action close to the state it resolves.
            // Long localized details and failure text follow it, especially
            // at accessibility sizes where they can span several lines.
            primaryAction

            Text(statusDetail(visibleState.status))
                .font(.dsBodySm)
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if engine.isSyncing && engine.isBuildingInitialSleepHistory {
                Label("Building your recent sleep history. This runs once and does not block today's sync.",
                      systemImage: "moon.zzz.fill")
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = visibleState.metrics.failure ?? visibleState.workouts.failure {
                failureRow(failure)
            }
        }
        .padding(.dsSpacing)
        .dsCard()
    }

    @ViewBuilder
    private var overallHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: .dsSpacingSm) {
                statusTitleBlock
                DSStatusBadge(text: statusBadge(visibleState.status),
                              status: badgeStatus(visibleState.status))
            }
        } else {
            HStack(alignment: .top, spacing: .dsSpacing) {
                statusTitleBlock
                Spacer(minLength: 0)
                DSStatusBadge(text: statusBadge(visibleState.status),
                              status: badgeStatus(visibleState.status))
            }
        }
    }

    private var statusTitleBlock: some View {
        VStack(alignment: .leading, spacing: .dsSpacingXs) {
            Text("Latest sync attempt")
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
            Text(statusTitle(visibleState.status))
                .font(.dsHeading)
                .foregroundStyle(statusColor(visibleState.status))
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch visibleState.primaryAction {
        case .configure:
            Button("Connect server", systemImage: "server.rack", action: configure)
                .frame(maxWidth: .infinity)
                .buttonStyle(DSPrimaryButtonStyle())
                .accessibilityIdentifier("sync-primary-action")
        case .sync:
            Button(engine.isSyncing ? "Syncing…" : "Sync now",
                   systemImage: "arrow.trianglehead.2.clockwise",
                   action: sync)
                .frame(maxWidth: .infinity)
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(engine.isSyncing || !visibleState.canSync)
                .accessibilityIdentifier("sync-primary-action")
        case .retry:
            Button(engine.isSyncing ? "Retrying…" : "Retry",
                   systemImage: "arrow.clockwise",
                   action: retry)
                .frame(maxWidth: .infinity)
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(engine.isSyncing || !visibleState.canSync)
                .accessibilityIdentifier("sync-primary-action")
        }
    }

    private func channelCard(title: LocalizedStringKey,
                             channel: SyncChannelSnapshot,
                             icon: String,
                             tint: Color,
                             isWorkout: Bool) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            HStack(spacing: .dsSpacingSm) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.dsSubhead)
                    .foregroundStyle(Color.dsText)
                Spacer(minLength: 0)
                DSStatusBadge(text: statusBadge(channel.status),
                              status: badgeStatus(channel.status))
            }

            VStack(alignment: .leading, spacing: .dsSpacingSm) {
                if let accepted = channel.lastAcceptedAt {
                    LabeledContent("Last accepted") {
                        Text(accepted, style: .relative)
                            .font(.dsBodySm)
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                } else {
                    LabeledContent("Last accepted") {
                        Text("Never")
                            .font(.dsBodySm)
                            .foregroundStyle(Color.dsTextTertiary)
                    }
                }

                if channel.acceptedCount > 0 {
                    LabeledContent("Last upload size") {
                        Text(uploadCount(channel.acceptedCount, isWorkout: isWorkout))
                            .font(.dsBodySm)
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                }

                if let pendingSince = channel.pendingSince {
                    LabeledContent("Pending since") {
                        Text(pendingSince, style: .relative)
                            .font(.dsBodySm)
                            .foregroundStyle(Color.dsWarn)
                    }
                }

                if let retryAt = channel.retryAt {
                    LabeledContent("Retry") {
                        Text(retryAt, style: .relative)
                            .font(.dsBodySm)
                            .foregroundStyle(Color.dsWarn)
                    }
                }
            }

            if let failure = channel.failure {
                failureRow(failure)
            }
        }
        .padding(.dsSpacing)
        .dsCard()
    }

    private var historyAndResync: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup {
                VStack(spacing: .dsSpacing) {
                    if engine.history.isEmpty && engine.legacyHistory.isEmpty {
                        Text("No sync history yet.")
                            .font(.dsBodySm)
                            .foregroundStyle(Color.dsTextTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, .dsSpacingSm)
                    } else {
                        if !engine.history.isEmpty {
                            Text("This account")
                                .font(.dsCaption.weight(.medium))
                                .foregroundStyle(Color.dsTextTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            historyRows(engine.history)
                        }
                        if !engine.legacyHistory.isEmpty {
                            if !engine.history.isEmpty { Divider() }
                            VStack(alignment: .leading, spacing: .dsSpacingXs) {
                                Text("Older attempts (account unknown)")
                                    .font(.dsCaption.weight(.medium))
                                    .foregroundStyle(Color.dsTextTertiary)
                                Text("These attempts are retained without account attribution.")
                                    .font(.dsCaption)
                                    .foregroundStyle(Color.dsTextTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            historyRows(engine.legacyHistory)
                        }
                    }

                    Button("Re-sync a date range…", systemImage: "calendar.badge.clock") {
                        showCustomResync = true
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(engine.isSyncing || !visibleState.canSync)
                }
                .padding(.top, .dsSpacingSm)
            } label: {
                Label("History & re-sync", systemImage: "clock.arrow.circlepath")
                    .font(.dsSubhead)
                    .foregroundStyle(Color.dsText)
            }
            .padding(.dsSpacing)
            .accessibilityIdentifier("sync-history-disclosure")
        }
        .dsCard()
        .sheet(isPresented: $showCustomResync) {
            customResyncSheet
        }
    }

    @ViewBuilder
    private func historyRows(_ entries: [SyncEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { Divider() }
            historyRow(entry)
        }
    }

    private func historyRow(_ entry: SyncEntry) -> some View {
        HStack(alignment: .top, spacing: .dsSpacingSm) {
            Image(systemName: historyIcon(entry))
                .foregroundStyle(historyColor(entry))
            VStack(alignment: .leading, spacing: .dsSpacingXs) {
                Text(entry.date, style: .relative)
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsText)
                if let error = entry.error {
                    Text(verbatim: error)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entry.points > 0 {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("Accepted items: %lld", comment: "Acknowledged item count in sync history"),
                        entry.points
                    ))
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                } else {
                    Text("Attempt")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func historyIcon(_ entry: SyncEntry) -> String {
        if entry.success && entry.points > 0 { return "checkmark.circle.fill" }
        if entry.error != nil { return "xmark.circle.fill" }
        return "circle.dotted"
    }

    private func historyColor(_ entry: SyncEntry) -> Color {
        if entry.success && entry.points > 0 { return .dsGood }
        if entry.error != nil { return .dsDanger }
        return .dsTextTertiary
    }

    private var customResyncSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: .dsSpacingLg) {
                VStack(alignment: .leading, spacing: .dsSpacingSm) {
                    Text("Date range")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                    // The server-side availability audit spans 108 days. Keep the
                    // manual control above that boundary so a user can establish
                    // the required coverage in one explicit re-sync, while the
                    // regular/background sync remains its lightweight 7-day job.
                    Stepper(value: $customDays, in: 1...120) {
                        Text("Last \(customDays) days")
                            .font(.dsHeading)
                            .foregroundStyle(Color.dsText)
                    }
                    Text("Re-reads Health data for this range and retries any incomplete channel delivery.")
                        .font(.dsBodySm)
                        .foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.dsSpacing)
                .dsCard()

                Button("Start re-sync", systemImage: "arrow.trianglehead.2.clockwise") {
                    startResync()
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(engine.isSyncing || !visibleState.canSync)

                Spacer()
            }
            .padding(.dsSpacing)
            .background(Color.dsBackground)
            .navigationTitle("Re-sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showCustomResync = false }
                }
            }
        }
    }

    private func failureRow(_ failure: SyncFailure) -> some View {
        Label {
            VStack(alignment: .leading, spacing: .dsSpacingXs) {
                Text(failureTitle(failure.code))
                    .font(.dsBodySm.weight(.medium))
                    .foregroundStyle(Color.dsDanger)
                Text(verbatim: failure.message)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.dsDanger)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dsSpacingSm)
        .background(Color.dsDangerBg)
        .clipShape(RoundedRectangle(cornerRadius: .dsRadius))
    }

    private func configure() {
        dismiss()
        guard let onConfigure else { return }
        Task { @MainActor in
            // Let the pushed screen leave the navigation stack before the
            // parent performs its destination-specific action.
            await Task.yield()
            onConfigure()
        }
    }

    private func sync() {
        Task { _ = await engine.syncNow() }
    }

    private func retry() {
        Task { _ = await engine.retryNow() }
    }

    private func startResync() {
        showCustomResync = false
        let days = customDays
        Task { _ = await engine.syncFullDays(daysBack: days) }
    }

    private func statusTitle(_ status: SyncStatus) -> LocalizedStringKey {
        switch status {
        case .notConfigured: return "Not configured"
        case .noData: return "No available data"
        case .sending: return "Sending"
        case .accepted: return "Accepted by server"
        case .partial: return "Partially accepted"
        case .retryPending: return "Waiting to retry"
        case .error: return "Needs attention"
        case .disabled: return "Sync disabled"
        }
    }

    private func uploadCount(_ count: Int, isWorkout: Bool) -> String {
        let key = isWorkout ? "%lld workouts" : "%lld samples"
        return String.localizedStringWithFormat(NSLocalizedString(key, comment: "Accepted upload volume by channel"), count)
    }

    private func statusBadge(_ status: SyncStatus) -> LocalizedStringKey {
        switch status {
        case .notConfigured: return "Not configured"
        case .noData: return "No data"
        case .sending: return "Sending"
        case .accepted: return "Accepted"
        case .partial: return "Partial"
        case .retryPending: return "Retry pending"
        case .error: return "Error"
        case .disabled: return "Disabled"
        }
    }

    private func statusDetail(_ status: SyncStatus) -> LocalizedStringKey {
        switch status {
        case .notConfigured: return "Add a server URL and API key before reading Health data."
        case .noData: return "No Health data was available for this attempt."
        case .sending: return "The selected channels are being uploaded."
        case .accepted: return "The server accepted the upload; processing is not confirmed."
        case .partial: return "One channel was accepted while another needs attention."
        case .retryPending: return "Incomplete work is saved for a later attempt."
        case .error: return "The latest attempt needs attention before it can continue."
        case .disabled: return "This sync channel is disabled in Settings."
        }
    }

    private func failureTitle(_ code: SyncFailure.Code) -> LocalizedStringKey {
        switch code {
        case .configuration: return "Check connection settings"
        case .authorization: return "Health access required"
        case .transport: return "Connection failed"
        case .rejectedAck: return "Server rejected the upload"
        case .partialAck: return "Upload was only partly accepted"
        case .statePersistence: return "Progress could not be saved"
        case .healthData: return "Health data could not be read"
        case .locked: return "Device is locked"
        case .cancelled: return "Sync was cancelled"
        }
    }

    private func badgeStatus(_ status: SyncStatus) -> DSStatusBadge.Status {
        switch status {
        case .accepted: return .good
        case .sending, .partial, .retryPending: return .warn
        case .error: return .danger
        case .notConfigured, .noData, .disabled: return .neutral
        }
    }

    private func statusColor(_ status: SyncStatus) -> Color {
        switch badgeStatus(status) {
        case .good: return .dsGood
        case .warn: return .dsWarn
        case .danger: return .dsDanger
        case .neutral: return .dsTextSecondary
        }
    }
}

/// Shared stale-data banner for dashboard pages that retain the last good
/// server response after a later refresh fails.
struct SyncRefreshBanner: View {
    let message: String
    let lastLoadedAt: Date?
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: .dsSpacingSm) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(Color.dsWarn)
            VStack(alignment: .leading, spacing: .dsSpacingXs) {
                Text("Refresh failed")
                    .font(.dsBodySm.weight(.medium))
                    .foregroundStyle(Color.dsText)
                Text(verbatim: message)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let lastLoadedAt {
                    Text("Last updated \(lastLoadedAt, style: .relative)")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }
            Spacer(minLength: 0)
            Button("Retry", action: retry)
                .font(.dsBodySm.weight(.medium))
                .foregroundStyle(Color.dsAccent)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.dsSpacing)
        .background(Color.dsWarnBg)
        .clipShape(RoundedRectangle(cornerRadius: .dsRadius))
    }
}

#Preview {
    SyncStatusView()
}
