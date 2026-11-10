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
    let unitStatus: String?
    let variantLabel: String?

    init(metric: String, displayName: String?, unit: String = "", unitStatus: String? = nil, variantLabel: String? = nil) {
        self.metric = metric
        self.displayName = displayName
        self.unit = unit
        self.unitStatus = unitStatus
        self.variantLabel = variantLabel
    }

    @State private var controller = MetricDetailController()
    @State private var historicalRange: MetricDateWindow?
    @State private var days: Int = 30
    private var points: [DataPoint] { controller.points }
    private var isLoading: Bool { controller.isLoading }
    private var loadError: String? { controller.loadError }
    private var selectedWindow: MetricDateWindow {
        MetricDateWindow.ending(at: historicalRange?.to ?? MetricDateWindow.iso(Date(), timeZone: .current),
                                days: days, minimum: historicalRange?.from)!
    }

    private var isSum: Bool { sumMetrics.contains(metric) }

    var body: some View {
        let window = selectedWindow
        ScrollView {
            VStack(spacing: .dsSpacingLg) {
                rangePicker
                if let variantLabel, !variantLabel.isEmpty {
                    Text(verbatim: variantLabel)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsHorizonTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("metric-detail-variant")
                }
                if let notice = unitMetadata.notice {
                    Text(verbatim: notice)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsHorizonTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("metric-unit-notice")
                }
                if historicalRange != nil {
                    Button("Current period") { self.historicalRange = nil }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .accessibilityIdentifier("metric-current-period")
                }
                if let loadError, !points.isEmpty {
                    VStack(alignment: .leading, spacing: .dsSpacingSm) {
                        Text("Couldn’t update this period. The chart still shows the previous dates.")
                        Text(verbatim: loadError)
                        Button("Retry") { Task { await load() } }
                    }
                    .font(.dsCaption).foregroundStyle(Color.dsHorizonTextSecondary)
                    .accessibilityIdentifier("metric-refresh-error")
                }
                if isLoading && points.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 220)
                } else if let err = loadError, points.isEmpty {
                    emptyState(LocalizedStringKey(err), isError: true)
                } else if points.isEmpty {
                    VStack(spacing: .dsSpacingSm) {
                        emptyState(historicalRange == nil ? "No data in this range." : "No records are available for these dates.", isError: false)
                        if let window = controller.displayedWindow {
                            Text(window.caption).font(.dsCaption).foregroundStyle(Color.dsHorizonTextSecondary)
                        }
                        if historicalRange == nil, let range = controller.availableRange {
                            Text("Available records: \(range.caption)")
                                .font(.dsCaption).foregroundStyle(Color.dsHorizonTextSecondary)
                            Button("Show latest records") { historicalRange = range }
                                .buttonStyle(DSSecondaryButtonStyle())
                                .accessibilityIdentifier("metric-latest-records")
                        }
                    }
                } else {
                    chartCard
                    statsCard
                }
            }
            .padding(.dsSpacing)
            .padding(.bottom, .dsTabBarClearance)
        }
        .background(Color.dsHorizonBackground)
        .navigationTitle(LocalizedStringKey(displayName ?? metric))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("metric-detail-\(metric)")
        .refreshable { await load() }
        .task(id: "\(metric)|\(window.from)|\(window.to)|\(historicalRange != nil)") {
            await controller.load(metric: metric, window: window)
        }
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        Picker("", selection: $days) {
            Text("7d").tag(7)
            Text("30d").tag(30)
            Text("90d").tag(90)
        }
        .pickerStyle(.segmented)
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
                    .foregroundStyle(Color.dsHorizonText)
                Spacer()
                if !displayUnit.isEmpty {
                    Text(displayUnit)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsHorizonTextSecondary)
                        .accessibilityIdentifier("metric-chart-unit")
                }
            }
            Text(selectedRangeCaption)
                .font(.dsCaption)
                .foregroundStyle(Color.dsHorizonTextSecondary)
                .accessibilityIdentifier("metric-chart-dates")

            Chart(chartPoints, id: \.id) { p in
            if isSum {
                BarMark(
                    x: .value("Date", p.date, unit: .day, calendar: MetricDateWindow.calendar),
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
                    .foregroundStyle(Color.dsHorizonBorder)
                AxisValueLabel(format: Date.FormatStyle(date: .omitted, time: .omitted, timeZone: .gmt).day().month(.abbreviated))
                    .foregroundStyle(Color.dsHorizonTextSecondary)
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
            if let notice = unitMetadata.notice {
                Text(verbatim: notice)
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsHorizonTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.dsSpacing)
            }
            statsRow(label: "Latest",  value: stats.last)
            Divider().padding(.leading, .dsSpacing)
            statsRow(label: "Average", value: stats.avg)
            Divider().padding(.leading, .dsSpacing)
            statsRow(label: "Min",     value: stats.min)
            Divider().padding(.leading, .dsSpacing)
            statsRow(label: "Max",     value: stats.max)
            if let range = controller.availableRange {
                Divider().padding(.leading, .dsSpacing)
                statsRow(label: "Recorded since", value: range.from)
            }
        }
        .dsDetailCard()
    }

    private func statsRow(label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .font(.dsBody)
                .foregroundStyle(Color.dsHorizonText)
            Spacer()
            Text(value)
                .font(.dsMono)
                .foregroundStyle(Color.dsHorizonTextSecondary)
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, 12)
    }

    // MARK: - Empty / error

    private func emptyState(_ message: LocalizedStringKey, isError: Bool) -> some View {
        VStack(spacing: .dsSpacingSm) {
            Image(systemName: isError ? "exclamationmark.triangle" : "chart.xyaxis.line")
                .font(.system(size: 40))
                .foregroundStyle(isError ? Color.dsDanger : Color.dsHorizonTextSecondary)
            Text(message)
                .font(.dsBodySm)
                .foregroundStyle(Color.dsHorizonTextSecondary)
                .multilineTextAlignment(.center)
            if isError {
                Button("Retry") { Task { await load() } }
                    .buttonStyle(DSSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Load

    private func load() async {
        let window = selectedWindow
        await controller.load(metric: metric, window: window)
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

    private var unitMetadata: MetricUnitMetadata {
        MetricUnitMetadata(metric: metric, units: unit, status: unitStatus)
    }

    private var displayUnit: String {
        unitMetadata.displayUnit ?? ""
    }

    private var selectedRangeCaption: String {
        controller.displayedWindow?.caption ?? ""
    }

    private func chartDate(_ raw: String) -> Date? {
        MetricDateWindow.date(raw)
    }

    /// Take the first 10 chars (`YYYY-MM-DD`) of a server timestamp.
    private func shortDate(_ s: String) -> String {
        guard s.count >= 10 else { return s }
        return String(s.prefix(10))
    }
}
