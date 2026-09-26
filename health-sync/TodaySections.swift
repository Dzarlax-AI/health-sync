import SwiftUI
import Charts

struct TodayPageHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let date: String
    let syncStatus: SyncStatus
    let openSyncStatus: () -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.dsRingText)
                Text(verbatim: formattedDate)
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsRingText)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            TodayHeaderSyncButton(status: syncStatus, action: openSyncStatus)
                .environment(\.colorScheme, .dark)
        }
    }

    private var formattedDate: String {
        guard let parsed = try? Date(date, strategy: .iso8601.year().month().day()) else {
            return date
        }
        return parsed.formatted(.dateTime.day().month(.wide).year())
    }
}

struct TodayHeroBlock: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let briefing: BriefingResponse
    let history: [ReadinessPoint]
    @Binding var expandedStressFlag: String?
    let contentWidth: CGFloat
    @Binding var selection: TabSelection
    let aiResponse: AIBriefingResponse?
    let aiGenerating: Bool
    let todayInsights: TodayInsightsResponse?
    var insightsStale = false

    var body: some View {
        VStack(spacing: 16) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 20)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
            layout {
                NavigationLink { EnergyView() } label: {
                    ring(value: briefing.energyBank?.current.formatted() ?? "—",
                         label: briefing.energyBank.map { LocalizedStringKey("of \($0.capacity)") } ?? "Current energy",
                         title: "Energy", fraction: briefing.energyBank.flatMap { $0.capacity > 0 ? Double($0.current) / Double($0.capacity) : nil }, appearance: .energy)
                }.accessibilityIdentifier("today-ring-energy")
                NavigationLink { SectionDetailView(sectionKey: "recovery") } label: {
                    ring(value: briefing.recoveryPct.map { "\($0)%" } ?? "—", label: "Recovery", title: "Recovery",
                         fraction: briefing.recoveryPct.map { Double($0) / 100 }, appearance: .recovery)
                }.accessibilityIdentifier("today-ring-recovery")
                Button { selection = .sleep } label: {
                    ring(value: briefing.sleep.map { "\(Int($0.efficiency.rounded()))%" } ?? "—",
                         label: "Sleep efficiency", title: "Sleep efficiency", fraction: briefing.sleep.map { $0.efficiency / 100 }, appearance: .sleep)
                }.accessibilityIdentifier("today-ring-sleep")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(Color.dsRingGroove.opacity(reduceTransparency || dynamicTypeSize.isAccessibilitySize ? 1 : 0.32), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.dsRingHighlight.opacity(0.45), lineWidth: 1))

            if let todayInsights {
                InsightPairView(snapshot: todayInsights, stale: insightsStale)
                    .frame(width: contentWidth)
            } else if briefing.dailyDecision != nil {
                TodayDailyPlanCard(
                    decision: briefing.dailyDecision!,
                    headline: briefing.headline,
                    aiResponse: aiResponse,
                    aiGenerating: aiGenerating
                )
                .frame(width: contentWidth)
            } else if shouldShowNarrativeCard {
                TodayHeroNarrativeCard(
                    briefing: briefing,
                    history: history,
                    expandedStressFlag: $expandedStressFlag,
                    showsDetails: shouldShowHeroDetails
                )
                .frame(width: contentWidth)
            }
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    private func ring(value: String, label: LocalizedStringKey, title: LocalizedStringKey,
                      fraction: Double?, appearance: DomainAppearance) -> some View {
        VStack(spacing: 10) {
            DomainGauge(value: value, label: label, fraction: fraction, appearance: appearance,
                        size: dynamicTypeSize.isAccessibilitySize ? 158 : max(76, (contentWidth - 48) / 3), compact: true, showsCaption: appearance == .energy)
            Text(title).font(.system(.caption).weight(.semibold)).foregroundStyle(Color.dsRingText)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity)
    }

    private var shouldShowHeroDetails: Bool {
        if let headline = briefing.headline, !headline.detail.isEmpty { return true }
        if briefing.energyBank != nil { return true }
        return !history.isEmpty
    }

    private var shouldShowNarrativeCard: Bool {
        briefing.headline?.title.isEmpty == false
            || briefing.readinessTip?.isEmpty == false
            || shouldShowHeroDetails
    }
}

