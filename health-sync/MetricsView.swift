import SwiftUI

struct MetricsView: View {
    var openConnection: () -> Void = {}
    @State private var metrics: [MetricSummary] = []
    @State private var search: String = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var lastLoadedAt: Date?
    @State private var missingConfiguration = false

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
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }

    private var collidingNames: Set<String> {
        let groups = Dictionary(grouping: metrics) { $0.title.folding(options: .caseInsensitive, locale: .current) }
        return Set(groups.filter { $0.value.count > 1 }.keys)
    }

    var body: some View {
        let collisions = collidingNames
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
                    VStack(spacing: .dsSpacing) {
                        Image(systemName: missingConfiguration ? "server.rack" : "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(Color.dsTextSecondary)
                        Text(missingConfiguration ? "Connect your server to browse metrics." : "Couldn't load metrics")
                            .font(.dsBody).multilineTextAlignment(.center)
                        if !missingConfiguration { Text(verbatim: err).font(.dsCaption).foregroundStyle(Color.dsTextSecondary) }
                        if missingConfiguration {
                            Button("Connect server", action: openConnection)
                                .buttonStyle(DSSecondaryButtonStyle())
                                .accessibilityIdentifier("metrics-connect-server")
                        } else {
                            Button("Retry") { Task { await load() } }
                                .buttonStyle(DSSecondaryButtonStyle())
                                .accessibilityIdentifier("metrics-retry")
                        }
                    }.padding(.dsSpacing)
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
                                    metricRow(metric, hasNameCollision: collisions.contains(metric.title.folding(options: .caseInsensitive, locale: .current)))
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
            Image(systemName: metrics.isEmpty ? "waveform.path.ecg" : "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Color.dsTextTertiary)
            Text(metrics.isEmpty ? "No metrics yet." : "No matching metrics.")
                .font(.dsBodySm)
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metricRow(_ metric: MetricSummary, hasNameCollision: Bool) -> some View {
        NavigationLink(destination: MetricDetailView(
            metric: metric.name,
            displayName: metric.displayName,
            unit: metric.units,
            unitStatus: metric.unitStatus,
            variantLabel: metric.variantDescription(hasNameCollision: hasNameCollision)
        )) {
            HStack(spacing: .dsSpacing) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dsAccent)
                    .frame(width: 38, height: 38)
                    .background(Color.dsAccent.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.title)
                        .font(.dsBody.weight(.semibold))
                        .foregroundStyle(Color.dsText)
                    if let variant = metric.variantDescription(hasNameCollision: hasNameCollision) {
                        Text(verbatim: variant)
                            .font(.dsCaption)
                            .foregroundStyle(Color.dsTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let date = MetricDateWindow.date(metric.max) {
                        Text("Last record: \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))")
                            .font(.dsCaption)
                            .foregroundStyle(Color.dsTextTertiary)
                    }
                    HStack(spacing: 6) {
                        Text(verbatim: metric.unitMetadata.displayUnit ?? metric.unitMetadata.notice ?? "")
                            .font(.dsCaption)
                            .foregroundStyle(Color.dsTextSecondary)
                        Text("\(metric.count) records")
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
        .accessibilityIdentifier("metric-row-\(metric.name)")
    }

    private func load() async {
        isLoading = true
        loadError = nil
        missingConfiguration = false
        do {
            metrics = try await ServerClient.shared.listMetrics()
            lastLoadedAt = Date()
        } catch {
            if case .missingConfig = error as? ServerError { missingConfiguration = true }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    MetricsView()
}
