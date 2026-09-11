import SwiftUI

struct MetricsView: View {
    @State private var metrics: [MetricSummary] = []
    @State private var search: String = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var lastLoadedAt: Date?

    private var filtered: [MetricSummary] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return metrics }
        return metrics.filter {
            $0.name.localizedStandardContains(q)
                || ($0.displayName?.localizedStandardContains(q) ?? false)
        }
    }

    private var orderedMetrics: [MetricSummary] {
        filtered.sorted {
            ($0.displayName ?? $0.name).localizedCaseInsensitiveCompare($1.displayName ?? $1.name) == .orderedAscending
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
                            Text("Browse all available health data")
                                .font(.dsBodySm)
                                .foregroundStyle(Color.dsTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let loadError {
                                SyncRefreshBanner(message: loadError, lastLoadedAt: lastLoadedAt) {
                                    Task { await load() }
                                }
                            }
                            VStack(spacing: 0) {
                                ForEach(Array(orderedMetrics.enumerated()), id: \.element.id) { index, metric in
                                    if index > 0 { Divider().padding(.leading, 70) }
                                    metricRow(metric)
                                }
                            }
                            .dsDetailCard()
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

    private func metricRow(_ metric: MetricSummary) -> some View {
        NavigationLink(destination: MetricDetailView(
            metric: metric.name,
            displayName: metric.displayName,
            unit: metric.units
        )) {
            HStack(spacing: .dsSpacing) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dsAccent)
                    .frame(width: 38, height: 38)
                    .background(Color.dsAccent.opacity(0.10), in: Circle())

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

#Preview {
    MetricsView()
}