struct TodayInsightsDomainsBlock: View {
    let snapshot: TodayInsightsResponse
    @Binding var selection: TabSelection

    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            Text("Today by domain").font(.system(.title3, design: .rounded).weight(.semibold))
            VStack(spacing: .dsSpacingSm) {
                ForEach(snapshot.domains) { domain in
                    TodayInsightDomainLink(domain: domain, selection: $selection)
                }
            }
            if !snapshot.changes.isEmpty {
                VStack(alignment: .leading, spacing: .dsSpacingSm) {
                    Text("Changes today").font(.system(.headline, design: .rounded))
                    ForEach(snapshot.changes) { change in
                        Text(change.title).font(.dsBodySm.weight(.semibold))
                        Text(change.detail).font(.dsBodySm).foregroundStyle(Color.dsTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.dsSpacing).dsCard()
                .accessibilityIdentifier("insight-changes")
            }
        }
    }
}

private struct TodayInsightDomainLink: View {
    let domain: TodayInsightDomain
    @Binding var selection: TabSelection

    private var destination: InsightDestination { .resolve(domain: domain) }
    private var isNavigable: Bool { destination != .none }

    @ViewBuilder
    var body: some View {
        Group {
            switch destination {
            case .sleep:
                Button { selection = .sleep } label: { card }.buttonStyle(.plain)
            case .energy:
                NavigationLink { EnergyView() } label: { card }.buttonStyle(.plain)
            case .section(let key):
                NavigationLink { SectionDetailView(sectionKey: key) } label: { card }.buttonStyle(.plain)
            case .none: card
            }
        }
        .accessibilityIdentifier("insight-domain-\(domain.key)")
    }

    private var dataStateLabel: LocalizedStringKey {
        switch domain.dataState {
        case "fresh": return "Data is current"
        case "partial": return "Partial data"
        case "stale": return "Data needs updating"
        default: return "Not enough data"
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: .dsSpacingXs) {
            HStack(alignment: .firstTextBaseline, spacing: .dsSpacingSm) {
                Text(domain.summary)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Color.dsText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: isNavigable ? "chevron.right" : "circle.fill")
                    .font(.system(size: isNavigable ? 13 : 7, weight: .semibold))
                    .foregroundStyle(Color.dsTextTertiary)
            }
            Text(dataStateLabel).font(.dsCaption).foregroundStyle(Color.dsTextSecondary)

        }
        .padding(.dsSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .domainSurface(.recovery)
        .accessibilityElement(children: .combine)
    }
}

private struct TodayReadinessRing: View {
    let score: Int
    let label: Text

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.dsSurface.opacity(0.82))
                .shadow(color: Color.dsElevatedShadow.opacity(0.08), radius: 14, y: 7)
            Circle()
                .stroke(Color.dsReadiness.opacity(0.13), lineWidth: 18)
                .padding(9)
            Circle()
                .trim(from: 0, to: readinessProgress)
                .stroke(
                    AngularGradient(
                        colors: [Color.dsReadiness.opacity(0.62), Color.dsReadiness],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(9)

            VStack(spacing: .dsSpacingXs) {
                Text(score > 0 ? "\(score)" : "--")
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                    .foregroundStyle(Color.dsReadiness)
                Text("Readiness")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(Color.dsText)
                label
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
        }
        .frame(width: 164, height: 164)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Readiness today")
        .accessibilityValue(score > 0 ? "\(score)" : "No score")
    }
    private var readinessProgress: CGFloat {
        CGFloat(max(0, min(100, score))) / 100
    }
}

