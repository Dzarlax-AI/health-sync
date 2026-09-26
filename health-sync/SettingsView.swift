import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("health-sync.config-revision") private var configRevision = 0
    @AppStorage("backgroundSync") private var backgroundSync = true
    @AppStorage("syncOnLaunch") private var syncOnLaunch = true
    @AppStorage("notifyOnSync") private var notifyOnSync = false
    @AppStorage("syncIntervalMinutes") private var syncIntervalMinutes = 15
    @AppStorage("syncVitals") private var syncVitals = true
    @AppStorage("syncActivity") private var syncActivity = true
    @AppStorage("syncSleep") private var syncSleep = true
    @AppStorage("syncOther") private var syncOther = true
    @AppStorage("syncWorkouts") private var syncWorkouts = true
    @AppStorage("workoutHRTimeline") private var workoutHRTimeline = true
    @AppStorage("workoutGPS") private var workoutGPS = false

    @State private var apiKey = KeychainStore.apiKey ?? ""
    @State private var connectionState: ConnectionState = .idle
    @State private var account: UserSettings?
    @State private var showServerDetails = false
    @State private var connectionProbeID = UUID()
    @State private var appliedServerEndpoint: String?

    private let engine = SyncEngine.shared

    private var visibleSyncState: SyncUIState {
        SyncUIFixtures.state ?? engine.uiState
    }

    enum ConnectionState {
        case idle, testing, ok, failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: .dsSpacingLg) {
                    serverSection
                    syncStatusSection
                    accountSection
                    syncSection
                    BackgroundDiagnosticsView()
                    metricsSection
                    workoutsSection
                }
                .padding(.dsSpacing)
                .padding(.bottom, .dsTabBarClearance)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Color.dsBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .task {
                appliedServerEndpoint = normalizedServerURL?.absoluteString
                applyBackgroundSyncSetting()
                await loadAccount()
            }
            .onChange(of: serverURL) { _, _ in
                resetConnectionState()
            }
            .onChange(of: backgroundSync) { applyBackgroundSyncSetting() }
            .onChange(of: syncOnLaunch) { engine.refreshConfiguration() }
            .onChange(of: syncIntervalMinutes) { applyBackgroundSyncSetting() }
            .onChange(of: syncVitals) { engine.refreshConfiguration() }
            .onChange(of: syncActivity) { engine.refreshConfiguration() }
            .onChange(of: syncSleep) { engine.refreshConfiguration() }
            .onChange(of: syncOther) { engine.refreshConfiguration() }
            .onChange(of: syncWorkouts) { engine.refreshConfiguration() }
            .onChange(of: workoutHRTimeline) { engine.refreshConfiguration() }
        }
    }

    // MARK: - Account

    /// Compact identity block — confirms which user / tenant the API key
    /// resolves to on the server, so a wrong key doesn't silently route
    /// to someone else's data. Read-only; everything is managed on the web.
    @ViewBuilder
    private var accountSection: some View {
        if let account {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Account")
                VStack(alignment: .leading, spacing: 0) {
                    if let username = account.username, !username.isEmpty {
                        accountRow(label: "Logged in as", value: username,
                                   trailing: account.isAdmin == true ? "admin" : nil)
                    }
                    if let tenant = account.tenant, !tenant.isEmpty,
                       tenant != account.username {
                        Divider().padding(.leading, .dsSpacing)
                        accountRow(label: "Tenant", value: tenant, trailing: nil)
                    }
                    if let timezone = account.timezone, !timezone.isEmpty {
                        Divider().padding(.leading, .dsSpacing)
                        accountRow(label: "Time zone", value: timezone, trailing: nil)
                    }
                    if let reportLang = account.reportLang, !reportLang.isEmpty {
                        Divider().padding(.leading, .dsSpacing)
                        accountRow(label: "Report language", value: reportLang, trailing: nil)
                    }
                }
            }
            .dsCard()
        }
    }

    private func accountRow(label: LocalizedStringKey, value: String, trailing: String?) -> some View {
        let visibleTrailing = trailing == value ? nil : trailing
        return HStack(spacing: .dsSpacing) {
            Text(label)
                .font(.dsBody)
                .foregroundStyle(Color.dsText)
            Spacer()
            Text(value)
                .font(.dsMono)
                .foregroundStyle(Color.dsTextSecondary)
            if let trailing = visibleTrailing {
                Text(trailing)
                    .font(.dsCaption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.dsAccent.opacity(0.10))
                    .foregroundStyle(Color.dsAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, 12)
    }

    private func loadAccount(expectedProbeID: UUID? = nil) async {
        let requestURL = serverURL
        let requestKey = apiKey
        let loaded = try? await ServerClient.shared.userSettings()
        // Do not apply an answer for a previous endpoint/key to the current
        // settings screen after the user switches accounts.
        guard requestURL == serverURL, requestKey == apiKey,
              expectedProbeID == nil || expectedProbeID == connectionProbeID else { return }
        account = loaded
    }

    // MARK: - Sync status

    private var syncStatusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "HealthKit upload")

            VStack(alignment: .leading, spacing: .dsSpacing) {
                HStack(alignment: .top, spacing: .dsSpacing) {
                    Text("Upload status")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                    Spacer(minLength: 0)
                    syncStatusBadge
                }

                channelReceiptRow(title: "Metrics", channel: visibleSyncState.metrics, isWorkout: false)
                channelReceiptRow(title: "Workouts", channel: visibleSyncState.workouts, isWorkout: true)

                syncAction

                if let error = engine.lastError {
                    HStack(alignment: .top, spacing: .dsSpacingSm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.dsDanger)
                        Text(error)
                            .font(.dsBodySm)
                            .foregroundStyle(Color.dsDanger)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, .dsSpacing)
            .padding(.top, .dsSpacingSm)
            .padding(.bottom, .dsSpacing)

            // Recent activity row: full-width tappable list-style row with
            // a divider above so it reads as an action, not floating text.
            Divider()
            NavigationLink(destination: SyncStatusView(onConfigure: openServerDetailsFromStatus)) {
                HStack(spacing: .dsSpacing) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Color.dsTextSecondary)
                        .frame(width: 20)
                    Text("Recent activity & re-sync")
                        .font(.dsBody)
                        .foregroundStyle(Color.dsText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color.dsTextTertiary)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, .dsSpacing)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sync-status-details")
        }
        .dsCard()
    }

    @ViewBuilder
    private var syncStatusBadge: some View {
        DSStatusBadge(text: settingsStatusBadge(visibleSyncState.status),
                      status: settingsBadgeStatus(visibleSyncState.status))
    }

    private func channelReceiptRow(title: LocalizedStringKey,
                                   channel: SyncChannelSnapshot,
                                   isWorkout: Bool) -> some View {
        HStack(alignment: .top, spacing: .dsSpacingSm) {
            VStack(alignment: .leading, spacing: .dsSpacingXs) {
                Text(title)
                    .font(.dsBodySm.weight(.medium))
                    .foregroundStyle(Color.dsText)
                if let acceptedAt = channel.lastAcceptedAt {
                    Text("Last accepted")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                    Text(acceptedAt, style: .relative)
                        .font(.dsBodySm)
                        .foregroundStyle(Color.dsTextSecondary)
                } else {
                    Text("Never accepted")
                        .font(.dsBodySm)
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }
            Spacer(minLength: 0)
            if channel.acceptedCount > 0 {
                Text(uploadCount(channel.acceptedCount, isWorkout: isWorkout))
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
        }
        .padding(.vertical, .dsSpacingXs)
    }

    private func uploadCount(_ count: Int, isWorkout: Bool) -> String {
        let key = isWorkout ? "%lld workouts" : "%lld samples"
        return String.localizedStringWithFormat(NSLocalizedString(key, comment: "Accepted upload volume by channel"), count)
    }

    @ViewBuilder
    private var syncAction: some View {
        Group {
            switch visibleSyncState.primaryAction {
            case .configure:
                Button("Connect server", systemImage: "server.rack") {
                    showServerDetails = true
                }
            case .sync:
                Button(engine.isSyncing ? "Syncing…" : "Sync now",
                       systemImage: "arrow.trianglehead.2.clockwise") {
                    Task { _ = await engine.syncNow() }
                }
                .disabled(engine.isSyncing || !visibleSyncState.canSync)
            case .retry:
                Button(engine.isSyncing ? "Retrying…" : "Retry",
                       systemImage: "arrow.clockwise") {
                    Task { _ = await engine.retryNow() }
                }
                .disabled(engine.isSyncing || !visibleSyncState.canSync)
            }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(DSPrimaryButtonStyle())
    }

    private func settingsStatusBadge(_ status: SyncStatus) -> LocalizedStringKey {
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

    private func settingsBadgeStatus(_ status: SyncStatus) -> DSStatusBadge.Status {
        switch status {
        case .accepted: return .good
        case .sending, .partial, .retryPending: return .warn
        case .error: return .danger
        case .notConfigured, .noData, .disabled: return .neutral
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Server connection")

            VStack(alignment: .leading, spacing: .dsSpacing) {
                HStack(alignment: .top, spacing: .dsSpacing) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(serverSummaryTitle)
                            .font(.dsBody)
                            .foregroundStyle(Color.dsText)
                        Text(serverSummarySubtitle)
                            .font(.dsCaption)
                            .foregroundStyle(Color.dsTextTertiary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    connectionBadge
                }

                DisclosureGroup(isExpanded: $showServerDetails) {
                    VStack(spacing: .dsSpacingSm) {
                        DSTextField(label: "URL", placeholder: "https://health.example.com", text: $serverURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .onSubmit(commitServerConfiguration)

                        DSSecureField(label: "API Key", placeholder: "your-secret-key", text: $apiKey)
                            .onChange(of: apiKey) { _, new in
                                do {
                                    try KeychainStore.shared.write(new)
                                    invalidateConnection()
                                } catch {
                                    connectionState = .failed(String(localized: "Unable to save API key"))
                                }
                            }

                        HStack {
                            Button(action: testConnection) {
                                Label("Test connection", systemImage: "network")
                            }
                            .buttonStyle(DSSecondaryButtonStyle())

                            Spacer()
                        }
                        .padding(.horizontal, .dsSpacing)
                        .padding(.top, .dsSpacingXs)
                    }
                    .padding(.top, .dsSpacingSm)
                } label: {
                    Text("Connection details")
                        .font(.dsBodySm.weight(.medium))
                        .foregroundStyle(Color.dsText)
                }
                .tint(Color.dsTextSecondary)
            }
            .padding(.horizontal, .dsSpacing)
            .padding(.top, .dsSpacingSm)
            .padding(.bottom, .dsSpacing)
        }
        .dsCard()
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            SectionHeader(title: "Background sync")

            VStack(spacing: 0) {
                DSToggleRow(label: "Background sync", isOn: $backgroundSync)
                Divider().padding(.leading, .dsSpacing)
                DSToggleRow(label: "Sync on launch", isOn: $syncOnLaunch)
                Divider().padding(.leading, .dsSpacing)
                DSPickerRow(
                    label: "Sync frequency",
                    selection: $syncIntervalMinutes,
                    options: [
                        (1,   "Every 1 min"),
                        (15,  "Every 15 min"),
                        (30,  "Every 30 min"),
                        (60,  "Every hour"),
                        (180, "Every 3 hours"),
                        (360, "Every 6 hours"),
                    ]
                )
                Text("Foreground checks follow this interval when the app is open; iOS may delay background work.")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, .dsSpacing)
                    .padding(.vertical, .dsSpacingSm)
                Divider().padding(.leading, .dsSpacing)
                DSToggleRow(
                    label: "Notify on sync",
                    subtitle: "Local push after each successful sync",
                    isOn: Binding(
                        get: { notifyOnSync },
                        set: { newValue in
                            if newValue {
                                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                                    DispatchQueue.main.async { notifyOnSync = granted }
                                }
                            } else {
                                notifyOnSync = false
                            }
                        }
                    )
                )
            }
        }
        .dsCard()
    }

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            SectionHeader(title: "Metrics")

            VStack(spacing: 0) {
                DSToggleRow(
                    label: "Vital signs",
                    subtitle: "Heart rate, HRV, SpO₂ and body signals",
                    color: .dsHeart,
                    isOn: $syncVitals
                )
                Divider().padding(.leading, .dsSpacing)
                DSToggleRow(
                    label: "Activity",
                    subtitle: "Steps, calories, distance and movement",
                    color: .dsActivity,
                    isOn: $syncActivity
                )
                Divider().padding(.leading, .dsSpacing)
                DSToggleRow(
                    label: "Sleep",
                    subtitle: "Sleep duration and stages",
                    color: .dsSleep,
                    isOn: $syncSleep
                )
                Divider().padding(.leading, .dsSpacing)
                DSToggleRow(
                    label: "Other metrics",
                    subtitle: "Cardio, body, environment and dietary data",
                    color: .dsCardio,
                    isOn: $syncOther
                )
            }
        }
        .dsCard()
    }

    private var workoutsSection: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            SectionHeader(title: "Workouts")

            VStack(spacing: 0) {
                DSToggleRow(label: "Sync workouts", isOn: $syncWorkouts)

                if syncWorkouts {
                    Divider().padding(.leading, .dsSpacing)
                    DSToggleRow(
                        label: "Heart rate timeline",
                        subtitle: "Per-minute HR during workout",
                        isOn: $workoutHRTimeline
                    )
                    Divider().padding(.leading, .dsSpacing)
                    DSToggleRow(
                        label: "GPS route",
                        subtitle: "Increases payload size",
                        isOn: $workoutGPS
                    )
                }
            }
        }
        .dsCard()
    }

    // MARK: - Connection test

    @ViewBuilder
    private var connectionBadge: some View {
        switch connectionState {
        case .idle:
            if isServerConfigured {
                DSStatusBadge(text: "Configured", status: .neutral)
            } else {
                DSStatusBadge(text: "Missing", status: .warn)
            }
        case .testing:
            ProgressView().scaleEffect(0.8)
        case .ok:
            DSStatusBadge(text: "Connected", status: .good)
        case .failed(let msg):
            DSStatusBadge(verbatim: msg, status: .danger)
        }
    }

    private var normalizedServerURL: URL? {
        UserDefaultsSyncConfiguration.normalizedEndpoint(serverURL)
    }

    private var isServerConfigured: Bool {
        normalizedServerURL != nil
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var serverSummaryTitle: LocalizedStringKey {
        isServerConfigured ? "Dashboard API configured" : "Dashboard API not configured"
    }

    private var serverSummarySubtitle: String {
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "Add the server URL and API key to read dashboard data.")
        }
        guard let endpoint = normalizedServerURL else {
            return String(localized: "Invalid server URL")
        }
        let host = endpoint.host ?? endpoint.absoluteString
        let keyState = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "API key missing")
            : String(localized: "API key saved")
        return "\(host) · \(keyState)"
    }

    private func openServerDetailsFromStatus() {
        Task { @MainActor in
            await Task.yield()
            showServerDetails = true
        }
    }

    private func testConnection() {
        commitServerConfiguration()
        let requestURL = serverURL
        let requestKey = apiKey
        let requestProbeID = connectionProbeID
        connectionState = .testing
        Task {
            let result = await engine.testConnection()
            guard requestURL == serverURL, requestKey == apiKey,
                  requestProbeID == connectionProbeID else { return }
            switch result {
            case .accepted:
                connectionState = .ok
                await loadAccount(expectedProbeID: requestProbeID)
                // The app is already foregrounded after a user has verified
                // a new endpoint. Start the normal, opt-in launch sync here
                // instead of making a new account wait for the next scene
                // activation (or press a second button) before its one-time
                // sleep-history job can begin.
                if syncOnLaunch {
                    _ = await engine.syncNow(reason: .appActivation)
                }
            case .failed(let failure):
                connectionState = .failed(failure.message)
            }
        }
    }

    private func invalidateConnection() {
        resetConnectionState()
        configRevision &+= 1
        engine.refreshConfiguration()
    }

    private func resetConnectionState() {
        connectionState = .idle
        account = nil
        connectionProbeID = UUID()
    }

    /// Reload the app-wide client only when the effective endpoint changes.
    /// Editing a URL is intentionally local UI state until it is committed.
    private func commitServerConfiguration() {
        let endpoint = normalizedServerURL?.absoluteString
        guard endpoint != appliedServerEndpoint else { return }
        appliedServerEndpoint = endpoint
        invalidateConnection()
    }

    private func applyBackgroundSyncSetting() {
        engine.refreshConfiguration()
        BackgroundSyncManager.shared.applyConfiguration()
    }
}

