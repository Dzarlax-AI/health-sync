import SwiftUI
import Charts

struct TodayView: View {
    @Binding var selection: TabSelection

    @State private var briefing: BriefingResponse?
    @State private var history: [ReadinessPoint] = []
    @State private var isLoading = false
    @State private var loadError: String?

    // AI briefing state — fetched independently from /api/ai-briefing so a
    // cold Gemini cache does not block the rest of the Today view. nil =
    // not fetched yet; "" + generating = server is regenerating; non-empty
    // = ready to render. `aiDisabled` hides the section entirely.
    /// Latest AI briefing payload. We store the whole response so the
    /// renderer can pick between the chunked fields (`sleep`/`yesterday`/
    /// `recovery`/`recommendation` — server PR #86) and the legacy
    /// combined `insight` text as fallback.
    @State private var aiResponse: AIBriefingResponse?
    @State private var aiGenerating: Bool = false
    @State private var aiDisabled: Bool = false
    @State private var aiPollTask: Task<Void, Never>? = nil

    // Which stress-flag chip is currently expanded (tap-to-reveal-description).
    // nil = no description shown. Tapping the same chip again collapses it;
    // tapping another swaps. Lives on TodayView because the chips live inside
    // a per-build hero card and we want the expanded state to persist across
    // re-renders driven by AI-briefing polls.
    @State private var expandedStressFlag: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: .dsSpacingLg) {
                    if let b = briefing {
                        heroBlock(b)
                        if let cards = b.metricCards, !cards.isEmpty {
                            atAGlanceBlock(cards: cards)
                        }
                        if let alerts = b.alerts, !alerts.isEmpty {
                            alertsBlock(alerts)
                        }
                        if !aiDisabled {
                            aiInsightBlock(aiResponse, generating: aiGenerating)
                        }
                        if let sections = b.sections, !sections.isEmpty {
                            overviewBlock(sections: sections)
                        }
                    } else if isLoading {
                        ProgressView().padding(.top, 40)
                    } else if let err = loadError {
                        emptyState(message: LocalizedStringKey(err), isError: true)
                    } else {
                        emptyState(message: "No data yet. Pull to refresh.", isError: false)
                    }
                }
                .padding(.dsSpacing)
            }
            .background(Color.dsBackground)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
        }
        .task { await load() }
        .onDisappear { aiPollTask?.cancel(); aiPollTask = nil }
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        loadError = nil
        async let briefingTask = ServerClient.shared.healthBriefing()
        async let historyTask = ServerClient.shared.readinessHistory(days: 30)
        async let aiTask: AIBriefingResponse? = try? ServerClient.shared.aiBriefing()
        do {
            let (b, h) = try await (briefingTask, historyTask)
            self.briefing = b
            self.history = h
        } catch {
            self.loadError = error.localizedDescription
        }
        // AI is independent — even if briefing failed, render what we have.
        if let ai = await aiTask {
            applyAI(ai)
            scheduleAIPolling()
        }
        isLoading = false
    }

    /// Update local AI state from a server response. We only overwrite
    /// `aiResponse` when the new payload carries non-empty content so a
    /// polling tick that races a cold cache flush doesn't replace a
    /// populated render with an empty one.
    private func applyAI(_ r: AIBriefingResponse) {
        aiDisabled = r.disabled
        aiGenerating = r.generating
        if aiHasContent(r) {
            aiResponse = r
        }
    }

    private func aiHasContent(_ r: AIBriefingResponse) -> Bool {
        !r.insight.isEmpty
            || !(r.sleep ?? "").isEmpty
            || !(r.yesterday ?? "").isEmpty
            || !(r.recovery ?? "").isEmpty
            || !(r.recommendation ?? "").isEmpty
    }

    /// Poll /api/ai-briefing while the server reports a regen in flight and
    /// the cache is still empty. Stops on first non-empty insight or after
    /// 5 minutes (10 ticks × 30 s) so we don't loop forever on a stuck regen.
    private func scheduleAIPolling() {
        aiPollTask?.cancel()
        let alreadyHaveContent = aiResponse.map(aiHasContent) ?? false
        guard !alreadyHaveContent, !aiDisabled, aiGenerating else { return }
        aiPollTask = Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { return }
                guard let r = try? await ServerClient.shared.aiBriefing() else { continue }
                applyAI(r)
                let haveContent = aiResponse.map(aiHasContent) ?? false
                if haveContent || aiDisabled { return }
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroBlock(_ b: BriefingResponse) -> some View {
        let score = b.readinessToday ?? b.readinessScore ?? 0
        VStack(alignment: .leading, spacing: .dsSpacing) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Readiness today")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                    Text(score > 0 ? "\(score)" : "--")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(readinessColor(band: b.readinessTodayBand ?? b.readinessBand,
                                                        score: score))
                    readinessDisplay(b, score: score)
                        .font(.dsBodySm)
                        .foregroundStyle(Color.dsTextSecondary)
                }
                Spacer()
                if !history.isEmpty {
                    sparkline.frame(width: 120, height: 56)
                }
            }

            if let h = b.headline {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(severityColor(h.severity)).frame(width: 8, height: 8)
                        Text(h.title).font(.dsSubhead).foregroundStyle(Color.dsText)
                    }
                    if !h.detail.isEmpty {
                        Text(h.detail).font(.dsBodySm).foregroundStyle(Color.dsTextSecondary)
                    }
                }
            }

            if let tip = b.readinessTip, !tip.isEmpty {
                Text(tip).font(.dsBodySm).foregroundStyle(Color.dsTextSecondary)
            }

            if let e = b.energyBank {
                energyView(e)
            }
        }
        .padding(.dsSpacing)
        .dsCard()
    }

    private var sparkline: some View {
        Chart(history) { p in
            LineMark(
                x: .value("Date", p.date),
                y: .value("Score", p.score)
            )
            .foregroundStyle(Color.dsAccent)
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...100)
    }

    @ViewBuilder
    private func energyView(_ e: EnergyBank) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Title is server-localized via `verdict_label` (PR #84);
                // fall back to the raw key only for older servers. Colour
                // stays keyed by the stable `action_verdict` enum.
                verdictDisplay(e)
                    .font(.dsBodySm.weight(.semibold))
                    .foregroundStyle(verdictColor(e.actionVerdict))
                Spacer()
                Text("\(e.current)/\(e.capacity)")
                    .font(.dsMono)
                    .foregroundStyle(Color.dsTextSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.dsTextTertiary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(verdictColor(e.actionVerdict))
                        .frame(width: geo.size.width * CGFloat(max(0, min(100, e.current))) / 100.0)
                }
            }
            .frame(height: 8)
            if !e.verdictReason.isEmpty {
                Text(e.verdictReason)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextTertiary)
            }
            if let details = e.flagDetails, !details.isEmpty {
                stressFlagChips(details)
            }
        }
    }

    /// Renders the multi-channel stress flags as colour-coded chips
    /// under the hero verdict (mirrors dashboard PR #64). Text comes
    /// from the server's pre-localized `flag_details` (PR #84); the
    /// chip's visual style — colour, dashed border — is keyed off
    /// `key` by `stressFlagStyle(_:)` because that's a design
    /// decision, not a translation.
    ///
    /// `imputed_*` flags are filtered out because the Today card
    /// surfaces them through the dedicated imputed-inputs banner.
    /// Entries with empty `label` are also dropped — that's the
    /// server's signal that no i18n key exists for the flag (e.g. a
    /// brand-new server-only diagnostic flag without translation yet).
    ///
    /// Horizontally scrollable so 4+ simultaneous flags don't truncate
    /// on narrower iPhone widths.
    @ViewBuilder
    private func stressFlagChips(_ details: [FlagDetail]) -> some View {
        let visible = details.filter {
            !$0.key.hasPrefix("imputed_") && !$0.label.isEmpty
        }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(visible) { detail in
                            stressFlagChip(detail)
                        }
                    }
                }
                if let expanded = expandedStressFlag,
                   let match = visible.first(where: { $0.key == expanded }) {
                    Text(match.description)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func stressFlagChip(_ detail: FlagDetail) -> some View {
        let style = stressFlagStyle(detail.key)
        return Text(detail.label)
            .font(.dsCaption.weight(.medium))
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(style.background)
            )
            .overlay(
                Capsule().strokeBorder(
                    style.foreground.opacity(0.4),
                    style: style.isDashed
                        ? StrokeStyle(lineWidth: 1, dash: [3, 2])
                        : StrokeStyle(lineWidth: 0)
                )
            )
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.snappy) {
                    expandedStressFlag = (expandedStressFlag == detail.key) ? nil : detail.key
                }
            }
            .accessibilityLabel(detail.label)
            .accessibilityHint(detail.description)
            // VoiceOver: `.onTapGesture` alone doesn't announce the
            // element as actionable; without the button trait users
            // hear only the label and have no idea a double-tap will
            // do anything. CodeRabbit review on PR #12.
            .accessibilityAddTraits(.isButton)
    }

    private struct StressFlagStyle {
        let foreground: Color
        let background: Color
        let isDashed: Bool
    }

    /// Colour-codes a stress flag per dashboard PR #64's chip palette:
    ///   - safety-critical (force rest)   → danger
    ///   - load-suppresses-push           → warn
    ///   - interpretation only            → cardio (informational blue)
    ///   - HR-derived diagnostics         → tertiary neutral
    ///   - operational state / warmup     → tertiary with dashed border
    /// Unknown flag keys fall to the neutral diagnostic style so future
    /// server-side additions render with correct text from
    /// `flag_details.label` and a generic-but-visible chip.
    private func stressFlagStyle(_ key: String) -> StressFlagStyle {
        switch key {
        case "illness_signature":
            return .init(foreground: .dsDanger, background: .dsDangerBg, isDashed: false)
        case "recovery_debt":
            return .init(foreground: .dsWarn, background: .dsWarnBg, isDashed: false)
        case "parasympathetic_rebound":
            return .init(foreground: .dsCardio, background: .dsCardio.opacity(0.12), isDashed: false)
        case "stale_stress", "calibration_warmup":
            return .init(foreground: .dsTextTertiary, background: Color.clear, isDashed: true)
        default:
            return .init(foreground: .dsTextSecondary, background: Color.dsSurface2.opacity(0.6), isDashed: false)
        }
    }

    // MARK: - At a glance (cards grid)

    @ViewBuilder
    private func atAGlanceBlock(cards: [MetricCard]) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            SectionHeader(title: "At a glance")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: .dsSpacingSm),
                                GridItem(.flexible(), spacing: .dsSpacingSm)],
                      spacing: .dsSpacingSm) {
                ForEach(cards) { card in
                    if card.metric.hasPrefix("sleep_") {
                        // Sleep is a composite: stage breakdown lives in the
                        // dedicated Sleep tab, not in a single-metric chart.
                        Button { selection = .sleep } label: {
                            metricCardView(card)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(destination: MetricDetailView(
                            metric: card.metric,
                            displayName: card.name
                        )) {
                            metricCardView(card)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metricCardView(_ card: MetricCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.name)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(card.value)
                    .font(.dsHeading)
                    .foregroundStyle(Color.dsText)
                Text(card.unit)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextTertiary)
            }
            HStack(spacing: 6) {
                if let l = card.trend7dLabel, !l.isEmpty {
                    trendChip(l, status: card.trend7dStatus)
                }
                if let l = card.trend30dLabel, !l.isEmpty {
                    trendChip(l, status: card.trend30dStatus, secondary: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dsSpacingSm)
        .dsCard()
    }

    private func trendChip(_ label: String, status: String?, secondary: Bool = false) -> some View {
        Text(label)
            .font(.dsCaption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(trendColor(status).opacity(secondary ? 0.10 : 0.18))
            .foregroundStyle(trendColor(status))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Alerts

    private func alertsBlock(_ alerts: [Alert]) -> some View {
        VStack(spacing: .dsSpacingSm) {
            ForEach(alerts, id: \.text) { a in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: a.severity == "critical"
                          ? "exclamationmark.triangle.fill"
                          : "exclamationmark.circle.fill")
                        .foregroundStyle(a.severity == "critical" ? Color.dsDanger : Color.dsWarn)
                    Text(a.text)
                        .font(.dsBodySm)
                        .foregroundStyle(Color.dsText)
                    Spacer(minLength: 0)
                }
                .padding(.dsSpacingSm)
                .dsCard()
            }
        }
    }

    // MARK: - AI Insight

    @ViewBuilder
    private func aiInsightBlock(_ r: AIBriefingResponse?, generating: Bool) -> some View {
        if let r, aiHasContent(r) {
            aiInsightExpanded(r)
        } else {
            // Cache cold — show a placeholder so the user knows the section
            // exists and an update is on the way. Polling drives the
            // transition to the populated state without a manual refresh.
            HStack(spacing: 10) {
                if generating {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.dsAccent)
                Text(generating
                     ? "AI is preparing today's briefing…"
                     : "AI briefing not available yet.")
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(.dsSpacing)
            .dsCard()
        }
    }

    private func aiInsightExpanded(_ r: AIBriefingResponse) -> some View {
        // Render the four server-pre-chunked blocks (PR #86) in fixed
        // order: Sleep → Yesterday → Recovery → Recommendation. Each is
        // optional and only rendered when non-empty, so partial cache
        // states don't paint empty cards. The legacy combined `insight`
        // text is the final fallback — used only when all four blocks
        // are empty (e.g. an older server, or a generation run that
        // produced no recognised headers and only emits the raw blob).
        let sleep          = r.sleep ?? ""
        let yesterday      = r.yesterday ?? ""
        let recovery       = r.recovery ?? ""
        let recommendation = r.recommendation ?? ""
        let anyChunked = !sleep.isEmpty || !yesterday.isEmpty
            || !recovery.isEmpty || !recommendation.isEmpty
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: .dsSpacing) {
                if anyChunked {
                    if !sleep.isEmpty {
                        aiBlock(icon: "moon.zzz", title: "Sleep",
                                tint: .dsSleep, body: sleep)
                    }
                    if !yesterday.isEmpty {
                        aiBlock(icon: "clock.arrow.circlepath", title: "Yesterday",
                                tint: .dsActivity, body: yesterday)
                    }
                    if !recovery.isEmpty {
                        aiBlock(icon: "leaf.fill", title: "Recovery",
                                tint: .dsCardio, body: recovery)
                    }
                    if !recommendation.isEmpty {
                        aiBlock(icon: "sparkles", title: "Recommendation",
                                tint: .dsAccent, body: recommendation)
                    }
                } else {
                    // Server's combined-text fallback. Used for old
                    // servers (pre-PR-#86) and LLM runs where the
                    // server-side chunker didn't recognise headers.
                    Text(r.insight)
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, .dsSpacingSm)
        } label: {
            Label("AI Insight", systemImage: "sparkles")
                .font(.dsSubhead)
                .foregroundStyle(Color.dsText)
        }
        .padding(.dsSpacing)
        .dsCard()
    }

    private func aiBlock(icon: String, title: LocalizedStringKey,
                         tint: Color, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.dsBodySm.weight(.semibold))
                    .foregroundStyle(Color.dsText)
                    .textCase(.uppercase)
            }
            Text(body)
                .font(.dsBodySm)
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Health overview

    @ViewBuilder
    private func overviewBlock(sections: [BriefingSection]) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            SectionHeader(title: "Health overview")
            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { idx, s in
                    if idx > 0 { Divider().padding(.leading, .dsSpacing) }
                    sectionLink(s)
                }
            }
            .dsCard()
        }
    }

    /// Sleep has a dedicated tab with stage breakdown — jump there. The
    /// other sections push into SectionDetailView (rich page with summary,
    /// KPIs, charts, and "How it works" explainers).
    @ViewBuilder
    private func sectionLink(_ s: BriefingSection) -> some View {
        if s.key == "sleep" {
            Button { selection = .sleep } label: { sectionRow(s) }
                .buttonStyle(.plain)
        } else {
            NavigationLink(destination: SectionDetailView(sectionKey: s.key)) {
                sectionRow(s)
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionRow(_ s: BriefingSection) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            // Header: title + status badge, chevron on the trailing edge.
            HStack(spacing: .dsSpacingSm) {
                Text(s.title)
                    .font(.dsSubhead)
                    .foregroundStyle(Color.dsText)
                sectionStatusBadge(s)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.dsTextTertiary)
                    .font(.system(size: 13, weight: .semibold))
            }

            // Summary spans full width — long enough to wrap cleanly without
            // fighting the chevron column.
            if !s.summary.isEmpty {
                Text(s.summary)
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Detail chips: trend dot · label (bold) · value (trailing) ·
            // optional note on second line. Mirrors the web `.insight-detail`
            // pill so the visual hierarchy matches.
            if let details = s.details, !details.isEmpty {
                VStack(spacing: 6) {
                    ForEach(details.prefix(3), id: \.self) { d in
                        detailChip(d)
                    }
                }
            }
        }
        .padding(.dsSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailChip(_ d: BriefingDetail) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(trendDotColor(d.trend))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(d.label)
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(Color.dsText)
                    Spacer(minLength: 0)
                    Text(d.value)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsText)
                        .monospacedDigit()
                }
                if let n = d.note, !n.isEmpty {
                    Text(n)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsTextTertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSurface2.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func trendDotColor(_ trend: String?) -> Color {
        switch trend {
        case "up":     return .dsGood
        case "down":   return .dsDanger
        case "stable": return .dsTextTertiary
        default:       return .dsTextTertiary
        }
    }

    // MARK: - Empty / error

    private func emptyState(message: LocalizedStringKey, isError: Bool) -> some View {
        VStack(spacing: .dsSpacingSm) {
            Image(systemName: isError ? "exclamationmark.triangle" : "tray")
                .font(.system(size: 40))
                .foregroundStyle(isError ? Color.dsDanger : Color.dsTextTertiary)
            Text(message)
                .font(.dsBodySm)
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Helpers

    /// Readiness chip colour. Prefers the server-provided band
    /// (`readiness_band` / `readiness_today_band`, PR #85 with stable
    /// keys `optimal`/`fair`/`low`) so the threshold (80/50) lives
    /// server-side. Falls back to the local 70/40 split only when an
    /// older server omits the band — note those thresholds are stale,
    /// so once the v2.4 server is live the bands path is the
    /// authoritative one.
    private func readinessColor(band: String?, score: Int) -> Color {
        switch band {
        case "optimal", "good": return .dsGood
        case "fair":            return .dsWarn
        case "low":             return .dsDanger
        case nil, .some(_):
            if score >= 70 { return .dsGood }
            if score >= 40 { return .dsWarn }
            if score >  0  { return .dsDanger }
            return .dsTextTertiary
        }
    }

    /// Readiness text label as a `Text` view. Returns `Text(verbatim:)`
    /// for the primary path so the server-localized string renders
    /// as-is — wrapping in `LocalizedStringKey` would look the value up
    /// in xcstrings again and re-translate to the iOS UI locale,
    /// violating the content-vs-chrome split (Codex review on PR #12).
    /// The fallbacks for older servers use literal English keys that
    /// `LocalizedStringKey` can still look up in xcstrings to honour
    /// the iOS UI locale when no server label is available.
    private func readinessDisplay(_ b: BriefingResponse, score: Int) -> Text {
        if let label = b.readinessTodayLabel ?? b.readinessLabel, !label.isEmpty {
            return Text(verbatim: label)
        }
        switch b.readinessTodayBand ?? b.readinessBand {
        case "optimal":   return Text("Optimal")
        case "good":      return Text("Good")
        case "fair":      return Text("Fair")
        case "low":       return Text("Low")
        case nil, .some(_):
            // Final fallback only — pre-PR-#85 servers without band
            // fields. Same thresholds as the legacy iOS switch.
            if score >= 70 { return Text("Good") }
            if score >= 40 { return Text("Fair") }
            if score >  0  { return Text("Low") }
            return Text("")
        }
    }

    private func severityColor(_ s: String) -> Color {
        switch s {
        case "warning":  return .dsWarn
        case "positive": return .dsGood
        default:         return .dsAccent
        }
    }

    private func trendColor(_ status: String?) -> Color {
        switch status {
        case "good":    return .dsGood
        case "warn":    return .dsWarn
        case "danger":  return .dsDanger
        default:        return .dsTextSecondary
        }
    }

    /// Section status badge. Uses `DSStatusBadge`'s `verbatim` init
    /// when the server provides a localized `status_label` (PR #84) so
    /// the string renders as-is. Falls back to the iOS xcstrings path
    /// (looks up the raw `status` key in chrome locale) only for older
    /// servers that don't populate `status_label`. The two-init split on
    /// `DSStatusBadge` is what makes this clean — see Codex review on
    /// PR #12.
    @ViewBuilder
    private func sectionStatusBadge(_ s: BriefingSection) -> some View {
        if let label = s.statusLabel, !label.isEmpty {
            DSStatusBadge(verbatim: label, status: badgeStatus(s.status))
        } else {
            DSStatusBadge(text: LocalizedStringKey(s.status.capitalized),
                          status: badgeStatus(s.status))
        }
    }

    private func badgeStatus(_ s: String) -> DSStatusBadge.Status {
        switch s {
        case "good": return .good
        case "fair": return .warn
        case "low":  return .danger
        default:     return .neutral
        }
    }

    private func verdictColor(_ v: String) -> Color {
        switch v {
        case "push_hard":         return .dsGood
        case "moderate":          return .dsAccent
        case "active_recovery":   return .dsWarn
        case "rest":              return .dsDanger
        default:                  return .dsTextSecondary
        }
    }

    /// Verdict display as a `Text` view. Server PR #84 ships
    /// `verdict_label` already localized; `Text(verbatim:)` renders it
    /// as-is so the iOS UI locale doesn't re-translate it (Codex
    /// review on PR #12). The fallback for older servers uses a
    /// capitalised raw key through `LocalizedStringKey` so iOS
    /// chrome locale still applies when no server label is available.
    private func verdictDisplay(_ e: EnergyBank) -> Text {
        if let label = e.verdictLabel, !label.isEmpty {
            return Text(verbatim: label)
        }
        return Text(LocalizedStringKey(e.actionVerdict
            .replacingOccurrences(of: "_", with: " ")
            .capitalized))
    }
}

#Preview {
    TodayView(selection: .constant(.today))
}