private struct TodayHeaderSyncButton: View {
    let status: SyncStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Text(label)
                    .font(.dsCaption.weight(.semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .frame(minHeight: 34)
            .background(backgroundTint, in: Capsule())
            .overlay(Capsule().stroke(Color.dsElevatedBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today-sync-status")
        .accessibilityLabel("Data sync")
        .accessibilityValue(label)
    }

    private var icon: String {
        switch status {
        case .accepted: return "checkmark"
        case .error: return "arrow.trianglehead.2.clockwise"
        default: return "arrow.trianglehead.2.clockwise"
        }
    }

    private var tint: Color {
        switch status {
        case .accepted: return .dsGood
        case .error: return .dsDanger
        case .sending, .partial, .retryPending: return .dsWarn
        case .notConfigured, .noData, .disabled: return .dsTextSecondary
        }
    }

    private var label: LocalizedStringKey {
        switch status {
        case .accepted: return "Updated"
        case .error: return "Sync issue"
        case .sending: return "Sending"
        case .partial: return "Partially accepted"
        case .retryPending: return "Waiting to retry"
        case .notConfigured: return "Connect server"
        case .noData: return "No available data"
        case .disabled: return "Sync disabled"
        }
    }

    private var backgroundTint: Color {
        status == .error ? .dsDangerBg.opacity(0.92) : .dsSurface.opacity(0.72)
    }
}

private struct TodayEnergyPill: View {
    let energyBank: EnergyBank

    private var tint: Color { todayVerdictColor(energyBank.actionVerdict) }

    private var batterySymbol: String {
        let ratio = Double(energyBank.current) / Double(max(energyBank.capacity, 1))
        switch ratio {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: .dsSpacingSm) {
            Image(systemName: batterySymbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Energy")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(Color.dsText)
                Text("\(energyBank.current) / \(energyBank.capacity)")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.dsSurface.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(Color.dsElevatedBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Energy")
        .accessibilityValue("\(energyBank.current) of \(energyBank.capacity)")
    }
}

private struct TodayHeroSupportingValues: View {
    let cards: [MetricCard]
    @Binding var selection: TabSelection

    var body: some View {
        HStack(alignment: .top, spacing: .dsSpacingSm) {
            ForEach(cards) { card in
                metricDestination(for: card) {
                    TodaySupportingMetricContent(card: card, symbol: symbol(for: card), color: iconColor(for: card))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func metricDestination<Label: View>(for card: MetricCard, @ViewBuilder label: () -> Label) -> some View {
        // The server's primary duration card is `night_sleep_total`, while
        // stages use `sleep_*`. Both are a single Sleep destination, never a
        // generic metric-detail screen.
        if card.metric.localizedCaseInsensitiveContains("sleep") {
            Button { selection = .sleep } label: { label() }
        } else {
            NavigationLink(destination: MetricDetailView(metric: card.metric, displayName: card.name)) {
                label()
            }
        }
    }

    private func symbol(for card: MetricCard) -> String {
        let value = "\(card.metric) \(card.name)".lowercased()
        if value.contains("sleep") { return "moon.stars.fill" }
        if value.contains("heart") || value.contains("pulse") || value.contains("hrv") { return "heart.text.square.fill" }
        return "waveform.path.ecg"
    }

    private func iconColor(for card: MetricCard) -> Color {
        symbol(for: card) == "moon.stars.fill" ? .dsSleep : .dsGood
    }
}

private struct TodaySupportingMetricContent: View {
    let card: MetricCard
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: .dsSpacingSm) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 30, height: 30)
                    .background(color.opacity(0.12), in: Circle())
                Text(card.name)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(card.value)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.dsText)
                    .minimumScaleFactor(0.78)
                    .lineLimit(1)
                Text(card.unit)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextTertiary)
                    .lineLimit(1)
            }
            if let trend = card.trend7dLabel, !trend.isEmpty {
                Text(trend)
                    .font(.dsCaption.weight(.medium))
                    .foregroundStyle(todayTrendColor(card.trend7dStatus))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dsSpacing)
        .todayMetricSurface()
    }
}

private struct TodayHeroNarrativeCard: View {
    let briefing: BriefingResponse
    let history: [ReadinessPoint]
    @Binding var expandedStressFlag: String?
    let showsDetails: Bool

    private var hasNarrative: Bool {
        (briefing.headline?.title.isEmpty == false)
            || (briefing.readinessTip?.isEmpty == false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            if hasNarrative {
                HStack(alignment: .firstTextBaseline, spacing: .dsSpacingSm) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 24, height: 24)
                        .background(Color.dsAccent.opacity(0.12), in: Circle())
                    if let title = briefing.headline?.title, !title.isEmpty {
                        Text(title)
                            .font(.system(.title3, design: .default).weight(.semibold))
                            .foregroundStyle(Color.dsText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if briefing.dailyDecision == nil, let tip = briefing.readinessTip, !tip.isEmpty {
                Text(tip)
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsDetails {
                DisclosureGroup {
                    TodayHeroDetails(
                        briefing: briefing,
                        history: history,
                        expandedStressFlag: $expandedStressFlag
                    )
                    .padding(.top, .dsSpacingSm)
                } label: {
                    Text("Learn more")
                        .font(.dsBodySm.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                }
                .tint(Color.dsAccent)
            }
        }
        .padding(.dsSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayFocusSurface()
    }
}

private struct TodayDailyPlanCard: View {
    let decision: DailyDecision
    let headline: HeadlineSignal?
    let aiResponse: AIBriefingResponse?
    let aiGenerating: Bool

    private var hasFreshPlan: Bool {
        guard let aiResponse,
              aiResponse.decisionId == decision.id,
              aiResponse.freshForDecision == true,
              let plan = aiResponse.plan else { return false }
        return TodayAIBriefingController.planHasContent(plan)
    }

    private var planTitle: String {
        if hasFreshPlan {
            let title = aiResponse?.plan?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "AI plan" : title
        }
        return decision.label ?? "Plan for today"
    }

    private var planBody: String? {
        guard hasFreshPlan else { return decision.reason }
        return aiResponse?.plan?.body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            Label(hasFreshPlan ? "AI plan" : "Daily guidance",
                  systemImage: hasFreshPlan ? "sparkles" : "scope")
                .font(.dsBody.weight(.semibold))
                .foregroundStyle(Color.dsText)
            Text(planTitle)
                .font(.system(.title3, design: .default).weight(.semibold))
                .foregroundStyle(Color.dsText)
                .fixedSize(horizontal: false, vertical: true)
            if let planBody, !planBody.isEmpty {
                Text(planBody)
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let headline, !headline.title.isEmpty {
                Divider()
                    .overlay(Color.dsElevatedBorder)
                Label(headline.title, systemImage: "waveform.path.ecg")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasFreshPlan, let aiResponse {
                Divider()
                    .overlay(Color.dsElevatedBorder)
                NavigationLink {
                    TodayAIPlanDetail(response: aiResponse)
                } label: {
                    HStack {
                        Text("View AI insight")
                            .font(.dsBodySm.weight(.semibold))
                            .foregroundStyle(Color.dsAccent)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dsAccent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-ai-insight-details")
            }
            if !hasFreshPlan && (aiGenerating || aiResponse?.generating == true || aiResponse?.freshForDecision == false) {
                Label("Detailed plan is updating", systemImage: "arrow.trianglehead.2.clockwise")
                    .font(.dsCaption.weight(.medium))
                    .foregroundStyle(Color.dsWarn)
            }
        }
        .padding(.dsSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayFocusSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-daily-plan")
    }
}

private struct TodayFocusSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.dsSurface.opacity(0.78))
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.dsElevatedBorder, lineWidth: 1)
            }
            .shadow(color: Color.dsElevatedShadow.opacity(0.42), radius: 12, y: 4)
    }
}

private struct TodayMetricSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.dsSurface.opacity(0.70))
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.dsElevatedBorder, lineWidth: 1)
            }
            .shadow(color: Color.dsElevatedShadow.opacity(0.22), radius: 8, y: 3)
    }
}

private struct TodayRecommendationSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.dsSurface.opacity(0.68))
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.dsElevatedBorder, lineWidth: 1)
            }
            .shadow(color: Color.dsElevatedShadow.opacity(0.16), radius: 7, y: 3)
    }
}

