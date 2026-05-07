import SwiftUI
import Charts

/// One night's sleep breakdown. Values are hours (server's SleepAnalysis
/// convention — see internal/ui/handler.go::fmtMinutes calls with `* 60`).
struct SleepNight: Identifiable, Hashable {
    let date: String
    let total: Double
    let deep: Double
    let rem: Double
    let core: Double
    let awake: Double

    var id: String { date }

    /// `(total - awake) / total` × 100, capped to 0–100; nil when total is 0.
    var efficiency: Double? {
        guard total > 0 else { return nil }
        return min(100, max(0, (total - awake) / total * 100))
    }
}

/// Flattened (date, stage, hours) point used for stacked-bar plotting. Swift
/// Charts stacks BarMark automatically when foregroundStyle(by:) is set.
private struct SleepStagePoint: Identifiable {
    let id = UUID()
    let date: String
    let stage: String
    let hours: Double
}

struct SleepView: View {
    @State private var nights: [SleepNight] = []
    @State private var lastNightSource: String?
    @State private var days: Int = 30
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: .dsSpacingLg) {
                    if isLoading && nights.isEmpty {
                        ProgressView().padding(.top, 60)
                    } else if let err = loadError, nights.isEmpty {
                        emptyState(LocalizedStringKey(err), isError: true)
                    } else if nights.isEmpty {
                        emptyState("No sleep data yet.", isError: false)
                    } else {
                        if let last = nights.last {
                            lastNightCard(last)
                        }
                        if let source = lastNightSource {
                            sourceCard(source)
                        }
                        chartCard
                    }
                }
                .padding(.dsSpacing)
            }
            .background(Color.dsBackground)
            .navigationTitle("Sleep")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
            .task { await load() }
        }
    }

    // MARK: - Last night

    @ViewBuilder
    private func lastNightCard(_ n: SleepNight) -> some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Last night")
                Spacer()
                Text(n.date)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextTertiary)
                    .padding(.trailing, .dsSpacing)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatHours(n.total))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.dsText)
                if let eff = n.efficiency {
                    // Format the percentage in code so each locale uses its
                    // own % conventions (placement, separator). Catalog key
                    // is "%@ efficiency" — the formatted percentage substitutes in.
                    let pct = (eff / 100).formatted(.percent.precision(.fractionLength(0)))
                    Text("\(pct) efficiency")
                        .font(.dsBodySm)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            .padding(.horizontal, .dsSpacing)

            HStack(spacing: 0) {
                stageCell(label: "Deep",  value: n.deep,  color: .dsSleep)
                Divider()
                stageCell(label: "REM",   value: n.rem,   color: .dsCardio)
                Divider()
                stageCell(label: "Core",  value: n.core,  color: .dsAccent)
                Divider()
                stageCell(label: "Awake", value: n.awake, color: .dsTextTertiary)
            }
            .padding(.horizontal, .dsSpacing)
            .padding(.bottom, .dsSpacing)
        }
        .dsCard()
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
                SectionHeader(title: "Trend")
                Spacer()
                Picker("", selection: $days) {
                    Text("7d").tag(7)
                    Text("30d").tag(30)
                    Text("90d").tag(90)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .padding(.trailing, .dsSpacing)
                .onChange(of: days) { _, _ in
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
                "Deep":  Color.dsSleep,
                "Core":  Color.dsAccent,
                "REM":   Color.dsCardio,
                "Awake": Color.dsTextTertiary,
            ])
            .chartLegend(.hidden)
            .frame(height: 220)
            .padding(.horizontal, .dsSpacing)

            HStack(spacing: 12) {
                legendDot("Deep",  color: .dsSleep)
                legendDot("Core",  color: .dsAccent)
                legendDot("REM",   color: .dsCardio)
                legendDot("Awake", color: .dsTextTertiary)
                Spacer()
            }
            .padding(.horizontal, .dsSpacing)
            .padding(.bottom, .dsSpacing)
        }
        .dsCard()
    }

    private func legendDot(_ label: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
        }
    }

    private var stagePoints: [SleepStagePoint] {
        var out: [SleepStagePoint] = []
        out.reserveCapacity(nights.count * 4)
        for n in nights {
            out.append(.init(date: n.date, stage: "Deep",  hours: n.deep))
            out.append(.init(date: n.date, stage: "Core",  hours: n.core))
            out.append(.init(date: n.date, stage: "REM",   hours: n.rem))
            out.append(.init(date: n.date, stage: "Awake", hours: n.awake))
        }
        return out
    }

    // MARK: - Empty / error

    /// Tiny "data from <device>" footer under the last-night card. Helpful
    /// when you wear both an Apple Watch and a smart ring — at a glance you
    /// see which one the server cross-validated to. Chosen as the source
    /// with the largest sleep_total contribution on the most recent night.
    private func sourceCard(_ source: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: sourceIcon(for: source))
                .foregroundStyle(Color.dsTextSecondary)
                .frame(width: 18)
            Text("Source")
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
            Text(source)
                .font(.dsCaption.weight(.medium))
                .foregroundStyle(Color.dsTextSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSurface2.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            async let totalT  = ServerClient.shared.metricData(name: "sleep_total", from: from, to: to, bucket: "day")
            async let deepT   = ServerClient.shared.metricData(name: "sleep_deep",  from: from, to: to, bucket: "day")
            async let remT    = ServerClient.shared.metricData(name: "sleep_rem",   from: from, to: to, bucket: "day")
            async let coreT   = ServerClient.shared.metricData(name: "sleep_core",  from: from, to: to, bucket: "day")
            async let awakeT  = ServerClient.shared.metricData(name: "sleep_awake", from: from, to: to, bucket: "day")
            // Last-night-only by-source query — covers two days to handle
            // sleep that crosses midnight. Pick the source with the largest
            // contribution; failure is non-fatal (source row hides itself).
            async let sourceT = ServerClient.shared.metricData(
                name: "sleep_total", from: lastFrom, to: to, bucket: "day", bySource: true
            )

            let (totalR, deepR, remR, coreR, awakeR) = try await (totalT, deepT, remT, coreT, awakeT)

            nights = mergeNights(total: totalR.points,
                                 deep: deepR.points,
                                 rem: remR.points,
                                 core: coreR.points,
                                 awake: awakeR.points)

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
        let aw = index(awake)
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

#Preview {
    SleepView()
}
