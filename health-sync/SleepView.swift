import SwiftUI
import Charts

/// One night's sleep breakdown. Values are hours (server's SleepAnalysis
/// convention — see internal/ui/handler.go::fmtMinutes calls with `* 60`).
struct SleepNight: Identifiable, Hashable, Sendable {
    let date: String
    let total: Double
    let deep: Double
    let rem: Double
    let core: Double
    /// Coarse asleep time from sources without per-stage tracking
    /// (RingConn, iPhone Sleep Schedule, older Apple Watch). Server v2.3+
    /// surfaces this as a dedicated metric (not folded into core). Zero
    /// on Apple-Watch-with-stages nights; non-zero on stage-less sources.
    let unspecified: Double
    let awake: Double

    var id: String { date }

    /// Asleep time divided by the full in-bed window, capped to 0–100.
    var efficiency: Double? {
        let inBed = total + awake
        guard inBed > 0 else { return nil }
        return min(100, max(0, total / inBed * 100))
    }
}

/// Flattened (date, stage, hours) point used for stacked-bar plotting. Swift
/// Charts stacks BarMark automatically when foregroundStyle(by:) is set.
private struct SleepStagePoint: Identifiable {
    let id = UUID()
    let date: Date
    let stage: String
    let hours: Double
}

private struct SleepSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color.dsSurface)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.dsBorder, lineWidth: 1)
            }
    }
}

private extension View {
    func sleepSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(SleepSurface(cornerRadius: cornerRadius))
    }
}

