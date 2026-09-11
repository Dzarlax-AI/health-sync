import SwiftUI

struct MetricsView: View {
    @State private var metrics: [MetricSummary] = []
    @State private var search: String = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var lastLoadedAt: Date?

    private var filtered: [MetricSummary] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return metrics }
        return metrics.filter {
            $0.name.lowercased().contains(q)
                || ($0.displayName?.lowercased().contains(q) ?? false)
        }
    }

    private var groupedMetrics: [DisplayMetricGroup] {
        let grouped = Dictionary(grouping: filtered) { MetricDomain.classify($0.name) }
        return MetricDomain.allCases.compactMap { domain in
            guard let items = grouped[domain], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                ($0.displayName ?? $0.name).localizedCaseInsensitiveCompare($1.displayName ?? $1.name) == .orderedAscending
            }
            return DisplayMetricGroup(domain: domain, metrics: sorted)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.dsReadiness.opacity(0.10), Color.dsBackground],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea()

                if isLoading && metrics.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = loadError, metrics.isEmpty {
                    ComingSoonView(icon: "exclamationmark.triangle",
                                   title: "Couldn't load metrics",
                                   message: LocalizedStringKey(err))
                } else if filtered.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: .dsSpacingLg) {
                            Text("Browse your health data by domain")
                                .font(.dsBodySm)
                                .foregroundStyle(Color.dsTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        if let loadError {
                            SyncRefreshBanner(message: loadError, lastLoadedAt: lastLoadedAt) {
                                Task { await load() }
                            }
                        }
                        ForEach(groupedMetrics) { group in
                            VStack(alignment: .leading, spacing: .dsSpacingSm) {
                                MetricGroupHeader(domain: group.domain, count: group.metrics.count)
                                VStack(spacing: 0) {
                                    ForEach(Array(group.metrics.enumerated()), id: \.element.id) { index, metric in
                                        if index > 0 { Divider().padding(.leading, 70) }
                                    metricRow(metric, domain: group.domain)
                                    }
                                }
                                .dsDetailCard()
                            }
                        }
                        }
                        .padding(.horizontal, .dsSpacing)
                        .padding(.top, .dsSpacingSm)
                        .padding(.bottom, .dsTabBarClearance)
                    }
                }
            }
            .navigationTitle("Metrics")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: .dsSpacingSm) {
            Image(systemName: search.isEmpty ? "waveform.path.ecg" : "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Color.dsTextTertiary)
            Text(search.isEmpty ? "No metrics yet." : "No matching metrics.")
                .font(.dsBodySm)
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metricRow(_ metric: MetricSummary, domain: MetricDomain) -> some View {
        NavigationLink(destination: MetricDetailView(
            metric: metric.name,
            displayName: metric.displayName,
            unit: metric.units
        )) {
            HStack(spacing: .dsSpacing) {
                Image(systemName: domain.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(domain.tint)
                    .frame(width: 38, height: 38)
                    .background(domain.tint.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.displayName ?? metric.name)
                        .font(.dsBody.weight(.semibold))
                        .foregroundStyle(Color.dsText)
                    HStack(spacing: 6) {
                        if !metric.units.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(metric.units)
                                .font(.dsCaption)
                                .foregroundStyle(Color.dsTextSecondary)
                        }
                        Text("\(metric.count.formatted()) samples")
                            .font(.dsCaption)
                            .foregroundStyle(Color.dsTextTertiary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsTextTertiary)
            }
            .padding(.horizontal, .dsSpacing)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dateRange(for metric: MetricSummary) -> String {
        if metric.min.isEmpty { return metric.max }
        if metric.max.isEmpty || metric.min == metric.max { return metric.min }
        return "\(metric.min) - \(metric.max)"
    }

    private func localizedDateRange(for metric: MetricSummary) -> String {
        guard let start = parseDate(metric.min), let end = parseDate(metric.max) else {
            return dateRange(for: metric)
        }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return start.formatted(.dateTime.day().month(.abbreviated).year())
        }
        if Calendar.current.component(.year, from: start) != Calendar.current.component(.year, from: end) {
            return "\(start.formatted(.dateTime.day().month(.abbreviated).year())) – \(end.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
        return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    private func parseDate(_ raw: String) -> Date? {
        try? Date(raw, strategy: .iso8601.year().month().day())
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            metrics = try await ServerClient.shared.listMetrics()
            lastLoadedAt = Date()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

private struct DisplayMetricGroup: Identifiable {
    var id: MetricDomain { domain }
    let domain: MetricDomain
    let metrics: [MetricSummary]
}

private enum MetricDomain: String, CaseIterable, Identifiable {
    case readiness
    case sleep
    case heart
    case activity
    case body
    case workouts
    case other

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .readiness: return "Readiness"
        case .sleep: return "Sleep"
        case .heart: return "Heart"
        case .activity: return "Activity"
        case .body: return "Body"
        case .workouts: return "Workouts"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .readiness: return "gauge.with.dots.needle.67percent"
        case .sleep: return "moon.zzz.fill"
        case .heart: return "heart.fill"
        case .activity: return "figure.run"
        case .body: return "person.fill"
        case .workouts: return "figure.strengthtraining.traditional"
        case .other: return "chart.bar.fill"
        }
    }

    var tint: Color {
        switch self {
        case .readiness: return .dsAccent
        case .sleep: return .dsSleep
        case .heart: return .dsHeart
        case .activity: return .dsActivity
        case .body: return .dsCardio
        case .workouts: return .dsWarn
        case .other: return .dsTextSecondary
        }
    }

    static func classify(_ metric: String) -> MetricDomain {
        let key = metric.lowercased()
        if key.contains("readiness") || key.contains("energy_bank") || key.contains("recovery") {
            return .readiness
        }
        if key.contains("sleep") || key.contains("awake") || key.contains("rem") {
            return .sleep
        }
        if key.contains("heart") || key.contains("hrv") || key.contains("spo2")
            || key.contains("oxygen") || key.contains("respiratory") || key.contains("vo2") {
            return .heart
        }
        if key.contains("step") || key.contains("distance") || key.contains("calorie")
            || key.contains("active_energy") || key.contains("exercise") || key.contains("stand")
            || key.contains("basal") {
            return .activity
        }
        if key.contains("workout") || key.contains("route") {
            return .workouts
        }
        if key.contains("weight") || key.contains("body") || key.contains("mass")
            || key.contains("temperature") || key.contains("glucose") {
            return .body
        }
        return .other
    }
}

private struct MetricGroupHeader: View {
    let domain: MetricDomain
    let count: Int

    var body: some View {
        HStack {
            Label {
                Text(domain.title)
                    .font(.dsBodySm.weight(.semibold))
            } icon: {
                Image(systemName: domain.symbol)
            }
            .foregroundStyle(domain.tint)
            Spacer()
            Text("\(count)")
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
        }
        .textCase(nil)
    }
}

#Preview {
    MetricsView()
}