private extension View {
    func todayFocusSurface() -> some View { modifier(TodayFocusSurface()) }
    func todayMetricSurface() -> some View { modifier(TodayMetricSurface()) }
    func todayRecommendationSurface() -> some View { modifier(TodayRecommendationSurface()) }
}

private struct TodayHeroDetails: View {
    let briefing: BriefingResponse
    let history: [ReadinessPoint]
    @Binding var expandedStressFlag: String?

    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            if let headline = briefing.headline, !headline.detail.isEmpty {
                Text(headline.detail)
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextSecondary)
                    .multilineTextAlignment(.leading)
            }

            if let energyBank = briefing.energyBank {
                TodayEnergyBankDetailView(
                    energyBank: energyBank,
                    expandedStressFlag: $expandedStressFlag
                )
            }

            if !history.isEmpty {
                TodayReadinessSparkline(history: history)
                    .frame(height: 56)
                    .accessibilityLabel("Readiness trend")
            }
        }
    }
}

private struct TodayReadinessSparkline: View {
    let history: [ReadinessPoint]

    var body: some View {
        let points = history.compactMap { point -> (id: String, date: Date, score: Int)? in
            guard let date = try? Date(point.date, strategy: .iso8601.year().month().day()) else { return nil }
            return (point.id, date, point.score)
        }
        Chart(points, id: \.id) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("Score", point.score)
            )
            .foregroundStyle(Color.dsAccent)
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...100)
    }
}