struct SleepView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var todayInsights = TodayInsightsController()
    @State private var loadGeneration = UUID()
    @State private var nights: [SleepNight] = []
    @State private var lastNightSource: String?
    @State private var days: Int = 30
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var lastLoadedAt: Date?

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                let contentWidth = max(0, viewport.size.width - (2 * .dsSpacing))
                ZStack(alignment: .top) {
                    DomainBackdrop(appearance: .sleep)
                        .ignoresSafeArea()

                    ScrollView {
                        VStack(spacing: .dsSpacingLg) {
                            if let loadError, !nights.isEmpty {
                                SyncRefreshBanner(message: loadError, lastLoadedAt: lastLoadedAt) {
                                    Task { await load() }
                                }
                            }
                            if nights.isEmpty {
                                DomainPageHeader(title: String(localized: "Sleep"))
                                    .domainHero(.sleep)
                                DomainInsightSection(controller: todayInsights, slot: "sleep", appearance: .sleep)
                            }
                            if isLoading && nights.isEmpty {
                                ProgressView().padding(.top, 60)
                            } else if let err = loadError, nights.isEmpty {
                                emptyState(LocalizedStringKey(err), isError: true)
                            } else if nights.isEmpty {
                                emptyState("No sleep data yet.", isError: false)
                            } else if let last = nights.last {
                                VStack(spacing: .dsSpacingLg) {
                                    DomainPageHeader(title: String(localized: "Sleep"), date: last.date)
                                    DomainGauge(value: last.efficiency.map { "\(Int($0.rounded()))%" } ?? "—",
                                                label: "Sleep efficiency", fraction: last.efficiency.map { $0 / 100 }, appearance: .sleep)
                                        .accessibilityIdentifier("domain-hero-sleep")
                                }.domainHero(.sleep)
                                sleepHero(last)
                                DomainInsightSection(controller: todayInsights, slot: "sleep", appearance: .sleep)
                                sleepStructureCard(last)
                                if let source = lastNightSource {
                                    sourceCard(source, night: last)
                                }
                                chartCard
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
            .refreshable {
                async let charts: Void = load()
                async let insights: Void = todayInsights.refresh()
                _ = await (charts, insights)
            }
            .task { await load() }
        }
        .insightLifecycle(todayInsights)
    }

    // MARK: - Last night

    @ViewBuilder
    private func sleepHero(_ n: SleepNight) -> some View {
        VStack(spacing: .dsSpacing) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: .dsSpacingSm)) : AnyLayout(HStackLayout(spacing: .dsSpacingSm))
            layout {
                DomainValueCard(title: "Sleep time", value: formatHours(n.total), icon: "moon.stars.fill", appearance: .sleep)
                DomainValueCard(title: "Awake", value: formatHours(n.awake), icon: "wake", appearance: .sleep)
            }
        }
    }

    private func sleepStructureCard(_ n: SleepNight) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            Label("Sleep structure", systemImage: "chart.bar.fill")
                .font(.dsBody.weight(.semibold))
                .foregroundStyle(Color.dsText)

            GeometryReader { geometry in
                let segmentCount = n.unspecified > 0 ? 5 : 4
                let availableWidth = max(0, geometry.size.width - CGFloat(segmentCount - 1) * 2)
                HStack(spacing: 2) {
                    sleepBand(n.deep, duration: n.total + n.awake, availableWidth: availableWidth, color: .dsSleep)
                    sleepBand(n.rem, duration: n.total + n.awake, availableWidth: availableWidth, color: .dsCardio)
                    sleepBand(n.core, duration: n.total + n.awake, availableWidth: availableWidth, color: .dsSleepStageCore)
                    if n.unspecified > 0 {
                        sleepBand(n.unspecified, duration: n.total + n.awake, availableWidth: availableWidth, color: .dsSleepUnspecified)
                    }
                    sleepBand(n.awake, duration: n.total + n.awake, availableWidth: availableWidth, color: .dsSleepStageAwake)
                }
                .frame(width: geometry.size.width, height: 12)
                .clipShape(Capsule())
            }
            .frame(height: 12)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), alignment: .leading), count: dynamicTypeSize >= .xxxLarge ? 1 : 2), alignment: .leading, spacing: .dsSpacingSm) {
                sleepStageLabel("Deep", value: n.deep, color: .dsSleep)
                sleepStageLabel("REM", value: n.rem, color: .dsCardio)
                sleepStageLabel("Core", value: n.core, color: .dsSleepStageCore)
                if n.unspecified > 0 {
                    sleepStageLabel("Asleep", value: n.unspecified, color: .dsSleepUnspecified)
                }
                sleepStageLabel("Awake", value: n.awake, color: .dsSleepStageAwake)
            }
        }
        .padding(.dsSpacing)
        .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.dsBorder, lineWidth: 1))
    }

    private func sleepBand(_ value: Double, duration: Double, availableWidth: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: availableWidth * value / max(duration, 0.01))
    }

    private func sleepStageLabel(_ label: LocalizedStringKey, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.dsCaption).fixedSize(horizontal: false, vertical: true)
            }
            Text(formatHours(value))
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextSecondary)
        }
        .foregroundStyle(Color.dsText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stageCell(label: LocalizedStringKey, value: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.dsCaption)
                .foregroundStyle(color)
            Text(formatHours(value))
                .font(.dsBodySm.weight(.medium))
                .foregroundStyle(Color.dsText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, .dsSpacingSm)
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            VStack(alignment: .leading, spacing: .dsSpacingSm) {
                Text("Trend")
                    .accessibilityIdentifier("sleep-trend-title")
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(Color.dsText)
                SleepRangePicker(days: $days) {
                    Task { await load() }
                }
            }

            Chart(stagePoints) { p in
                BarMark(
                    x: .value("Date", p.date, unit: .day),
                    y: .value("Hours", p.hours),
                    width: .ratio(0.8)
                )
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
            .chartXAxis {
                if !dynamicTypeSize.isAccessibilitySize {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.dsBorder)
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 4, 8, 12]) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.dsBorder)
                    AxisValueLabel()
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            .frame(height: 220)

            VStack(alignment: .leading, spacing: .dsSpacingSm) {
                if dynamicTypeSize.isAccessibilitySize,
                   let first = stagePoints.first?.date, let last = stagePoints.last?.date {
                    Text("\(first, format: .dateTime.day().month(.abbreviated)) – \(last, format: .dateTime.day().month(.abbreviated))")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Last \(days) days")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)

                SleepStageLegend(hasUnspecified: nights.contains { $0.unspecified > 0 }, nightStyle: false)
            }
        }
        .padding(.dsSpacing)
        .sleepSurface()
    }

    private var stagePoints: [SleepStagePoint] {
        var out: [SleepStagePoint] = []
        out.reserveCapacity(nights.count * 5)
        for n in nights {
            guard let date = try? Date(n.date, strategy: .iso8601.year().month().day()) else { continue }
            out.append(.init(date: date, stage: "Deep",   hours: n.deep))
            out.append(.init(date: date, stage: "Core",   hours: n.core))
            out.append(.init(date: date, stage: "REM",    hours: n.rem))
            // Stack order: Deep → Core → REM → Asleep (unspecified) → Awake.
            // The new band sits next to Awake so it visually reads as
            // "still real sleep, just not classified" rather than mixed in
            // with the stage stack.
            out.append(.init(date: date, stage: "Asleep", hours: n.unspecified))
            out.append(.init(date: date, stage: "Awake",  hours: n.awake))
        }
        return out
    }

    // MARK: - Empty / error

    /// Tiny "data from <device>" footer under the last-night card. Helpful
    /// when you wear both an Apple Watch and a smart ring — at a glance you
    /// see which one the server cross-validated to. Chosen as the source
    /// with the largest sleep_total contribution on the most recent night.
    private func sourceCard(_ source: String, night: SleepNight?) -> some View {
        // "Stages not measured" hint surfaces when the picked source for the
        // last night reported coarse asleep time but no per-stage breakdown
        // — RingConn, iPhone Sleep Schedule, older Apple Watch. Makes it
        // obvious to a two-device user *why* the night's chart row looks
        // different from their staged Watch nights. Stays hidden for
        // normal Apple-Watch-with-stages nights.
        let noStages = (night?.unspecified ?? 0) > 0
            && (night?.deep ?? 0) == 0
            && (night?.rem ?? 0) == 0
            && (night?.core ?? 0) == 0
        return HStack(spacing: 8) {
            Image(systemName: sourceIcon(for: source))
                .foregroundStyle(Color.dsTextSecondary)
                .frame(width: 18)
            Text("Source")
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextSecondary)
            Text(source)
                .font(.dsCaption.weight(.medium))
                .foregroundStyle(Color.dsText)
            if noStages {
                Text("· stages not measured")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sleepSurface(cornerRadius: 14)
    }

    private func sourceIcon(for source: String) -> String {
        let s = source.lowercased()
        if s.contains("watch") || s.contains("ultra") { return "applewatch" }
        if s.contains("ring") { return "circle.dashed" }
        if s.contains("iphone") { return "iphone" }
        return "applewatch"
    }

    private func emptyState(_ message: LocalizedStringKey, isError: Bool) -> some View {
        VStack(spacing: .dsSpacingSm) {
            Image(systemName: isError ? "exclamationmark.triangle" : "moon.zzz")
                .font(.system(size: 40))
                .foregroundStyle(isError ? Color.dsDanger : Color.dsTextSecondary)
            Text(message)
                .font(.dsBodySm)
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Load

    private func load() async {
        if InsightFixtures.enabled {
            nights = InsightFixtures.sleepNights(days: days)
            return
        }
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        loadError = nil

        let cal = Calendar(identifier: .gregorian)
        let to = isoDate(Date())
        let from = isoDate(cal.date(byAdding: .day, value: -days, to: Date()) ?? Date())
        let lastFrom = isoDate(cal.date(byAdding: .day, value: -2, to: Date()) ?? Date())

        do {
            async let totalT        = ServerClient.shared.metricData(name: "sleep_total",        from: from, to: to, bucket: "day")
            async let deepT         = ServerClient.shared.metricData(name: "sleep_deep",         from: from, to: to, bucket: "day")
            async let remT          = ServerClient.shared.metricData(name: "sleep_rem",          from: from, to: to, bucket: "day")
            async let coreT         = ServerClient.shared.metricData(name: "sleep_core",         from: from, to: to, bucket: "day")
            async let unspecifiedT  = ServerClient.shared.metricData(name: "sleep_unspecified",  from: from, to: to, bucket: "day")
            async let awakeT        = ServerClient.shared.metricData(name: "sleep_awake",        from: from, to: to, bucket: "day")
            // Last-night-only by-source query — covers two days to handle
            // sleep that crosses midnight. Pick the source with the largest
            // contribution; failure is non-fatal (source row hides itself).
            async let sourceT = ServerClient.shared.metricData(
                name: "sleep_total", from: lastFrom, to: to, bucket: "day", bySource: true
            )

            // sleep_unspecified is non-fatal: pre-v2.3 servers don't know
            // the metric and 404 the request. `try?` swallows that so the
            // rest of the chart still renders on older deployments.
            let (totalR, deepR, remR, coreR, awakeR) = try await (totalT, deepT, remT, coreT, awakeT)
            let unspecifiedR = try? await unspecifiedT

            guard !Task.isCancelled, generation == loadGeneration else { return }
            nights = mergeNights(total: totalR.points,
                                 deep: deepR.points,
                                 rem: remR.points,
                                 core: coreR.points,
                                 unspecified: unspecifiedR?.points,
                                 awake: awakeR.points)
            lastLoadedAt = Date()

            if let sourceR = try? await sourceT {
                guard !Task.isCancelled, generation == loadGeneration else { return }
                lastNightSource = dominantSource(from: sourceR.pointsBySource)
            } else {
                lastNightSource = nil
            }
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            loadError = error.localizedDescription
        }
        if generation == loadGeneration { isLoading = false }
    }

    /// Pick the source with the largest sleep_total contribution across the
    /// returned points. Server already cross-validates between Apple Watch
    /// and ring sources for the daily aggregate; here we just surface which
    /// one dominated for the latest day with data.
    private func dominantSource(from groups: [SourceDataPoints]?) -> String? {
        guard let groups, !groups.isEmpty else { return nil }
        var best: (name: String, total: Double) = ("", 0)
        for g in groups {
            let total = (g.points.map(\.qty).max() ?? 0)  // most-recent day in this source
            if total > best.total {
                best = (g.source, total)
            }
        }
        return best.total > 0 ? best.name : nil
    }

    private func mergeNights(total: [DataPoint]?,
                             deep: [DataPoint]?,
                             rem: [DataPoint]?,
                             core: [DataPoint]?,
                             unspecified: [DataPoint]?,
                             awake: [DataPoint]?) -> [SleepNight] {
        func index(_ pts: [DataPoint]?) -> [String: Double] {
            var d: [String: Double] = [:]
            for p in pts ?? [] { d[p.date] = p.qty }
            return d
        }
        let t = index(total)
        let dp = index(deep)
        let rm = index(rem)
        let co = index(core)
        let un = index(unspecified)
        let aw = index(awake)
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

    // MARK: - Formatting

    private func isoDate(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "Xh Ym" / "Ym" — values in hours, localized via "%lldh %lldm" /
    /// "%lldm" catalog keys.
    private func formatHours(_ hours: Double) -> String {
        let totalMin = Int((hours * 60).rounded())
        let h = totalMin / 60
        let m = totalMin % 60
        if h > 0 {
            return String(localized: "\(h)h \(m)m")
        }
        return String(localized: "\(m)m")
    }
}

private struct SleepRangePicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var days: Int
    let didChange: () -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach([7, 30, 90], id: \.self) { range in
                Button("\(range)d") { days = range }
                    .accessibilityIdentifier("sleep-range-\(range)")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(range == days ? Color.dsBackground : Color.dsTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(range == days ? Color.dsSleep : Color.dsSurface2, in: Capsule())
            }
        }
        .padding(3)
        .background(Color.dsSurface2, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.dsBorder, lineWidth: 1))
        .onChange(of: days) { _, _ in didChange() }
    }
}

#Preview {
    SleepView()
}