// MARK: - Subviews

struct SectionHeader: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title)
            .font(.dsSubhead)
            .foregroundStyle(Color.dsText)
            .padding(.horizontal, .dsSpacing)
            .padding(.top, .dsSpacing)
    }
}

private struct DSTextField: View {
    let label: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
            TextField(placeholder, text: $text)
                .font(.dsBody)
                .foregroundStyle(Color.dsText)
                .accessibilityIdentifier("server-url-field")
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, .dsSpacingSm)
    }
}

private struct DSSecureField: View {
    let label: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
            SecureField(placeholder, text: $text)
                .font(.dsBody)
                .foregroundStyle(Color.dsText)
                .accessibilityIdentifier("server-api-key-field")
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, .dsSpacingSm)
    }
}

private struct DSPickerRow: View {
    let label: LocalizedStringKey
    @Binding var selection: Int
    let options: [(Int, LocalizedStringKey)]

    var body: some View {
        HStack {
            Text(label)
                .font(.dsBody)
                .foregroundStyle(Color.dsText)
            Spacer()
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { value, title in
                    Text(title).tag(value)
                }
            }
            .labelsHidden()
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, 12)
    }
}

private struct DSToggleRow: View {
    let label: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    /// Metric rows supply their semantic colour. Rows without one use the
    /// neutral accent treatment, including its inverted on-state thumb.
    var color: Color? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.dsBody)
                    .foregroundStyle(Color.dsText)
                if let subtitle {
                    Text(subtitle)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }
        }
        .toggleStyle(DSSwitchStyle(
            onColor: color ?? .dsAccent,
            thumbOnColor: color == nil ? .dsAccentForeground : .dsControlThumb
        ))
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, 12)
    }
}

/// Custom track colours are needed because iOS applies `.tint` to a native
/// switch's off-track. Keep the interaction a Button rather than a bare tap
/// gesture: it preserves an actionable accessibility element and announces
/// both the label and current state.
private struct DSSwitchStyle: ToggleStyle {
    let onColor: Color
    let thumbOnColor: Color

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer()
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? onColor : Color.dsSurface3)
                        .overlay(
                            Capsule().strokeBorder(
                                configuration.isOn ? Color.clear : Color.dsBorder,
                                lineWidth: 1
                            )
                        )
                    Circle()
                        .fill(configuration.isOn ? thumbOnColor : Color.dsControlThumb)
                        .shadow(color: Color.dsControlThumbShadow, radius: 2, y: 1)
                        .padding(2)
                }
                .frame(width: 51, height: 31)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

#Preview {
    SettingsView()
}
