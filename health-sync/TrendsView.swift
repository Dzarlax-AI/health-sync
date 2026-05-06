import SwiftUI
import Charts

struct TrendsView: View {
    @State private var history: [ReadinessPoint] = []
    @State private var days: Int = 30
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: .dsSpacingLg) {
                    readinessCard
                    sectionList
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

    private var sectionList: some View {
        VStack(spacing: 0) {
            navigationRow(title: "Cardio",
                          systemImage: "heart.fill",
                          tint: .dsHeart,
                          subtitle: "RHR · HRV · VO2 · respiratory",
                          sectionKey: "cardio")
            Divider().padding(.leading, 56)
            navigationRow(title: "Activity",
                          systemImage: "figure.run",
                          tint: .dsActivity,
                          subtitle: "Steps · energy · exercise · distance",
                          sectionKey: "activity")
            Divider().padding(.leading, 56)
            navigationRow(title: "Recovery",
                          systemImage: "leaf.fill",
                          tint: .dsSleep,
                          subtitle: "Sleep summary · HRV CV · wrist temp",
                          sectionKey: "recovery")
        }
        .dsCard()
    }

    /// Push to SectionDetailView — same view used from Today's Health
    /// overview, so both entry points show the rich (summary + KPIs +
    /// charts + "How it works") page.
    private func navigationRow(title: String,
                               systemImage: String,
                               tint: Color,
                               subtitle: String,
                               sectionKey: String) -> some View {
        NavigationLink(destination: SectionDetailView(sectionKey: sectionKey)) {
            HStack(spacing: .dsSpacing) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title)).font(.dsSubhead).foregroundStyle(Color.dsText)
                    Text(LocalizedStringKey(subtitle)).font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
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

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            history = try await ServerClient.shared.readinessHistory(days: days)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    TrendsView()
}
