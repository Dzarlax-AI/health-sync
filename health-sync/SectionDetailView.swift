import SwiftUI
import Charts

/// Detail view for a Health overview section (recovery / sleep / activity /
/// cardio). Mirrors the web section page: summary → KPI details → curated
/// charts → "How it works" explainer cards. All content (including text and
/// chart picks) comes from `/api/section/{key}` so the server stays the
/// single source of truth for explanations.
struct SectionDetailView: View {
    let sectionKey: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var recoveryBriefing: BriefingResponse?
    private var appearance: DomainAppearance { DomainAppearance(key: sectionKey) }
    private var pageTitle: String {
        if let section { return section.title }
        switch sectionKey {
        case "sleep": return String(localized: "Sleep")
        case "activity": return String(localized: "Activity")
        case "cardio": return String(localized: "Cardio")
        default: return String(localized: "Recovery")
        }
    }
    @State private var todayInsights = TodayInsightsController()

    @State private var section: SectionResponse?
    @State private var pointsByMetric: [String: [DataPoint]] = [:]
    @State private var readinessHistory: [ReadinessPoint] = []
    @State private var sleepNights: [SleepNight] = []
    @State private var days: Int = 30
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var chartLoadGeneration = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .dsSpacingLg) {
                if section == nil {
                    DomainPageHeader(title: pageTitle).domainHero(appearance)
                }
                if isLoading && section == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if let err = loadError, section == nil {
                    errorBlock(err)
                } else if let s = section {
                    sectionHero(s)
                    let details = sectionKey == "recovery" ? s.details : Array(s.details.dropFirst())
                    if !details.isEmpty { kpiBlock(Array(details.prefix(2))) }
                    if sectionKey == "recovery" {
                        DomainInsightSection(controller: todayInsights, slot: "recovery", appearance: appearance)
                    }
                    if !s.summary.isEmpty {
                        summaryBlock(s.summary)
                    }
                    if details.count > 2 { kpiBlock(Array(details.dropFirst(2))) }
                    if !s.charts.isEmpty { sectionRangePicker }
                    ForEach(Array(s.charts.enumerated()), id: \.offset) { _, chart in
                        chartBlock(chart)
                    }
                }
                if let section, !section.explains.isEmpty { explainsBlock(section.explains) }
            }
            .foregroundStyle(Color.dsText)
            .padding(.dsSpacing)
            .padding(.bottom, .dsTabBarClearance)
        }
        .background { DomainBackdrop(appearance: appearance) }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .refreshable {
            async let charts: Void = load()
            if sectionKey == "recovery" { await todayInsights.refresh() }
            await charts
        }
        .task { await load() }
        .modifier(RecoveryInsightLifecycle(controller: todayInsights, enabled: sectionKey == "recovery"))
    }

    // MARK: - Blocks

    private func sectionHero(_ section: SectionResponse) -> some View {
        VStack(spacing: .dsSpacingLg) {
            DomainPageHeader(title: pageTitle, date: recoveryBriefing?.date)
            if sectionKey == "recovery" {
                DomainGauge(value: recoveryBriefing?.recoveryPct.map { "\($0)%" } ?? "—", label: "Recovery", fraction: recoveryBriefing?.recoveryPct.map { Double($0) / 100 }, appearance: appearance)
                    .accessibilityIdentifier("domain-hero-recovery")
            } else if let first = section.details.first {
                DomainGauge(value: first.value, label: LocalizedStringKey(first.label), fraction: nil, appearance: appearance)
                    .accessibilityIdentifier("domain-hero-\(sectionKey)")
            }
        }
        .domainHero(appearance)
    }

    private var sectionRangePicker: some View {
        Picker("Chart range", selection: $days) {
            Text("7d").tag(7)
            Text("30d").tag(30)
            Text("90d").tag(90)
        }
        .pickerStyle(.segmented)
        .tint(appearance.accent)
        .onChange(of: days) { _, _ in
            Task { await loadChartsForSelectedRange() }
        }
    }

    private func summaryBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            Text("Overview")
                .font(.dsCaption.weight(.semibold))
                .foregroundStyle(Color.dsTextSecondary)
            Text(text)
                .font(.dsBody)
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dsSpacing)
        .domainSurface(appearance)
    }

    private func kpiBlock(_ details: [SectionDetail]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), alignment: .top),
                                 count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: .dsSpacingSm) {
            ForEach(details, id: \.self) { detail in
                DomainValueCard(title: LocalizedStringKey(detail.label), value: detail.value,
                                icon: detail.trend == "up" ? "arrow.up.right" : detail.trend == "down" ? "arrow.down.right" : appearance.icon,
                                appearance: appearance, note: detail.note)
            }
        }
    }

    @ViewBuilder
    private func chartBlock(_ c: SectionChart) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            Text(c.label)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.dsText)

            if c.virtual == true {
                readinessChartView(color: parseColor(c.color))
            } else if c.stacked == true {
                sleepStagesChartView()
            } else if let metric = c.metric {
                metricChartView(metric: metric, color: parseColor(c.color), isBar: c.type == "bar")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dsSpacing)
        .domainSurface(appearance)
    }

    @ViewBuilder
    private func readinessChartView(color: Color) -> some View {
        let points = readinessHistory.compactMap { point -> (id: String, date: Date, score: Int)? in
            guard let date = Self.chartDate(point.date) else { return nil }
            return (point.id, date, point.score)
        }
        if points.isEmpty {
            chartPlaceholder
        } else {
            Chart(points, id: \.id) { p in
                LineMark(x: .value("Date", p.date),
                         y: .value("Score", p.score))
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("Date", p.date),
                         y: .value("Score", p.score))
                    .foregroundStyle(color.opacity(0.10))
                    .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.dsBorder)
                    AxisValueLabel().foregroundStyle(Color.dsTextSecondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: dynamicTypeSize.isAccessibilitySize ? 2 : 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.dsBorder)
                    AxisValueLabel(format: dynamicTypeSize.isAccessibilitySize ? .dateTime.day().month(.twoDigits) : .dateTime.day().month(.abbreviated))
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            .frame(height: 160)
        }
    }

    @ViewBuilder
    private func sleepStagesChartView() -> some View {
        let points = stagePoints
        if points.isEmpty {
            chartPlaceholder
        } else {
            Chart(points) { p in
                BarMark(x: .value("Date", p.date, unit: .day),
                        y: .value("Hours", p.hours), width: .ratio(0.8))
                    .foregroundStyle(by: .value("Stage", p.stage))
            }
            .chartForegroundStyleScale([
                "Deep":   Color.dsSleep,
                "Core":   Color.dsSleepStageCore,
                "REM":    Color.dsCardio,
                "Asleep": Color.dsSleepUnspecified,
                "Awake":  Color.dsSleepStageAwake,
            ])
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.dsBorder)
                    AxisValueLabel().foregroundStyle(Color.dsTextSecondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: dynamicTypeSize.isAccessibilitySize ? 2 : 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.dsBorder)
                    AxisValueLabel(format: dynamicTypeSize.isAccessibilitySize ? .dateTime.day().month(.twoDigits) : .dateTime.day().month(.abbreviated))
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            .frame(height: 180)
            SleepStageLegend(hasUnspecified: points.contains { $0.stage == "Asleep" && $0.hours > 0 })
        }
    }

    @ViewBuilder
    private func metricChartView(metric: String, color: Color, isBar: Bool) -> some View {
        let points = (pointsByMetric[metric] ?? []).compactMap { point -> (id: String, date: Date, qty: Double)? in
            guard let date = Self.chartDate(point.date) else { return nil }
            return (point.date, date, point.qty)
        }
        if points.isEmpty {
            chartPlaceholder
        } else {
            Chart(points, id: \.id) { p in
                if isBar {
                    BarMark(x: .value("Date", p.date, unit: .day),
                            y: .value("Value", p.qty), width: .ratio(0.8))
                        .foregroundStyle(color)
                } else {
                    LineMark(x: .value("Date", p.date),
                             y: .value("Value", p.qty))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("Date", p.date),
                             y: .value("Value", p.qty))
                        .foregroundStyle(color.opacity(0.10))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.dsBorder)
                    AxisValueLabel().foregroundStyle(Color.dsTextSecondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: dynamicTypeSize.isAccessibilitySize ? 2 : 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.dsBorder)
                    AxisValueLabel(format: dynamicTypeSize.isAccessibilitySize ? .dateTime.day().month(.twoDigits) : .dateTime.day().month(.abbreviated))
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            .chartPlotStyle { plot in plot.clipped() }
            .dsChartYScale(domain: DashboardChartScale.domain(
                for: metric,
                values: points.map(\.qty),
                isBar: isBar
            ))
            .frame(height: 160)
        }
    }

    private var chartPlaceholder: some View {
        Text("No data in this range.")
            .font(.dsCaption)
            .foregroundStyle(Color.dsTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 100)
    }

    private var stagePoints: [SleepStageChartPoint] {
        var out: [SleepStageChartPoint] = []
        for n in sleepNights {
            guard let date = Self.chartDate(n.date) else { continue }
            out.append(SleepStageChartPoint(id: "\(n.date)-deep", date: date, stage: "Deep", hours: n.deep))
            out.append(SleepStageChartPoint(id: "\(n.date)-core", date: date, stage: "Core", hours: n.core))
            out.append(SleepStageChartPoint(id: "\(n.date)-rem", date: date, stage: "REM", hours: n.rem))
            // 5th band — mirrors SleepView. Server-driven sleep section
            // chart was silently dropping coarse-only nights' hours
            // before this row was added (Codex review on PR #11).
            out.append(SleepStageChartPoint(id: "\(n.date)-unspecified", date: date, stage: "Asleep", hours: n.unspecified))
            out.append(SleepStageChartPoint(id: "\(n.date)-awake", date: date, stage: "Awake", hours: n.awake))
        }
        return out
    }

    // "How it works" — server-curated educational text. Real value of this view.
    private func explainsBlock(_ explains: [SectionExplain]) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            Text("How it works").font(.dsBody.weight(.semibold)).foregroundStyle(Color.dsText)
            VStack(spacing: .dsSpacingSm) {
                ForEach(explains, id: \.self) { e in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(e.title)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.dsText)
                        Text(e.body)
                            .font(.dsBodySm)
                            .foregroundStyle(Color.dsTextSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.dsSpacing)
                    .domainSurface(appearance)
                }
            }
        }
    }

    private func errorBlock(_ err: String) -> some View {
        VStack(spacing: .dsSpacingSm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Color.dsDanger)
            Text(LocalizedStringKey(err))
                .font(.dsBodySm)
                .foregroundStyle(Color.dsDanger)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Load

    private func load() async {
        let requestGeneration = UUID()
        chartLoadGeneration = requestGeneration
        isLoading = true
        loadError = nil
        async let overview: Void = loadRecoveryOverview(generation: requestGeneration)
        do {
            let s = try await ServerClient.shared.section(sectionKey)
            guard !Task.isCancelled, requestGeneration == chartLoadGeneration else { return }
            self.section = s
            await loadCharts(for: s, days: days, generation: requestGeneration)
        } catch {
            guard requestGeneration == chartLoadGeneration else { return }
            loadError = error.localizedDescription
        }
        await overview
        if requestGeneration == chartLoadGeneration {
            isLoading = false
        }
    }

    private func loadRecoveryOverview(generation: UUID) async {
        guard sectionKey == "recovery" else { return }
        let value = try? await ServerClient.shared.healthBriefing()
        guard !Task.isCancelled, generation == chartLoadGeneration else { return }
        recoveryBriefing = value
    }

    private func loadChartsForSelectedRange() async {
        guard let section else { return }
        let requestGeneration = UUID()
        chartLoadGeneration = requestGeneration
        isLoading = true
        await loadCharts(for: section, days: days, generation: requestGeneration)
        if requestGeneration == chartLoadGeneration {
            isLoading = false
        }
    }

    /// Sum type for the chart-data fetcher results. Sendable so it travels
    /// cleanly through TaskGroup under Swift 6 strict concurrency.
    private enum ChartChunk: Sendable {
        case readiness([ReadinessPoint])
        case sleepStages([SleepNight])
        case metric(String, [DataPoint])
    }

    private struct ChartPayload: Sendable {
        var readinessHistory: [ReadinessPoint] = []
        var sleepNights: [SleepNight] = []
        var pointsByMetric: [String: [DataPoint]] = [:]
    }

    private struct SleepStageChartPoint: Identifiable {
        let id: String
        let date: Date
        let stage: String
        let hours: Double
    }

    /// Fetch the time series data for each chart in parallel. Readiness and
    /// sleep stages have their own dedicated endpoints; everything else maps
    /// to /api/metrics/data. Per-chart failures are swallowed so one bad
    /// fetch doesn't blank the whole page.
    private func loadCharts(for s: SectionResponse, days: Int, generation: UUID) async {
        let payload = await fetchChartPayload(for: s, days: days)
        guard !Task.isCancelled, generation == chartLoadGeneration else { return }
        readinessHistory = payload.readinessHistory
        sleepNights = payload.sleepNights
        pointsByMetric = payload.pointsByMetric
    }

    /// Collect all range data before applying it. A generation guard at the
    /// call site prevents an older picker request from repainting a newer one.
    private func fetchChartPayload(for s: SectionResponse, days: Int) async -> ChartPayload {
        let cal = Calendar(identifier: .gregorian)
        let now = Date.now
        let to = isoDate(now)
        let from = isoDate(cal.date(byAdding: .day, value: -(days - 1), to: now) ?? now)

        var payload = ChartPayload()
        await withTaskGroup(of: ChartChunk?.self) { group in
            for chart in s.charts {
                if chart.virtual == true {
                    group.addTask {
                        let pts = (try? await ServerClient.shared.readinessHistory(days: days)) ?? []
                        return .readiness(pts)
                    }
                } else if chart.stacked == true {
                    group.addTask {
                        let nights = (try? await Self.loadSleepStages(from: from, to: to)) ?? []
                        return .sleepStages(nights)
                    }
                } else if let metric = chart.metric {
                    group.addTask {
                        let resp = try? await ServerClient.shared.metricData(
                            name: metric, from: from, to: to, bucket: "day"
                        )
                        return .metric(metric, resp?.points ?? [])
                    }
                } else {
                    group.addTask { nil }
                }
            }
            for await chunk in group {
                switch chunk {
                case .readiness(let pts):           payload.readinessHistory = pts
                case .sleepStages(let nights):      payload.sleepNights = nights
                case .metric(let m, let pts):       payload.pointsByMetric[m] = pts
                case .none:                         break
                }
            }
        }
        return payload
    }

    private static func loadSleepStages(from: String, to: String) async throws -> [SleepNight] {
        async let totalT        = ServerClient.shared.metricData(name: "sleep_total",        from: from, to: to, bucket: "day")
        async let deepT         = ServerClient.shared.metricData(name: "sleep_deep",         from: from, to: to, bucket: "day")
        async let remT          = ServerClient.shared.metricData(name: "sleep_rem",          from: from, to: to, bucket: "day")
        async let coreT         = ServerClient.shared.metricData(name: "sleep_core",         from: from, to: to, bucket: "day")
        async let unspecifiedT  = ServerClient.shared.metricData(name: "sleep_unspecified",  from: from, to: to, bucket: "day")
        async let awakeT        = ServerClient.shared.metricData(name: "sleep_awake",        from: from, to: to, bucket: "day")
        // sleep_unspecified is non-fatal on pre-v2.3 servers; `try?`
        // swallows the 404 so older deployments still render the chart.
        let (totalR, deepR, remR, coreR, awakeR) = try await (totalT, deepT, remT, coreT, awakeT)
        let unspecifiedR = try? await unspecifiedT

        func index(_ pts: [DataPoint]?) -> [String: Double] {
            var d: [String: Double] = [:]
            for p in pts ?? [] { d[p.date] = p.qty }
            return d
        }
        let t = index(totalR.points)
        let dp = index(deepR.points)
        let rm = index(remR.points)
        let co = index(coreR.points)
        let un = index(unspecifiedR?.points)
        let aw = index(awakeR.points)
        let dates = Set(t.keys).union(dp.keys).union(rm.keys).union(co.keys).union(un.keys).union(aw.keys)
        return dates.sorted().map { date in
            SleepNight(
                date: date,
                total:       t[date]  ?? 0,
                deep:        dp[date] ?? 0,
                rem:         rm[date] ?? 0,
                core:        co[date] ?? 0,
                unspecified: un[date] ?? 0,
                awake:       aw[date] ?? 0
            )
        }
    }

    // MARK: - Helpers

    /// Section APIs return day buckets as ISO date strings. Feeding those
    /// strings directly to Charts makes X categorical and produces one
    /// overlapping label per sample. Date values preserve the real time axis.
    private static func chartDate(_ raw: String) -> Date? {
        try? Date(raw, strategy: .iso8601.year().month().day())
    }

    private func trendColor(_ trend: String?) -> Color {
        switch trend {
        case "up", "positive": return .dsGood
        case "down", "negative": return .dsDanger
        case "stable": return .dsTextSecondary
        default: return .dsTextSecondary
        }
    }

    /// Parse "#rrggbb" hex from server. Falls back to the domain accent.
    private func parseColor(_ hex: String?) -> Color {
        guard let hex, hex.hasPrefix("#"), hex.count == 7 else { return appearance.accent }
        let scanner = Scanner(string: String(hex.dropFirst()))
        var rgb: UInt64 = 0
        guard scanner.scanHexInt64(&rgb) else { return appearance.accent }
        return Color(
            .sRGB,
            red:   Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8)  & 0xff) / 255,
            blue:  Double(rgb         & 0xff) / 255,
            opacity: 1
        )
    }

    private func isoDate(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

private struct RecoveryInsightLifecycle: ViewModifier {
    let controller: TodayInsightsController
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.insightLifecycle(controller) } else { content }
    }
}