private struct TodayEnergyBankDetailView: View {
    let energyBank: EnergyBank
    @Binding var expandedStressFlag: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.dsTextTertiary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(todayVerdictColor(energyBank.actionVerdict))
                        .frame(width: geo.size.width * CGFloat(max(0, min(energyBank.capacity, energyBank.current))) / CGFloat(max(energyBank.capacity, 1)))
                }
            }
            .frame(height: 8)
            if !energyBank.verdictReason.isEmpty {
                Text(energyBank.verdictReason)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextTertiary)
            }
            HStack(spacing: .dsSpacingSm) {
                TodayEnergyDetail(label: "Drain so far", value: "\(energyBank.drainSoFar)")
                TodayEnergyDetail(label: "Strain", value: "\(energyBank.strain)")
            }
            if let details = energyBank.flagDetails, !details.isEmpty {
                TodayStressFlagChips(
                    details: details,
                    expandedStressFlag: $expandedStressFlag
                )
            }
        }
    }
}

private struct TodayEnergyDetail: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
            Spacer(minLength: 4)
            Text(value)
                .font(.dsMono)
                .foregroundStyle(Color.dsTextSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.dsSurface2.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct TodayStressFlagChips: View {
    let details: [FlagDetail]
    @Binding var expandedStressFlag: String?

    private var visibleDetails: [FlagDetail] {
        details.filter {
            !$0.key.hasPrefix("imputed_") && !$0.label.isEmpty
        }
    }

    var body: some View {
        if !visibleDetails.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(visibleDetails) { detail in
                            TodayStressFlagChip(
                                detail: detail,
                                expandedStressFlag: $expandedStressFlag
                            )
                        }
                    }
                }
                if let expanded = expandedStressFlag,
                   let match = visibleDetails.first(where: { $0.key == expanded }) {
                    Text(match.description)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct TodayStressFlagChip: View {
    let detail: FlagDetail
    @Binding var expandedStressFlag: String?

    var body: some View {
        let style = todayStressFlagStyle(detail.key)
        Text(detail.label)
            .font(.dsCaption.weight(.medium))
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(style.background))
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
            .accessibilityAddTraits(.isButton)
    }
}

struct TodayAlertsBlock: View {
    let alerts: [Alert]

    var body: some View {
        VStack(spacing: .dsSpacingSm) {
            ForEach(criticalAlerts, id: \.text) { alert in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.dsDanger)
                    Text(alert.text)
                        .font(.dsBodySm)
                        .foregroundStyle(Color.dsText)
                    Spacer(minLength: 0)
                }
                .padding(.dsSpacingSm)
                .dsCard()
            }
            if !watchAlerts.isEmpty {
                VStack(alignment: .leading, spacing: .dsSpacingSm) {
                    Label("Signals to watch", systemImage: "exclamationmark.circle")
                        .font(.dsBodySm.weight(.semibold))
                        .foregroundStyle(Color.dsWarn)
                    ForEach(watchAlerts, id: \.text) { alert in
                        TodayWatchAlert(alert: alert)
                    }
                }
                .padding(.dsSpacingSm)
                .dsCard()
            }
        }
    }

    private var criticalAlerts: [Alert] {
        alerts.filter { $0.severity.lowercased() == "critical" }
    }

    private var watchAlerts: [Alert] {
        alerts.filter { $0.severity.lowercased() != "critical" }
    }
}

private struct TodayWatchAlert: View {
    let alert: Alert
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacingXs) {
            Text(alert.text)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextSecondary)
                .lineLimit(expanded ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !expanded {
                Button("Show more") {
                    withAnimation(.snappy) { expanded = true }
                }
                .font(.dsCaption.weight(.semibold))
                .foregroundStyle(Color.dsAccent)
                .buttonStyle(.plain)
            }
        }
    }
}

struct TodayAIInsightBlock: View {
    let response: AIBriefingResponse?
    let generating: Bool

