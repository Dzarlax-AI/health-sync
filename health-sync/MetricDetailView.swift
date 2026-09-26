import SwiftUI
import Charts

/// Metrics for which the server uses SUM aggregation (totals per bucket).
/// Mirrored from `internal/storage/aggregates.go::SumMetrics`. Used here to
/// pick bar vs line chart and pick a sensible default `agg` query.
private let sumMetrics: Set<String> = [
    "step_count", "active_energy", "basal_energy_burned",
    "apple_exercise_time", "apple_stand_time", "flights_climbed",
    "walking_running_distance", "time_in_daylight", "apple_stand_hour",
    "sleep_total", "sleep_deep", "sleep_rem", "sleep_core", "sleep_unspecified", "sleep_awake",
]

struct MetricDetailView: View {
    let metric: String
    let displayName: String?
    let unit: String

    init(metric: String, displayName: String?, unit: String = "") {
        self.metric = metric
        self.displayName = displayName
        self.unit = unit
    }

    @State private var points: [DataPoint] = []
    @State private var dateRange: MetricDateRange?
    @State private var days: Int = 30
    @State private var isLoading = false
    @State private var loadError: String?

    private var isSum: Bool { sumMetrics.contains(metric) }

    var body: some View {
        ScrollView {
            VStack(spacing: .dsSpacingLg) {
                rangePicker
                if isLoading && points.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 220)
                } else if let err = loadError, points.isEmpty {
                    emptyState(LocalizedStringKey(err), isError: true)
                } else if points.isEmpty {
                    emptyState("No data in this range.", isError: false)
                } else {
                    chartCard
                    statsCard
                }
            }
            .padding(.dsSpacing)
            .padding(.bottom, .dsTabBarClearance)
        }
        .background(Color.dsBackground)
        .navigationTitle(LocalizedStringKey(displayName ?? metric))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        Picker("", selection: $days) {
            Text("7d").tag(7)
            Text("30d").tag(30)
            Text("90d").tag(90)
        }
        .pickerStyle(.segmented)
        .onChange(of: days) { _, _ in
            Task { await load() }
        }
    }

    // MARK: - Chart

    private var chartCard: some View {
        let chartPoints = points.compactMap { point -> (id: String, date: Date, qty: Double)? in
            guard let date = chartDate(point.date) else { return nil }
            return (point.date, date, point.qty)
        }
        return VStack(alignment: .leading, spacing: .dsSpacingSm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily values")
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(Color.dsText)
                Spacer()
                if !displayUnit.isEmpty {
                    Text(displayUnit)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            Text(selectedRangeCaption)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)

            Chart(chartPoints, id: \.id) { p in
            if isSum {
                BarMark(
                    x: .value("Date", p.date, unit: .day),
                    y: .value("Value", p.qty),
                    width: .ratio(0.8)
                )
                .foregroundStyle(Color.dsAccent)
            } else {
                LineMark(
                    x: .value("Date", p.date),
                    y: .value("Value", p.qty)
                )
                .foregroundStyle(Color.dsAccent)
                .interpolationMethod(.catmullRom)
                AreaMark(
                    x: .value("Date", p.date),
                    y: .value("Value", p.qty)
                )
                .foregroundStyle(Color.dsAccent.opacity(0.10))
                .interpolationMethod(.catmullRom)
            }
            }
            .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.dsBorderHover)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(Color.dsTextTertiary)
            }
            }
            .chartPlotStyle { plot in plot.clipped() }
            .dsChartYScale(domain: DashboardChartScale.domain(
            for: metric,
            values: chartPoints.map(\.qty),
            isBar: isSum
            ))
            .frame(height: 220)
        }
        .padding(.dsSpacing)
        .dsDetailCard()
    }

    // MARK: - Stats card

    private var statsCard: some View {
        let stats = computeStats()
        return VStack(alignment: .leading, spacing: 0) {
            statsRow(label: "Latest",  value: stats.last)
            Divider().padding(.leading, .dsSpacing)
            statsRow(label: "Average", value: stats.avg)
            Divider().padding(.leading, .dsSpacing)
            statsRow(label: "Min",     value: stats.min)
            Divider().padding(.leading, .dsSpacing)
            statsRow(label: "Max",     value: stats.max)
            if let range = dateRange {
                Divider().padding(.leading, .dsSpacing)
                statsRow(label: "Recorded since", value: shortDate(range.min))
            }
        }
        .dsDetailCard()
    }

    private func statsRow(label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .font(.dsBody)
                .foregroundStyle(Color.dsText)
            Spacer()
            Text(value)
                .font(.dsMono)
                .foregroundStyle(Color.dsTextSecondary)
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, 12)
    }

    // MARK: - Empty / error

    private func emptyState(_ message: LocalizedStringKey, isError: Bool) -> some View {
        VStack(spacing: .dsSpacingSm) {
            Image(systemName: isError ? "exclamationmark.triangle" : "chart.xyaxis.line")
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

        do {
            async let dataT = ServerClient.shared.metricData(
                name: metric, from: from, to: to, bucket: "day"
            )
            async let rangeT = ServerClient.shared.metricRange(name: metric)
            let (resp, range) = try await (dataT, rangeT)
            points = resp.points ?? []
            dateRange = range
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Stats

    private struct Stats {
        let last: String
        let avg: String
        let min: String
        let max: String
    }

    private func computeStats() -> Stats {
        guard !points.isEmpty else {
            return Stats(last: "—", avg: "—", min: "—", max: "—")
        }
        let values = points.map(\.qty)
        let sum = values.reduce(0, +)
        let avg = sum / Double(values.count)
        let mn = values.min() ?? 0
        let mx = values.max() ?? 0
        let last = points.last?.qty ?? 0
        return Stats(
            last: formatWithUnit(last),
            avg:  formatWithUnit(avg),
            min:  formatWithUnit(mn),
            max:  formatWithUnit(mx)
        )
    }

    /// Compact value formatter:
    /// - Integers (e.g. step counts) → no decimals.
    /// - Sub-100 floats → 1 decimal place.
    /// - Larger floats → 0 decimals.
    private func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1_000_000 {
            return String(format: "%.0f", v)
        }
        if abs(v) < 100 {
            return String(format: "%.1f", v)
        }
        return String(format: "%.0f", v)
    }

    private func formatWithUnit(_ value: Double) -> String {
        let number = format(value)
        return displayUnit.isEmpty ? number : "\(number) \(displayUnit)"
    }

    /// The metric catalogue normally supplies a unit. Sleep durations are an
    /// established API contract in hours, including on older catalogue
    /// responses which omit it, so never leave this chart's scale ambiguous.
    private var displayUnit: String {
        if !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return unit }
        return metric.hasPrefix("sleep_") ? String(localized: "hrs") : ""
    }

    private var selectedRangeCaption: String {
        let dates = points.compactMap { chartDate($0.date) }.sorted()
        guard let first = dates.first, let last = dates.last else { return "Last \(days) days" }
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return "\(first.formatted(format)) – \(last.formatted(format))"
    }

    private func isoDate(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func chartDate(_ raw: String) -> Date? {
        try? Date(raw, strategy: .iso8601.year().month().day())
    }

    /// Take the first 10 chars (`YYYY-MM-DD`) of a server timestamp.
    private func shortDate(_ s: String) -> String {
        guard s.count >= 10 else { return s }
        return String(s.prefix(10))
    }
}
