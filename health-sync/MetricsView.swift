import SwiftUI

struct MetricsView: View {
    @State private var metrics: [MetricSummary] = []
    @State private var search: String = ""
    @State private var isLoading = false
    @State private var loadError: String?

    var filtered: [MetricSummary] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return metrics }
        return metrics.filter {
            $0.name.lowercased().contains(q)
                || ($0.displayName?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && metrics.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = loadError, metrics.isEmpty {
                    ComingSoonView(icon: "exclamationmark.triangle",
                                   title: "Couldn't load metrics",
                                   message: LocalizedStringKey(err))
                } else {
                    List(filtered) { m in
                        let label = m.displayName ?? m.name
                        NavigationLink(destination: MetricDetailView(
                            metric: m.name,
                            displayName: m.displayName
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label).font(.dsSubhead).foregroundStyle(Color.dsText)
                                HStack(spacing: 8) {
                                    Text(m.units).font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                                    Text("·").font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                                    Text("\(m.count) pts").font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
                }
            }
            .background(Color.dsBackground)
            .navigationTitle("Metrics")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            metrics = try await ServerClient.shared.listMetrics()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    MetricsView()
}
