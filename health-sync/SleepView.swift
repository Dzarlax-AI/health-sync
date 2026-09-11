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

private struct SleepNightBackdrop: View {
    var body: some View {
        ZStack {
            Color.dsSleepNightBackground
            LinearGradient(
                colors: [.dsSleepNightTop, .dsSleepNightBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [.dsSleep.opacity(0.22), .dsSleepNightBackground.opacity(0)],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 380
            )
        }
    }
}

private struct SleepPageHeader: View {
    let date: String

    var body: some View {
        VStack(spacing: 2) {
            Text("Sleep")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.dsSleepNightText)
            Text(verbatim: formattedDate)
                .font(.dsBodySm)
                .foregroundStyle(Color.dsSleepNightTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var formattedDate: String {
        guard let parsed = try? Date(date, strategy: .iso8601.year().month().day()) else { return date }
        return parsed.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

private struct SleepEfficiencyRing: View {
    let efficiency: Double?

    private var value: Int? { efficiency.map { Int($0.rounded()) } }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.dsSleepNightSurface.opacity(0.88))
                .overlay(Circle().stroke(Color.dsSleepNightBorder, lineWidth: 1))
            Circle()
                .stroke(Color.dsSleepNightText.opacity(0.12), lineWidth: 18)
                .padding(9)
            Circle()
                .trim(from: 0, to: CGFloat(value ?? 0) / 100)
                .stroke(
                    AngularGradient(colors: [.dsSleep, .dsCardio, .dsSleep], center: .center),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(9)
            VStack(spacing: .dsSpacingXs) {
                Text(value.map { "\($0)%" } ?? "--")
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.dsSleepNightText)
                Text("Sleep efficiency")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(Color.dsSleepNightTextSecondary)
            }
        }
        .frame(width: 184, height: 184)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep efficiency")
        .accessibilityValue(value.map { "\($0) percent" } ?? "No data")
    }
}

private struct SleepSummaryValue: View {
    let icon: String
    let label: LocalizedStringKey
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            HStack(spacing: .dsSpacingSm) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.15), in: Circle())
                Text(label)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsSleepNightTextSecondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.dsSleepNightText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dsSpacing)
        .background(Color.dsSleepNightSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.dsSleepNightBorder, lineWidth: 1))
    }
}

private struct SleepSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color.dsSleepNightSurface.opacity(0.82))
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.dsSleepNightBorder, lineWidth: 1)
            }
    }
}

private extension View {
    func sleepSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(SleepSurface(cornerRadius: cornerRadius))
    }
}

struct SleepView: View {
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
                    SleepNightBackdrop()
                        .ignoresSafeArea()