    @ViewBuilder
    var body: some View {
        if let response, TodayAIBriefingController.hasContent(response) {
            TodayAIInsightExpanded(response: response)
        } else if generating {
            Label("Recommendation is updating", systemImage: "arrow.trianglehead.2.clockwise")
                .font(.dsCaption.weight(.medium))
                .foregroundStyle(Color.dsWarn)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.dsSpacing)
                .todayRecommendationSurface()
        }
    }
}

private struct TodayAIInsightExpanded: View {
    let response: AIBriefingResponse

    private var sections: TodayAISections { TodayAISections(response: response) }
    private var sleep: String { sections.sleep }
    private var yesterday: String { sections.yesterday }
    private var recovery: String { sections.recovery }
    private var recommendation: String { sections.recommendation }
    private var hasChunkedContent: Bool {
        !sleep.isEmpty || !yesterday.isEmpty || !recovery.isEmpty || !recommendation.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            HStack(alignment: .firstTextBaseline, spacing: .dsSpacingSm) {
                Label("Recommendation", systemImage: "sparkles")
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(Color.dsText)
                Spacer(minLength: 0)
                if topicChips.count > 1 {
                    Text("\(topicChips.count) signals")
                        .font(.dsCaption.weight(.medium))
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }

            Text(primaryText)
                .font(.dsBodySm)
                .foregroundStyle(Color.dsTextSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasDetails {
                Divider()
                NavigationLink {
                    TodayAIInsightDetail(sections: sections, topicChips: topicChips)
                } label: {
                    HStack {
                        Text("View details")
                            .font(.dsBodySm.weight(.semibold))
                            .foregroundStyle(Color.dsAccent)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dsAccent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.dsSpacing)
        .todayRecommendationSurface()
    }

    private var primaryText: String {
        [recommendation, recovery, sleep, yesterday, sections.fallback]
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private var hasDetails: Bool {
        let visibleSections = [recommendation, recovery, sleep, yesterday].filter { !$0.isEmpty }
        return visibleSections.count > 1 || (!sections.fallback.isEmpty && sections.fallback != primaryText)
    }

    private var topicChips: [TodayAIChip] {
        [
            TodayAIChip(icon: "sparkles", title: "Plan", tint: .dsAccent, isVisible: !recommendation.isEmpty),
            TodayAIChip(icon: "leaf.fill", title: "Recovery", tint: .dsCardio, isVisible: !recovery.isEmpty),
            TodayAIChip(icon: "moon.zzz", title: "Sleep", tint: .dsSleep, isVisible: !sleep.isEmpty),
            TodayAIChip(icon: "clock.arrow.circlepath", title: "Yesterday", tint: .dsActivity, isVisible: !yesterday.isEmpty),
        ].filter(\.isVisible)
    }
}

private struct TodayAIInsightDetail: View {
    let sections: TodayAISections
    let topicChips: [TodayAIChip]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .dsSpacingLg) {
                if !topicChips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(topicChips) { chip in
                                Label(chip.title, systemImage: chip.icon)
                                    .font(.dsCaption.weight(.medium))
                                    .foregroundStyle(chip.tint)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(chip.tint.opacity(0.10), in: Capsule())
                            }
                        }
                    }
                }

                if !sections.recommendation.isEmpty {
                    TodayAIBlock(icon: "sparkles", title: "Recommendation", tint: .dsAccent, text: sections.recommendation)
                }
                if !sections.recovery.isEmpty {
                    TodayAIBlock(icon: "leaf.fill", title: "Recovery", tint: .dsCardio, text: sections.recovery)
                }
                if !sections.sleep.isEmpty {
                    TodayAIBlock(icon: "moon.zzz", title: "Sleep", tint: .dsSleep, text: sections.sleep)
                }
                if !sections.yesterday.isEmpty {
                    TodayAIBlock(icon: "clock.arrow.circlepath", title: "Yesterday", tint: .dsActivity, text: sections.yesterday)
                }
                if sections.recommendation.isEmpty,
                   sections.recovery.isEmpty,
                   sections.sleep.isEmpty,
                   sections.yesterday.isEmpty,
                   !sections.fallback.isEmpty {
                    Text(sections.fallback)
                        .font(.dsBodySm)
                        .foregroundStyle(Color.dsTextSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.dsSpacing)
        }
        .navigationTitle("Recommendation")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.dsBackground)
    }
}

private struct TodayAIPlanDetail: View {
    let response: AIBriefingResponse

