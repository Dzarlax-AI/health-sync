import SwiftUI
import Charts

struct TrendsView: View {
    @State private var history: [ReadinessPoint] = []
    @State private var days: Int = 30
    @State private var loadError: String?
    @State private var isLoading = false
    /// Section catalogue from `/api/sections` (health_dashboard PR #90).
    /// nil = not loaded yet; empty = server returned no sections (treat
    /// like a transient failure and hide the list rather than rendering
    /// an empty card).
    @State private var sections: [SectionCatalogueEntry]?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: .dsSpacingLg) {
                    readinessCard
                    if let s = sections, !s.isEmpty {
                        sectionList(s)
                    }
                }
                .padding(.dsSpacing)
            }
            .background(Color.dsBackground)
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            HStack {
                SectionHeader(title: "Readiness")
                Spacer()
                Picker("", selection: $days) {
                    Text("7d").tag(7)
                    Text("30d").tag(30)
                    Text("90d").tag(90)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: days) { _, _ in
                    Task { await load() }
                }
            }

            if isLoading && history.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if let err = loadError {
                Text(LocalizedStringKey(err))
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsDanger)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if history.isEmpty {
                Text("No readiness data yet.")
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextTertiary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(history) { p in
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Score", p.score)
                    )
                    .foregroundStyle(Color.dsAccent)
                    .interpolationMethod(.catmullRom)
                    AreaMark(
                        x: .value("Date", p.date),
                        y: .value("Score", p.score)
                    )
                    .foregroundStyle(Color.dsAccent.opacity(0.10))
                }
                .chartYScale(domain: 0...100)
                .frame(height: 200)
            }
        }
        .padding(.dsSpacing)
        .dsCard()
    }

    private func sectionList(_ entries: [SectionCatalogueEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                if idx > 0 {
                    Divider().padding(.leading, 56)
                }
                navigationRow(entry)
            }
        }
        .dsCard()
    }

    /// Push to SectionDetailView — same view used from Today's Health
    /// overview, so both entry points show the rich (summary + KPIs +
    /// charts + "How it works") page.
    private func navigationRow(_ entry: SectionCatalogueEntry) -> some View {
        NavigationLink(destination: SectionDetailView(sectionKey: entry.key)) {
            HStack(spacing: .dsSpacing) {
                Image(systemName: sfSymbol(for: entry.icon))
                    .frame(width: 24)
                    .foregroundStyle(tint(for: entry.key))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.dsSubhead).foregroundStyle(Color.dsText)
                    Text(entry.subtitle).font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.dsTextTertiary)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.dsSpacing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Maps the server's abstract icon token (`heart` / `activity` /
    /// `leaf` / future values) to an SF Symbol. Stays iOS-side because
    /// the choice of glyph is design, not translation — server should
    /// not need to know iOS' icon vocabulary. Unknown tokens fall back
    /// to a generic chart glyph so a server-added section still
    /// renders something recognisable in the row.
    private func sfSymbol(for icon: String) -> String {
        switch icon {
        case "heart":    return "heart.fill"
        case "activity": return "figure.run"
        case "leaf":     return "leaf.fill"
        case "moon":     return "moon.zzz"
        default:         return "chart.bar.fill"
        }
    }

    /// Tint colour per section key. Same iOS-side rationale as
    /// `sfSymbol(for:)` — design semantics rather than translation.
    /// The web dashboard maintains its own colour palette; iOS aligns
    /// where the DS tokens map naturally. Unknown keys → neutral accent.
    private func tint(for key: String) -> Color {
        switch key {
        case "cardio":   return .dsHeart
        case "activity": return .dsActivity
        case "recovery": return .dsSleep
        default:         return .dsAccent
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        // Readiness history is the primary data — its failure shows
        // the empty-state in the readiness card. The sections catalogue
        // is best-effort: a server too old to know `/api/sections`
        // 404s, and we just hide the list rather than blocking the
        // whole tab.
        do {
            history = try await ServerClient.shared.readinessHistory(days: days)
        } catch {
            loadError = error.localizedDescription
        }
        if let s = try? await ServerClient.shared.sections() {
            sections = s.sections
        }
        isLoading = false
    }
}

#Preview {
    TrendsView()
}
