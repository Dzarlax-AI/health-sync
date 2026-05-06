import SwiftUI
import Charts

struct TodayView: View {
    @Binding var selection: TabSelection

    @State private var briefing: BriefingResponse?
    @State private var history: [ReadinessPoint] = []
    @State private var isLoading = false
    @State private var loadError: String?

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
                        if let ai = b.aiInsight, !ai.isEmpty {
                            aiInsightBlock(ai)
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
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        loadError = nil
        async let briefingTask = ServerClient.shared.healthBriefing()
        async let historyTask = ServerClient.shared.readinessHistory(days: 30)
        do {
            let (b, h) = try await (briefingTask, historyTask)
            self.briefing = b
            self.history = h
        } catch {
            self.loadError = error.localizedDescription
        }
        isLoading = false
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
                        .foregroundStyle(scoreColor(score))
                    Text(scoreLabel(score))
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
                Text(verdictTitle(e.actionVerdict))
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

    private func aiInsightBlock(_ text: String) -> some View {
        let parsed = parseAIInsight(text)
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: .dsSpacing) {
                if parsed.hasAnyBlock {
                    if !parsed.sleep.isEmpty {
                        aiBlock(icon: "moon.zzz", title: "Sleep",
                                tint: .dsSleep, body: parsed.sleep)
                    }
                    if !parsed.yesterday.isEmpty {
                        aiBlock(icon: "clock.arrow.circlepath", title: "Yesterday",
                                tint: .dsActivity, body: parsed.yesterday)
                    }
                    if !parsed.recovery.isEmpty {
                        aiBlock(icon: "leaf.fill", title: "Recovery",
                                tint: .dsCardio, body: parsed.recovery)
                    }
                    if !parsed.recommendation.isEmpty {
                        aiBlock(icon: "sparkles", title: "Recommendation",
                                tint: .dsAccent, body: parsed.recommendation)
                    }
                } else {
                    // Parser couldn't recognise headers — fall back to raw.
                    Text(parsed.raw)
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
                DSStatusBadge(text: statusLabel(s.status), status: badgeStatus(s.status))
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

    private func scoreColor(_ s: Int) -> Color {
        if s >= 70 { return .dsGood }
        if s >= 40 { return .dsWarn }
        if s > 0 { return .dsDanger }
        return .dsTextTertiary
    }

    private func scoreLabel(_ s: Int) -> LocalizedStringKey {
        if s >= 70 { return "Good" }
        if s >= 40 { return "Fair" }
        if s > 0 { return "Low" }
        return ""
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

    private func statusLabel(_ s: String) -> LocalizedStringKey {
        switch s {
        case "good": return "Good"
        case "fair": return "Fair"
        case "low":  return "Low"
        default:     return LocalizedStringKey(s.capitalized)
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

    private func verdictTitle(_ v: String) -> LocalizedStringKey {
        switch v {
        case "push_hard":        return "Push hard"
        case "moderate":         return "Moderate"
        case "active_recovery":  return "Active recovery"
        case "rest":             return "Rest"
        default:                 return LocalizedStringKey(v.replacingOccurrences(of: "_", with: " ").capitalized)
        }
    }
}

#Preview {
    TodayView(selection: .constant(.today))
}