    private var plan: AIBriefingPlan? { response.plan }
    private var sections: TodayAISections { TodayAISections(response: response) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .dsSpacingLg) {
                VStack(alignment: .leading, spacing: .dsSpacingSm) {
                    Label("Today's AI plan", systemImage: "sparkles")
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                    if let title = plan?.title, !title.isEmpty {
                        Text(title)
                            .font(.system(.title, design: .default).weight(.bold))
                            .foregroundStyle(Color.dsText)
                    }
                    if let body = plan?.body, !body.isEmpty {
                        Text(body)
                            .font(.dsBody)
                            .foregroundStyle(Color.dsTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if hasReasons {
                    Divider()
                    Text("Why this fits today")
                        .font(.dsSubhead)
                        .foregroundStyle(Color.dsText)
                    VStack(spacing: 0) {
                        if !sections.recovery.isEmpty {
                            TodayAIInsightReason(icon: "leaf.fill", title: "Recovery", tint: .dsCardio, text: sections.recovery)
                        }
                        if !sections.sleep.isEmpty {
                            Divider().padding(.leading, 42)
                            TodayAIInsightReason(icon: "moon.zzz", title: "Sleep", tint: .dsSleep, text: sections.sleep)
                        }
                        if !sections.yesterday.isEmpty {
                            Divider().padding(.leading, 42)
                            TodayAIInsightReason(icon: "clock.arrow.circlepath", title: "Yesterday", tint: .dsActivity, text: sections.yesterday)
                        }
                    }
                    .dsElevatedCard()
                }

                if !sections.fallback.isEmpty, !hasReasons {
                    Text(sections.fallback)
                        .font(.dsBodySm)
                        .foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.dsSpacing)
        }
        .background(Color.dsBackground)
        .navigationTitle("AI insight")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hasReasons: Bool {
        !sections.recovery.isEmpty || !sections.sleep.isEmpty || !sections.yesterday.isEmpty
    }
}

private struct TodayAIInsightReason: View {
    let icon: String
    let title: LocalizedStringKey
    let tint: Color
    let text: String
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: .dsSpacingSm) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.dsBodySm.weight(.semibold))
                        .foregroundStyle(Color.dsText)
                    Text(text)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextSecondary)
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dsTextTertiary)
                    .padding(.top, 4)
            }
            .padding(.dsSpacing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows more detail")
    }
}

private struct TodayAISections {
    let sleep: String
    let yesterday: String
    let recovery: String
    let recommendation: String
    let fallback: String

    init(response: AIBriefingResponse) {
        let parsed = Self.parseLegacyInsight(response.insight)
        sleep = Self.cleaned(response.sleep) ?? parsed["SLEEP"] ?? ""
        yesterday = Self.cleaned(response.yesterday) ?? parsed["YESTERDAY"] ?? ""
        recovery = Self.cleaned(response.recovery) ?? parsed["RECOVERY"] ?? ""
        recommendation = Self.cleaned(response.recommendation) ?? parsed["RECOMMENDATION"] ?? ""

        if parsed.isEmpty {
            fallback = Self.stripKnownHeading(response.insight)
        } else {
            fallback = ""
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return nil
        }
        return stripKnownHeading(cleaned)
    }

    private static func parseLegacyInsight(_ insight: String) -> [String: String] {
        let knownHeadings = Set(["SLEEP", "YESTERDAY", "RECOVERY", "RECOMMENDATION"])
        var sections: [String: [String]] = [:]
        var currentHeading: String?

        for rawLine in insight.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = line.uppercased()
            if knownHeadings.contains(upper) {
                currentHeading = upper
            } else if !line.isEmpty, let currentHeading {
                sections[currentHeading, default: []].append(line)
            }
        }

