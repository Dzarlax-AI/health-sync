import SwiftUI
import Charts

struct TrendsView: View {
    @State private var history: [ReadinessPoint] = []
    @State private var days: Int = 30
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var currentBriefing: BriefingResponse?
    @State private var loadGeneration = UUID()
    /// Section catalogue from `/api/sections` (health_dashboard PR #90).
    /// nil = not loaded yet; empty = server returned no sections (treat
    /// like a transient failure and hide the list rather than rendering
    /// an empty card).
    @State private var sections: [SectionCatalogueEntry]?

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                let contentWidth = max(0, viewport.size.width - (2 * .dsSpacing))
                ZStack(alignment: .top) {
                    TrendsBackdrop()
                        .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                        .ignoresSafeArea(edges: .top)

                    ScrollView {
                        VStack(alignment: .leading, spacing: .dsSpacingLg) {
                            TrendsPageHeader()
                            readinessCard
                            if let s = sections, !s.isEmpty {
                                sectionList(s)
                            }
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
            .task { await load() }
        }
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            if isLoading && history.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if let err = loadError {
                Text(LocalizedStringKey(err))
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsDanger)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if history.isEmpty {
                Text("No readiness data yet.")
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextTertiary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                readinessSummary

                HStack {
                    VStack(alignment: .leading, spacing: .dsSpacingXs) {
                        Text("Readiness history")
                            .font(.dsSubhead)
                            .foregroundStyle(Color.dsText)
                        Text("Last \(days) days")
                            .font(.dsCaption)
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                    Spacer()
                    Picker("Readiness range", selection: $days) {
                        Text("7d").tag(7)
                        Text("30d").tag(30)
                        Text("90d").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 164)
                    .tint(Color.dsReadiness)
                    .onChange(of: days) { _, _ in
                        Task { await load() }
                    }
                }

                Chart(chartPoints, id: \.id) { p in
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Score", p.score)
                    )
                    .foregroundStyle(Color.dsReadiness)
                    .interpolationMethod(.catmullRom)
                    AreaMark(
                        x: .value("Date", p.date),
                        y: .value("Score", p.score)
                    )
                    .foregroundStyle(Color.dsReadiness.opacity(0.16))
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.dsBorderHover)
                        AxisValueLabel()
                            .foregroundStyle(Color.dsTextTertiary)
                    }
                }
                .frame(height: 218)

                HStack {
                    Text(rangeStartLabel)
                    Spacer()
                    Text(rangeEndLabel)
                }
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
            }
        }
        .padding(.dsSpacing)
        .dsElevatedCard()
    }

    private var readinessSummary: some View {
        HStack(alignment: .center, spacing: .dsSpacing) {
            Text("\(latestReadinessScore)")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(Color.dsReadiness)
            VStack(alignment: .leading, spacing: 2) {
                Text("Today’s readiness")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
                Text(readinessDeltaSummary)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let readinessBadge {
                DSStatusBadge(verbatim: readinessBadge.label, status: readinessBadge.status)
            }
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color.dsReadiness.opacity(0.15), Color.dsReadiness.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: .dsRadiusElevatedCard, style: .continuous))
    }

    private var readinessChangeExplanation: String {
        guard let first = history.first?.score, let last = history.last?.score else {
            return String(localized: "No trend yet")
        }
        let delta = last - first
        if delta == 0 {
            return String(localized: "Unchanged from the start of this range")
        }
        let direction = delta > 0 ? String(localized: "higher") : String(localized: "lower")
        return String(localized: "\(abs(delta)) points \(direction) than the start of this range")
    }

    private var readinessDeltaSummary: String {
        guard let first = history.first?.score, let last = history.last?.score else {
            return String(localized: "No trend yet")
        }
        let delta = last - first
        if delta == 0 { return String(localized: "Unchanged from start") }
        let direction = delta > 0 ? String(localized: "higher") : String(localized: "lower")
        return String(localized: "\(abs(delta)) points \(direction)")
    }

    private var rangeStartLabel: String {
        formattedRangeDate(history.first?.date)
    }

    private var rangeEndLabel: String {
        formattedRangeDate(history.last?.date)
    }

    private var chartPoints: [(id: String, date: Date, score: Int)] {
        history.compactMap { point in
            guard let date = Self.chartDate(point.date) else { return nil }
            return (point.id, date, point.score)
        }
    }

    private func formattedRangeDate(_ value: String?) -> String {
        guard let value,
              let date = try? Date(value, strategy: .iso8601.year().month().day()) else {
            return value ?? ""
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private static func chartDate(_ raw: String) -> Date? {
        try? Date(raw, strategy: .iso8601.year().month().day())
    }

    private var latestReadinessScore: Int {
        history.last?.score ?? 0
    }

    /// The label and band stay server-owned. It is hidden rather than
    /// re-derived locally when this range ends before today's briefing.
    private var readinessBadge: (label: String, status: DSStatusBadge.Status)? {
        guard let briefing = currentBriefing,
              briefing.date == history.last?.date,
              let label = briefing.readinessTodayLabel ?? briefing.readinessLabel,
              !label.isEmpty else {
            return nil
        }
        let band = briefing.readinessTodayBand ?? briefing.readinessBand
        let status: DSStatusBadge.Status = switch band?.lowercased() {
        case "optimal", "strong", "good": .good
        case "fair", "moderate", "medium": .warn
        case "low", "poor": .danger
        default: .neutral
        }
        return (label, status)
    }

    private func sectionList(_ entries: [SectionCatalogueEntry]) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            Text("Explore your data")
                .font(.dsHeading.weight(.semibold))
                .foregroundStyle(Color.dsText)
                .padding(.horizontal, .dsSpacing)
                .padding(.top, .dsSpacing)

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                    if idx > 0 {
                        Divider().padding(.leading, 56)
                    }
                    navigationRow(entry)
                }
            }
        }
        .dsElevatedCard()
    }

    /// Push to SectionDetailView — same view used from Today's Health
    /// overview, so both entry points show the rich (summary + KPIs +
    /// charts + "How it works") page.
    private func navigationRow(_ entry: SectionCatalogueEntry) -> some View {
        NavigationLink(destination: SectionDetailView(sectionKey: entry.key)) {
            HStack(spacing: .dsSpacing) {
                Image(systemName: sfSymbol(for: entry.icon))
                    .frame(width: 24)
                    .foregroundStyle(tint(for: entry.key))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.dsSubhead).foregroundStyle(Color.dsText)
                    Text(entry.subtitle).font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.dsTextTertiary)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.dsSpacing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Maps the server's abstract icon token (`heart` / `activity` /
    /// `leaf` / future values) to an SF Symbol. Stays iOS-side because
    /// the choice of glyph is design, not translation — server should
    /// not need to know iOS' icon vocabulary. Unknown tokens fall back
    /// to a generic chart glyph so a server-added section still
    /// renders something recognisable in the row.
    private func sfSymbol(for icon: String) -> String {
        switch icon {
        case "heart":    return "heart.fill"
        case "activity": return "figure.run"
        case "leaf":     return "leaf.fill"
        case "moon":     return "moon.zzz"
        default:         return "chart.bar.fill"
        }
    }

    /// Tint colour per section key. Same iOS-side rationale as
    /// `sfSymbol(for:)` — design semantics rather than translation.
    /// The web dashboard maintains its own colour palette; iOS aligns
    /// where the DS tokens map naturally. Unknown keys → neutral accent.
    private func tint(for key: String) -> Color {
        switch key {
        case "cardio":   return .dsHeart
        case "activity": return .dsActivity
        case "recovery": return .dsSleep
        default:         return .dsAccent
        }
    }

    private func load() async {
        let requestGeneration = UUID()
        loadGeneration = requestGeneration
        isLoading = true
        loadError = nil
        // Readiness history is the primary data — its failure shows
        // the empty-state in the readiness card. The sections catalogue
        // is best-effort: a server too old to know `/api/sections`
        // 404s, and we just hide the list rather than blocking the
        // whole tab.
        do {
            async let historyTask = ServerClient.shared.readinessHistory(days: days)
            async let briefingTask: BriefingResponse? = try? ServerClient.shared.healthBriefing()
            let (history, briefing) = try await (historyTask, briefingTask)
            guard !Task.isCancelled, requestGeneration == loadGeneration else { return }
            self.history = history
            currentBriefing = briefing
        } catch {
            guard requestGeneration == loadGeneration else { return }
            loadError = error.localizedDescription
        }
        if let s = try? await ServerClient.shared.sections() {
            guard !Task.isCancelled, requestGeneration == loadGeneration else { return }
            sections = s.sections
        }
        if requestGeneration == loadGeneration {
            isLoading = false
        }
    }
}

private struct TrendsBackdrop: View {
    var body: some View {
        ZStack {
            Color.dsBackground
            RadialGradient(
                colors: [Color.dsReadiness.opacity(0.14), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 340
            )
            LinearGradient(
                colors: [Color.dsReadiness.opacity(0.05), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
    }
}

private struct TrendsPageHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacingXs) {
            Text("Trends")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(Color.dsText)
            Text("Your health over time")
                .font(.dsBody)
                .foregroundStyle(Color.dsTextSecondary)
        }
    }
}

#Preview {
    TrendsView()
}
