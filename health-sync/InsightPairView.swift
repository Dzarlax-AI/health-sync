import SwiftUI

struct InsightDisclosureState {
    private var serverOverride: Bool?
    private(set) var aiExpanded = true

    func serverExpanded(hasVisibleAI: Bool) -> Bool { serverOverride ?? !hasVisibleAI }
    mutating func toggleServer(hasVisibleAI: Bool) { serverOverride = !serverExpanded(hasVisibleAI: hasVisibleAI) }
    mutating func toggleAI() { aiExpanded.toggle() }
}

struct InsightPairView: View {
    let snapshot: TodayInsightsResponse
    var slot = "overall"
    var stale = false
    var appearance: DomainAppearance?
    @State private var disclosure = InsightDisclosureState()

    private var hasVisibleAI: Bool { snapshot.visibleAI(for: slot).map { !$0.text.isEmpty } ?? false }
    private var serverExpanded: Bool { disclosure.serverExpanded(hasVisibleAI: hasVisibleAI) }
    private var aiExpanded: Bool { disclosure.aiExpanded }

    private var insight: TodayInsight? { slot == "overall" ? snapshot.primary : snapshot.domain(slot)?.insight }

    private func generationDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    var body: some View {
        if let insight {
            VStack(alignment: .leading, spacing: 12) {
                if let ai = snapshot.visibleAI(for: slot), !ai.text.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Button { disclosure.toggleAI() } label: {
                            HStack(spacing: 8) {
                                Label("AI Insight", systemImage: "sparkles").font(.dsBodySm.weight(.semibold))
                                Spacer(minLength: 0)
                                Image(systemName: aiExpanded ? "chevron.up" : "chevron.down")
                                    .font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ai-insight-\(slot)")
                        .accessibilityValue(aiExpanded ? Text("Expanded") : Text("Collapsed"))
                        if ai.stale == true || stale {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Previous AI insight")
                                if let date = ai.sourceDate { Text(date).font(.dsCaption) }
                                if let generatedAt = ai.generatedAt,
                                   let date = generationDate(generatedAt) {
                                    Text(date, style: .time).font(.dsCaption)
                                }
                                Text(snapshot.state(for: slot) == "failed" ? "AI refresh failed" :
                                     ["cold", "generating"].contains(snapshot.state(for: slot)) ? "AI insight is updating" : "Previous context")
                            }.font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                        }
                        if aiExpanded {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(ai.text)
                                if let action = ai.alternativeAction, !action.isEmpty {
                                    Text("Alternative action").font(.dsCaption.weight(.semibold))
                                    Text(action)
                                }
                            }
                            .font(.dsBodySm)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("ai-insight-details-\(slot)")
                        }
                    }
                    .padding(16).domainSurface(appearance ?? .recovery)
                } else if !stale {
                    switch snapshot.state(for: slot) {
                    case "cold", "generating":
                        Label("AI insight is updating", systemImage: "sparkles")
                            .font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                            .padding(16).domainSurface(appearance ?? .recovery)
                    case "failed":
                        Text("AI insight is unavailable.")
                            .font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                            .padding(16).domainSurface(appearance ?? .recovery)
                    default: EmptyView()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if stale {
                        Label("Showing previous data. Pull to refresh.", systemImage: "clock.arrow.circlepath")
                            .font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                    }
                    Button { disclosure.toggleServer(hasVisibleAI: hasVisibleAI) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Server Insight").font(.dsCaption.weight(.semibold))
                                Spacer()
                                Image(systemName: serverExpanded ? "chevron.up" : "arrow.up.left.and.arrow.down.right")
                            }.foregroundStyle(Color.dsTextSecondary)
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("server-insight-\(slot)")
                    .accessibilityValue(serverExpanded ? Text("Expanded") : Text("Collapsed"))
                    if serverExpanded {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(insight.title).font(.system(.headline, design: .rounded))
                            if !insight.observation.isEmpty {
                                Text(insight.observation).fixedSize(horizontal: false, vertical: true)
                            }
                            if !insight.meaning.isEmpty, insight.meaning != insight.observation { Text(insight.meaning) }
                            if let action = insight.nextStep, !action.text.isEmpty {
                                Text(action.text).font(.dsBodySm.weight(.semibold))
                            }
                        }
                        .font(.dsBodySm)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("server-insight-details-\(slot)")
                    }
                }
                .padding(16).domainSurface(appearance ?? .recovery)
            }
            .foregroundStyle(Color.dsText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Mount independently of charts so optional insight requests never hold up
/// the rest of the page, and stop all polling when the screen is hidden.
private struct InsightLifecycle: ViewModifier {
    let controller: TodayInsightsController
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false; controller.invalidateRequest() }
            .task(id: visible && phase == .active) {
                guard visible && phase == .active else { return }
                await controller.run()
            }
    }
}
extension View {
    func insightLifecycle(_ controller: TodayInsightsController) -> some View {
        modifier(InsightLifecycle(controller: controller))
    }
}

struct DomainInsightSection: View {
    let controller: TodayInsightsController
    let slot: String
    var appearance: DomainAppearance?
    private var headerColor: Color { .dsTextSecondary }
    var body: some View {
        if let snapshot = controller.response, snapshot.domain(slot) != nil {
            VStack(alignment: .leading, spacing: .dsSpacingSm) {
                // This date is explicit: a current-day opinion never describes
                // the independently selected historical chart range.
                HStack {
                    Text("Today's insight").font(.dsCaption.weight(.semibold))
                    Spacer()
                    Text(snapshot.date).font(.dsCaption)
                }.foregroundStyle(headerColor)
                InsightPairView(snapshot: snapshot, slot: slot, stale: controller.isStale, appearance: appearance)
                    .id("\(controller.contentIdentity)-\(snapshot.date)-\(slot)")
            }
        }
    }
}