        return sections.mapValues { lines in
            lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func stripKnownHeading(_ text: String) -> String {
        let knownHeadings = Set(["SLEEP", "YESTERDAY", "RECOVERY", "RECOMMENDATION"])
        var lines = text.components(separatedBy: .newlines)
        while let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              knownHeadings.contains(first.uppercased()) {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TodayAIChip: Identifiable {
    var id: String { icon }
    let icon: String
    let title: LocalizedStringKey
    let tint: Color
    let isVisible: Bool
}

private struct TodayAIBlock: View {
    let icon: String
    let title: LocalizedStringKey
    let tint: Color
    let text: String

    var body: some View {
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
            Text(text)
                .font(.dsBodySm)
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TodayOverviewBlock: View {
    let sections: [BriefingSection]
    @Binding var selection: TabSelection

    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            SectionHeader(title: "Health overview")
            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { idx, section in
                    if idx > 0 { Divider().padding(.leading, .dsSpacing) }
                    TodayOverviewSectionLink(section: section, selection: $selection)
                }
            }
            .dsElevatedCard()
        }
    }
}

private struct TodayOverviewSectionLink: View {
    let section: BriefingSection
    @Binding var selection: TabSelection

    var body: some View {
        if section.key == "sleep" {
            Button {
                selection = .sleep
            } label: {
                TodayOverviewSectionRow(section: section)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(destination: SectionDetailView(sectionKey: section.key)) {
                TodayOverviewSectionRow(section: section)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct TodayOverviewSectionRow: View {
    let section: BriefingSection

    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            HStack(spacing: .dsSpacingSm) {
                Text(section.title)
                    .font(.dsSubhead)
                    .foregroundStyle(Color.dsText)
                todaySectionStatusBadge(section)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.dsTextTertiary)
                    .font(.system(size: 13, weight: .semibold))
            }

            if !section.summary.isEmpty {
                Text(section.summary)
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
        }
        .padding(.dsSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TodayEmptyState: View {
    let message: LocalizedStringKey
    let isError: Bool

    var body: some View {
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
}

private struct TodayStressFlagStyle {
    let foreground: Color
    let background: Color
    let isDashed: Bool
}

private func todayStressFlagStyle(_ key: String) -> TodayStressFlagStyle {
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

private func todayReadinessDisplay(_ briefing: BriefingResponse, score: Int) -> Text {
    if let label = briefing.readinessTodayLabel ?? briefing.readinessLabel, !label.isEmpty {
        return Text(verbatim: label)
    }
    switch briefing.readinessTodayBand ?? briefing.readinessBand {
    case "optimal":   return Text("Optimal")
    case "good":      return Text("Good")
    case "fair":      return Text("Fair")
    case "low":       return Text("Low")
    case nil, .some(_):
        if score >= 70 { return Text("Good") }
        if score >= 40 { return Text("Fair") }
        if score > 0 { return Text("Low") }
        return Text("")
    }
}

private func todayTrendColor(_ status: String?) -> Color {
    switch status {
    case "good":    return .dsGood
    case "warn":    return .dsWarn
    case "danger":  return .dsDanger
    default:        return .dsTextSecondary
    }
}

private func todayMetricCardSort(_ lhs: MetricCard, _ rhs: MetricCard) -> Bool {
    let left = todayMetricCardPriority(lhs)
    let right = todayMetricCardPriority(rhs)
    if left == right {
        return lhs.metric.localizedStandardCompare(rhs.metric) == .orderedAscending
    }
    return left < right
}

private func todayMetricCardPriority(_ card: MetricCard) -> Int {
    let key = "\(card.metric) \(card.name)".lowercased()
    if key.contains("sleep") { return 0 }
    if key.contains("hrv") || key.contains("variability") { return 1 }
    if key.contains("resting") || key.contains("rhr") { return 2 }
    if key.contains("stress") || key.contains("strain") || key.contains("load") { return 3 }
    if key.contains("steps") || key.contains("activity") { return 4 }
    return 10
}

@ViewBuilder
private func todaySectionStatusBadge(_ section: BriefingSection) -> some View {
    if let label = section.statusLabel, !label.isEmpty {
        DSStatusBadge(verbatim: label, status: todayBadgeStatus(section.status))
    } else {
        DSStatusBadge(text: LocalizedStringKey(section.status.capitalized),
                      status: todayBadgeStatus(section.status))
    }
}

private func todayBadgeStatus(_ status: String) -> DSStatusBadge.Status {
    switch status {
    case "good": return .good
    case "fair": return .warn
    case "low":  return .danger
    default:     return .neutral
    }
}

private func todayVerdictColor(_ verdict: String) -> Color {
    switch verdict {
    case "push_hard":       return .dsGood
    case "moderate":        return .dsAccent
    case "active_recovery": return .dsWarn
    case "rest":            return .dsDanger
    default:                return .dsTextSecondary
    }
}
