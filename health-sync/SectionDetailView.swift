import SwiftUI
import Charts

/// Detail view for a Health overview section (recovery / sleep / activity /
/// cardio). Mirrors the web section page: summary → KPI details → curated
/// charts → "How it works" explainer cards. All content (including text and
/// chart picks) comes from `/api/section/{key}` so the server stays the
/// single source of truth for explanations.
struct SectionDetailView: View {
    let sectionKey: String

    @State private var section: SectionResponse?
    @State private var pointsByMetric: [String: [DataPoint]] = [:]
    @State private var readinessHistory: [ReadinessPoint] = []
    @State private var sleepNights: [SleepNight] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .dsSpacingLg) {
                if isLoading && section == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if let err = loadError, section == nil {
                    errorBlock(err)
                } else if let s = section {
                    if !s.summary.isEmpty {
                        summaryBlock(s.summary)
                    }
                    if !s.details.isEmpty {
                        kpiBlock(s.details)
                    }
                    ForEach(Array(s.charts.enumerated()), id: \.offset) { _, chart in
                        chartBlock(chart)
                    }
                    if !s.explains.isEmpty {
                        explainsBlock(s.explains)
                    }
                }
            }
            .padding(.dsSpacing)
        }
        .background(Color.dsBackground)
        .navigationTitle(section.map { LocalizedStringKey($0.title) } ?? LocalizedStringKey(sectionKey.capitalized))
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - Blocks

    private func summaryBlock(_ text: String) -> some View {
        Text(text)
            .font(.dsBody)
            .foregroundStyle(Color.dsTextSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func kpiBlock(_ details: [SectionDetail]) -> some View {
        VStack(spacing: 6) {
            ForEach(details, id: \.self) { d in
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(trendColor(d.trend))
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
        }
    }

    @ViewBuilder
    private func chartBlock(_ c: SectionChart) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            Text(c.label)
                .font(.dsSubhead)
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
        .dsCard()
    }

    @ViewBuilder
    private func readinessChartView(color: Color) -> some View {
        if readinessHistory.isEmpty {
            chartPlaceholder
        } else {
            Chart(readinessHistory) { p in
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
            .frame(height: 160)
        }
    }

    @ViewBuilder
    private func sleepStagesChartView() -> some View {
        if sleepNights.isEmpty {
            chartPlaceholder
        } else {
            Chart(stagePoints, id: \.id) { p in
                BarMark(x: .value("Date", p.date),
                        y: .value("Hours", p.hours))
                    .foregroundStyle(by: .value("Stage", p.stage))
            }
            .chartForegroundStyleScale([
                "Deep":  Color.dsSleep,
                "Core":  Color.dsAccent,
                "REM":   Color.dsCardio,
                "Awake": Color.dsTextTertiary,
            ])
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 180)
        }
    }

    @ViewBuilder
    private func metricChartView(metric: String, color: Color, isBar: Bool) -> some View {
        let points = pointsByMetric[metric] ?? []
        if points.isEmpty {
            chartPlaceholder
        } else {
            Chart(points, id: \.date) { p in
                if isBar {
                    BarMark(x: .value("Date", p.date),
                            y: .value("Value", p.qty))
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
            .frame(height: 160)
        }
    }

    private var chartPlaceholder: some View {
        Text("No data in this range.")
            .font(.dsCaption)
            .foregroundStyle(Color.dsTextTertiary)
            .frame(maxWidth: .infinity, minHeight: 100)
    }

    private var stagePoints: [(id: String, date: String, stage: String, hours: Double)] {
        var out: [(id: String, date: String, stage: String, hours: Double)] = []
        for n in sleepNights {
            out.append((id: "\(n.date)-deep",  date: n.date, stage: "Deep",  hours: n.deep))
            out.append((id: "\(n.date)-core",  date: n.date, stage: "Core",  hours: n.core))
            out.append((id: "\(n.date)-rem",   date: n.date, stage: "REM",   hours: n.rem))
            out.append((id: "\(n.date)-awake", date: n.date, stage: "Awake", hours: n.awake))
        }
        return out
    }

    // "How it works" — server-curated educational text. Real value of this view.
    private func explainsBlock(_ explains: [SectionExplain]) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            SectionHeader(title: "How it works")
            VStack(spacing: .dsSpacingSm) {
                ForEach(explains, id: \.self) { e in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(e.title)
                            .font(.dsSubhead)
                            .foregroundStyle(Color.dsText)
                        Text(e.body)
                            .font(.dsBodySm)
                            .foregroundStyle(Color.dsTextSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.dsSpacing)
                    .dsCard()
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
        isLoading = true
        loadError = nil
        do {
            let s = try await ServerClient.shared.section(sectionKey)
            self.section = s
            await loadCharts(for: s)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Sum type for the chart-data fetcher results. Sendable so it travels
    /// cleanly through TaskGroup under Swift 6 strict concurrency.
    private enum ChartChunk: Sendable {
        case readiness([ReadinessPoint])
        case sleepStages([SleepNight])
        case metric(String, [DataPoint])
    }

    /// Fetch the time series data for each chart in parallel. Readiness and
    /// sleep stages have their own dedicated endpoints; everything else maps
    /// to /api/metrics/data. Per-chart failures are swallowed so one bad
    /// fetch doesn't blank the whole page.
    private func loadCharts(for s: SectionResponse) async {
        let cal = Calendar(identifier: .gregorian)
        let to = isoDate(Date())
        let from = isoDate(cal.date(byAdding: .day, value: -29, to: Date()) ?? Date())

        await withTaskGroup(of: ChartChunk?.self) { group in
            for chart in s.charts {
                if chart.virtual == true {
                    group.addTask {
                        let pts = (try? await ServerClient.shared.readinessHistory(days: 30)) ?? []
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
                case .readiness(let pts):           readinessHistory = pts
                case .sleepStages(let nights):      sleepNights = nights
                case .metric(let m, let pts):       pointsByMetric[m] = pts
                case .none:                         break
                }
            }
        }
    }

    private static func loadSleepStages(from: String, to: String) async throws -> [SleepNight] {
        async let totalT = ServerClient.shared.metricData(name: "sleep_total", from: from, to: to, bucket: "day")
        async let deepT  = ServerClient.shared.metricData(name: "sleep_deep",  from: from, to: to, bucket: "day")
        async let remT   = ServerClient.shared.metricData(name: "sleep_rem",   from: from, to: to, bucket: "day")
        async let coreT  = ServerClient.shared.metricData(name: "sleep_core",  from: from, to: to, bucket: "day")
        async let awakeT = ServerClient.shared.metricData(name: "sleep_awake", from: from, to: to, bucket: "day")
        let (totalR, deepR, remR, coreR, awakeR) = try await (totalT, deepT, remT, coreT, awakeT)

        func index(_ pts: [DataPoint]?) -> [String: Double] {
            var d: [String: Double] = [:]
            for p in pts ?? [] { d[p.date] = p.qty }
            return d
        }
        let t = index(totalR.points)
        let dp = index(deepR.points)
        let rm = index(remR.points)
        let co = index(coreR.points)
        let aw = index(awakeR.points)
        let dates = Set(t.keys).union(dp.keys).union(rm.keys).union(co.keys).union(aw.keys)
        return dates.sorted().map { date in
            SleepNight(
                date: date,
                total: t[date] ?? 0,
                deep:  dp[date] ?? 0,
                rem:   rm[date] ?? 0,
                core:  co[date] ?? 0,
                awake: aw[date] ?? 0
            )
        }
    }

    // MARK: - Helpers

    private func trendColor(_ trend: String?) -> Color {
        switch trend {
        case "up", "positive": return .dsGood
        case "down", "negative": return .dsDanger
        case "stable": return .dsTextTertiary
        default: return .dsTextTertiary
        }
    }

    /// Parse "#rrggbb" hex from server. Falls back to dsAccent.
    private func parseColor(_ hex: String?) -> Color {
        guard let hex, hex.hasPrefix("#"), hex.count == 7 else { return .dsAccent }
        let scanner = Scanner(string: String(hex.dropFirst()))
        var rgb: UInt64 = 0
        guard scanner.scanHexInt64(&rgb) else { return .dsAccent }
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
