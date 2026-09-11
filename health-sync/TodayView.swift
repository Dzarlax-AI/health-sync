import SwiftUI

struct TodayView: View {
    @Binding var selection: TabSelection

    @AppStorage("serverURL") private var serverURL = ""
    private let syncEngine = SyncEngine.shared
    @State private var briefing: BriefingResponse?
    @State private var history: [ReadinessPoint] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var lastLoadedAt: Date?
    @State private var loadGeneration = UUID()
    @State private var aiBriefing = TodayAIBriefingController()
    @State private var todayInsights = TodayInsightsController()

    // Which stress-flag chip is currently expanded (tap-to-reveal-description).
    // nil = no description shown. Tapping the same chip again collapses it;
    // tapping another swaps. Lives on TodayView so expanded state survives
    // re-renders driven by AI-briefing polls.
    @State private var expandedStressFlag: String?

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                let contentWidth = max(0, viewport.size.width - (2 * .dsSpacing))
                ZStack(alignment: .top) {
                    TodayMorningBackdrop()
                        .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                        .ignoresSafeArea(edges: .top)

                    ScrollView {
                        VStack(spacing: .dsSpacingLg) {
                            if let loadError, briefing != nil {
                                SyncRefreshBanner(message: loadError, lastLoadedAt: lastLoadedAt) {
                                    Task { await load() }
                                }
                                .frame(width: contentWidth)
                            }
                            content(width: contentWidth)
                        }
                        .frame(width: contentWidth, alignment: .leading)
                        .padding(.top, .dsSpacingXl)
                        .padding(.bottom, .dsTabBarClearance)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await load() }
        }
        .task {
            syncEngine.refreshConfiguration()
            await load()
        }
        .onChange(of: serverURL) {
            // A new endpoint must not inherit the previous account's cached
            // dashboard while the first response for this endpoint loads.
            briefing = nil
            history = []
            aiBriefing.reset()
            todayInsights.reset()
            loadError = nil
            lastLoadedAt = nil
            syncEngine.refreshConfiguration()
            Task { await load() }
        }
        .onDisappear {
            aiBriefing.cancelPolling()
            todayInsights.cancelPolling()
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let briefing {
            TodayPageHeader(
                date: briefing.date,
                syncStatus: visibleSyncStatus,
                openSyncStatus: { selection = .settings }
            )
                .frame(width: width, alignment: .leading)
            TodayHeroBlock(
                briefing: briefing,
                history: history,
                expandedStressFlag: $expandedStressFlag,
                contentWidth: width,
                selection: $selection,
                aiResponse: aiBriefing.response,
                aiGenerating: aiBriefing.generating,
                todayInsights: todayInsights.response
            )
            if let alerts = briefing.alerts, !alerts.isEmpty {
                TodayAlertsBlock(alerts: alerts)
                    .frame(width: width)
            }
            if let todaySnapshot = todayInsights.response, !todaySnapshot.domains.isEmpty {
                TodayInsightsDomainsBlock(snapshot: todaySnapshot, selection: $selection)
                    .frame(width: width)
            }
            if todayInsights.response == nil, briefing.dailyDecision == nil, !aiBriefing.disabled {
                TodayAIInsightBlock(
                    response: aiBriefing.response,
                    generating: aiBriefing.generating
                )
                .frame(width: width)
            }
            if todayInsights.response?.domains.isEmpty != false,
               let sections = briefing.sections, !sections.isEmpty {
                TodayOverviewBlock(sections: sections, selection: $selection)
                    .frame(width: width)
            }
        } else if isLoading {
            TodayLoadingState()
                .frame(width: width)
        } else if visibleSyncStatus == .notConfigured {
            VStack(spacing: .dsSpacingSm) {
                TodayEmptyState(message: "Connect a server to see your health data.", isError: false)
                Button("Connect server", systemImage: "server.rack") {
                    selection = .settings
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .accessibilityIdentifier("today-connect-server")
            }
            .frame(width: width)
        } else if SyncUIFixtures.state != nil {
            // Dashboard requests are deliberately disabled in UI tests so a
            // fixture never reads real credentials or reaches the network.
            // Still render the status entry point: these tests exercise the
            // sync state, not the dashboard data source.
            TodayPageHeader(
                date: "",
                syncStatus: visibleSyncStatus,
                openSyncStatus: { selection = .settings }
            )
            .frame(width: width, alignment: .leading)
        } else if let loadError {
            TodayEmptyState(message: LocalizedStringKey(loadError), isError: true)
                .frame(width: width)
        } else {
            TodayEmptyState(message: "No data yet. Pull to refresh.", isError: false)
                .frame(width: width)
        }
    }

    private func load() async {
        let requestGeneration = UUID()
        loadGeneration = requestGeneration
        isLoading = true
        loadError = nil
        async let briefingTask = ServerClient.shared.healthBriefing()
        async let historyTask = ServerClient.shared.readinessHistory(days: 30)
        async let aiTask: AIBriefingResponse? = try? ServerClient.shared.aiBriefing()
        async let todayInsightsTask: TodayInsightsResponse? = try? ServerClient.shared.todayInsights()

        do {
            let (briefing, history) = try await (briefingTask, historyTask)
            guard !Task.isCancelled, requestGeneration == loadGeneration else { return }
            self.briefing = briefing
            self.history = history
            self.lastLoadedAt = Date()
        } catch {
            guard !Task.isCancelled, requestGeneration == loadGeneration else { return }
            self.loadError = error.localizedDescription
        }

        // AI is independent: a cold Gemini cache or AI endpoint failure must
        // not block the rest of the Today view.
        if let ai = await aiTask,
           !Task.isCancelled,
           requestGeneration == loadGeneration {
            aiBriefing.apply(ai)
        }
        if let snapshot = await todayInsightsTask,
           !Task.isCancelled,
           requestGeneration == loadGeneration {
            todayInsights.apply(snapshot)
        }
        if requestGeneration == loadGeneration {
            aiBriefing.schedulePollingIfNeeded(for: self.briefing?.dailyDecision?.id)
            todayInsights.schedulePollingIfNeeded()
        }
        if requestGeneration == loadGeneration {
            isLoading = false
        }
    }

    private var visibleSyncStatus: SyncStatus {
        SyncUIFixtures.state?.status ?? syncEngine.status
    }
}

#Preview {
    TodayView(selection: .constant(.today))
}

private struct TodayLoadingState: View {
    var body: some View {
        VStack(spacing: .dsSpacingLg) {
            VStack(alignment: .leading, spacing: .dsSpacing) {
                skeletonLine(width: 118, height: 14)
                skeletonLine(width: 190, height: 34)
                skeletonLine(width: nil, height: 12)
                skeletonLine(width: 240, height: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.dsSpacing)
            .dsCard()

            HStack(spacing: .dsSpacingSm) {
                skeletonCard()
                skeletonCard()
            }

            VStack(spacing: .dsSpacingSm) {
                skeletonLine(width: nil, height: 12)
                skeletonLine(width: nil, height: 12)
                skeletonLine(width: 220, height: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.dsSpacing)
            .dsCard()
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your health data")
    }

    private func skeletonCard() -> some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            skeletonLine(width: 72, height: 12)
            skeletonLine(width: 94, height: 22)
            skeletonLine(width: 116, height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dsSpacing)
        .dsCard()
    }

    private func skeletonLine(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.dsSurface2)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}
