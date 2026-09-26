import SwiftUI
import Charts

@MainActor
@Observable
final class EnergyDataController {
    private(set) var briefing: BriefingResponse?
    private(set) var history: EnergyHistoryResponse?
    private(set) var historyFailed = false
    private(set) var briefingFailed = false
    private var generation = UUID()
    private var lastAttemptContext: String?
    private let sleep: @MainActor () async throws -> Void
    private let loadBriefing: @MainActor () async throws -> BriefingResponse
    private let loadHistory: @MainActor () async throws -> EnergyHistoryResponse
    private let context: @MainActor () throws -> String

    init(loadBriefing: @escaping @MainActor () async throws -> BriefingResponse = { try await ServerClient.shared.healthBriefing() },
         loadHistory: @escaping @MainActor () async throws -> EnergyHistoryResponse = { try await ServerClient.shared.energyHistory() },
         context: @escaping @MainActor () throws -> String = { try ServerClient.shared.dashboardContext() },
         sleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(60)) }) {
        self.loadBriefing = loadBriefing
        self.loadHistory = loadHistory
        self.context = context
        self.sleep = sleep
    }

    /// Observe day/account/language changes without coupling loads to AI arrival.
    func run() async {
        await refresh()
        while !Task.isCancelled {
            do { try await sleep() } catch { return }
            guard !Task.isCancelled else { return }
            if (try? context()) != lastAttemptContext { await refresh() }
        }
    }

    func refresh() async {
        let id = UUID()
        generation = id
        // Do not display a prior day's reserve as the current reserve.
        briefing = nil
        history = nil
        briefingFailed = false
        historyFailed = false
        let identity = try? context()
        lastAttemptContext = identity
        async let a: Void = refreshBriefing(id: id, identity: identity)
        async let b: Void = refreshHistory(id: id, identity: identity)
        _ = await (a, b)
    }

    private func isCurrent(_ id: UUID, _ identity: String?) -> Bool {
        !Task.isCancelled && id == generation && (try? context()) == identity
    }

    private func refreshBriefing(id: UUID, identity: String?) async {
        do {
            let value = try await loadBriefing()
            guard isCurrent(id, identity) else { return }
            briefing = value
        } catch {
            guard isCurrent(id, identity) else { return }
            briefingFailed = true
        }
    }

    private func refreshHistory(id: UUID, identity: String?) async {
        do {
            let value = try await loadHistory()
            guard isCurrent(id, identity) else { return }
            history = value
        } catch {
            guard isCurrent(id, identity) else { return }
            historyFailed = true
        }
    }
}

struct EnergyView: View {
    @State private var insights = TodayInsightsController()
    @State private var data = EnergyDataController()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let appearance = DomainAppearance.energy

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .dsSpacingLg) {
                VStack(spacing: 16) {
                    DomainPageHeader(title: String(localized: "Energy"), date: data.briefing?.date)
                    DomainGauge(value: data.briefing?.energyBank?.current.formatted() ?? "—", label: "Current energy",
                                fraction: data.briefing?.energyBank.flatMap { $0.capacity > 0 ? Double($0.current) / Double($0.capacity) : nil },
                                appearance: appearance)
                        .accessibilityIdentifier("energy-current")
                }.domainHero(appearance)
                if let bank = data.briefing?.energyBank {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0)),
                                             count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: .dsSpacingSm) {
                        DomainValueCard(title: "Capacity", value: bank.capacity.formatted(), icon: "battery.100percent", appearance: appearance)
                        DomainValueCard(title: "Drain so far", value: bank.drainSoFar.formatted(), icon: "arrow.down.right", appearance: appearance)
                    }
                    DomainInsightSection(controller: insights, slot: "energy", appearance: appearance)
                    if bank.verdictLabel != nil || !bank.verdictReason.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if let label = bank.verdictLabel { Text(label).font(.dsBody.weight(.semibold)) }
                            if !bank.verdictReason.isEmpty { Text(bank.verdictReason).font(.dsBodySm).foregroundStyle(Color.dsTextSecondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).domainSurface(appearance)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0)),
                                             count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 8) {
                        DomainValueCard(title: "Strain", value: bank.strain.formatted(), icon: "figure.run", appearance: appearance)
                        DomainValueCard(title: "Stress", value: bank.stress.formatted(), icon: "waveform.path.ecg", appearance: appearance)
                    }
                } else if data.briefingFailed || data.briefing != nil {
                    Text("Current energy is unavailable").foregroundStyle(Color.dsTextSecondary)
                } else {
                    ProgressView().tint(appearance.accent).frame(maxWidth: .infinity)
                }
                historySection
                if data.briefing?.energyBank == nil {
                    DomainInsightSection(controller: insights, slot: "energy", appearance: appearance)
                }
                if insights.unavailable, insights.response == nil {
                    Text("Insights are unavailable. Pull to refresh.").foregroundStyle(Color.dsTextSecondary)
                }
                if let flags = data.briefing?.energyBank?.flagDetails, !flags.isEmpty {
                    VStack(alignment: .leading, spacing: .dsSpacing) {
                        ForEach(flags) { flag in
                            VStack(alignment: .leading, spacing: .dsSpacingXs) {
                                Text(flag.label).font(.dsBodySm.weight(.semibold))
                                Text(flag.description).font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.dsSpacing).domainSurface(appearance)
                }
            }
            .foregroundStyle(Color.dsText)
            .padding(.dsSpacing)
            .padding(.bottom, .dsTabBarClearance)
        }
        .background { DomainBackdrop(appearance: appearance) }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .insightLifecycle(insights)
        .task(id: scenePhase) {
            if scenePhase == .active {
                await ServerClient.shared.refreshServerLang()
                guard !Task.isCancelled else { return }
                await data.run()
            }
        }
        .refreshable {
            async let values: Void = refreshData()
            async let opinions: Void = insights.refresh()
            _ = await (values, opinions)
        }
    }

    private func refreshData() async {
        await ServerClient.shared.refreshServerLang()
        guard !Task.isCancelled else { return }
        await data.refresh()
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            Text("Energy history · 14 days").font(.system(.title3, design: .rounded).weight(.semibold))
            if let history = data.history {
                let points = Array(history.points.sorted { $0.date < $1.date }.suffix(14))
                if points.isEmpty {
                    Text("Energy history is not available yet").font(.dsBodySm)
                } else {
                    Chart(points) { point in
                        BarMark(x: .value("Date", point.date), y: .value("Energy", point.currentEOD))
                            .foregroundStyle(appearance.accent)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(Color.dsBorder)
                            AxisValueLabel().foregroundStyle(Color.dsTextSecondary)
                        }
                    }
                    .frame(height: 180)
                    .accessibilityLabel("Daily energy snapshots")
                    DisclosureGroup {
                      ForEach(points.reversed()) { point in
                        HStack {
                            Text(displayDate(point.date))
                            Spacer()
                            Text(point.currentEOD.formatted()).monospacedDigit()
                        }
                        .font(.dsBodySm)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("energy-history-\(point.date)")
                      }
                    } label: {
                        Text("Daily energy snapshots")
                            .accessibilityIdentifier("energy-history-details")
                    }
                    .tint(Color.dsTextSecondary)
                }
            } else if data.historyFailed {
                Text("Energy history could not be loaded").font(.dsBodySm)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dsSpacing).domainSurface(appearance)
    }

    private func displayDate(_ raw: String) -> String {
        guard let date = try? Date(raw, strategy: .iso8601.year().month().day()) else { return raw }
        var style = Date.FormatStyle().day().month(.abbreviated)
        // The API returns calendar dates, not instants in the device zone.
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}