                    ScrollView {
                        VStack(spacing: .dsSpacingLg) {
                            if let loadError, !nights.isEmpty {
                                SyncRefreshBanner(message: loadError, lastLoadedAt: lastLoadedAt) {
                                    Task { await load() }
                                }
                            }
                            if isLoading && nights.isEmpty {
                                ProgressView().padding(.top, 60)
                            } else if let err = loadError, nights.isEmpty {
                                emptyState(LocalizedStringKey(err), isError: true)
                            } else if nights.isEmpty {
                                emptyState("No sleep data yet.", isError: false)
                            } else if let last = nights.last {
                                SleepPageHeader(date: last.date)
                                sleepHero(last)
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
            .refreshable { await load() }
            .task { await load() }
        }
    }

    // MARK: - Last night

    @ViewBuilder
    private func sleepHero(_ n: SleepNight) -> some View {
        VStack(spacing: .dsSpacing) {
            SleepEfficiencyRing(efficiency: n.efficiency)
            HStack(spacing: .dsSpacingSm) {
                SleepSummaryValue(icon: "moon.stars.fill", label: "Sleep time", value: formatHours(n.total), tint: .dsSleep)
                SleepSummaryValue(icon: "wake", label: "Awake", value: formatHours(n.awake), tint: .dsSleepNightTextSecondary)
            }
        }
    }

    private func sleepStructureCard(_ n: SleepNight) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            Label("Sleep structure", systemImage: "chart.bar.fill")
                .font(.dsBody.weight(.semibold))
                .foregroundStyle(Color.dsSleepNightText)

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

            HStack(spacing: .dsSpacingSm) {
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
        .background(Color.dsSleepNightSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.dsSleepNightBorder, lineWidth: 1))
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
                Text(label).font(.dsCaption).lineLimit(1)
            }
            Text(formatHours(value))
                .font(.dsCaption)
                .foregroundStyle(Color.dsSleepNightTextSecondary)
        }
        .foregroundStyle(Color.dsSleepNightText)
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
            HStack {
                Text("Trend")
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(Color.dsSleepNightText)
                Spacer()
                SleepRangePicker(days: $days) {
                    Task { await load() }
                }
            }

            Chart(stagePoints) { p in
                BarMark(
                    x: .value("Date", p.date),
                    y: .value("Hours", p.hours)
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
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.dsSleepNightBorder)
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        .foregroundStyle(Color.dsSleepNightTextSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 4, 8, 12]) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.dsSleepNightBorder)
                    AxisValueLabel()
                        .foregroundStyle(Color.dsSleepNightTextSecondary)
                }
            }
            .frame(height: 220)
            .padding(.horizontal, .dsSpacing)

            VStack(alignment: .leading, spacing: .dsSpacingSm) {
                Text("Last \(days) days")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsSleepNightTextSecondary)

                HStack(spacing: 12) {
                    legendDot("Deep",   color: .dsSleep)
                    legendDot("Core",   color: .dsSleepStageCore)
                    legendDot("REM",    color: .dsCardio)
                    // Only legend the 5th band when any visible night has it —
                    // keeps the row tight for typical Apple Watch users.
                    if nights.contains(where: { $0.unspecified > 0 }) {
                        legendDot("Asleep", color: .dsSleepUnspecified)
                    }
                    legendDot("Awake",  color: .dsSleepStageAwake)
                    Spacer()
                }
            }
            .padding(.horizontal, .dsSpacing)
            .padding(.bottom, .dsSpacing)
        }
        .sleepSurface()
    }

    private func legendDot(_ label: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.dsCaption).foregroundStyle(Color.dsSleepNightTextSecondary)
        }
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
                .foregroundStyle(Color.dsSleepNightTextSecondary)
                .frame(width: 18)
            Text("Source")
                .font(.dsCaption)
                .foregroundStyle(Color.dsSleepNightTextSecondary)
            Text(source)
                .font(.dsCaption.weight(.medium))
                .foregroundStyle(Color.dsSleepNightText)
            if noStages {
                Text("· stages not measured")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsSleepNightTextSecondary)
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
                .foregroundStyle(isError ? Color.dsDanger : Color.dsTextTertiary)
            Text(message)
                .font(.dsBodySm)
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Load

    private func load() async {
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

            nights = mergeNights(total: totalR.points,
                                 deep: deepR.points,
                                 rem: remR.points,
                                 core: coreR.points,
                                 unspecified: unspecifiedR?.points,
                                 awake: awakeR.points)
            lastLoadedAt = Date()

            if let sourceR = try? await sourceT {
                lastNightSource = dominantSource(from: sourceR.pointsBySource)
            } else {
                lastNightSource = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
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
    @Binding var days: Int
    let didChange: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach([7, 30, 90], id: \.self) { range in
                Button("\(range)d") { days = range }
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(range == days ? Color.dsSleepNightText : Color.dsSleepNightTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(range == days ? Color.dsSleep : Color.dsSleepNightSurface.opacity(0.62), in: Capsule())
            }
        }
        .padding(3)
        .frame(width: 180)
        .background(Color.dsSleepNightBackground.opacity(0.62), in: Capsule())
        .overlay(Capsule().stroke(Color.dsSleepNightBorder, lineWidth: 1))
        .onChange(of: days) { _, _ in didChange() }
    }
}

#Preview {
    SleepView()
}
