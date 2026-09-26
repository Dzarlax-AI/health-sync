import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class BackgroundSyncDiagnostics {
    static let shared = BackgroundSyncDiagnostics()

    enum Kind: String, Codable {
        case observer, backgroundTask, dailyResync, unlock
        case accepted, noData, partial, deferred, locked, credentialsUnavailable
        case cancelled, expired, disabled, scheduled, schedulerFailed
        case deliveryEnabled, deliveryFailed, observerFailed, registrationFailed, keyMigrationFailed

        var label: String {
            switch self {
            case .observer: return String(localized: "HealthKit background update")
            case .backgroundTask: return String(localized: "Background sync started")
            case .dailyResync: return String(localized: "Daily resync started")
            case .unlock: return String(localized: "Protected data became available")
            case .accepted: return String(localized: "Background upload accepted")
            case .noData: return String(localized: "No new background data")
            case .partial: return String(localized: "Background upload partially accepted")
            case .deferred: return String(localized: "Background sync deferred")
            case .locked: return String(localized: "Waiting for device unlock")
            case .credentialsUnavailable: return String(localized: "API key temporarily unavailable")
            case .cancelled: return String(localized: "Background sync cancelled")
            case .expired: return String(localized: "Background execution time expired")
            case .disabled: return String(localized: "Background delivery disabled")
            case .scheduled: return String(localized: "Background task scheduled")
            case .schedulerFailed: return String(localized: "Background scheduling failed")
            case .deliveryEnabled: return String(localized: "HealthKit delivery enabled")
            case .deliveryFailed: return String(localized: "HealthKit delivery setup failed")
            case .observerFailed: return String(localized: "HealthKit observer failed")
            case .registrationFailed: return String(localized: "Background task registration failed")
            case .keyMigrationFailed: return String(localized: "API key access update deferred")
            }
        }
    }

    struct Event: Codable, Identifiable {
        let id: UUID
        let date: Date
        let kind: Kind
    }

    private(set) var events: [Event]
    private(set) var lastAccepted: Date?
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let eventsKey = "health-sync.background-events.v1"
    private let receiptKey = "health-sync.background-receipt.v1"

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.clock = clock
        events = (defaults.data(forKey: eventsKey).flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []).suffix(40).map { $0 }
        lastAccepted = defaults.object(forKey: receiptKey) as? Date
        if SyncRuntime.isTestMode && ProcessInfo.processInfo.arguments.contains("--background-diagnostics-fixture") {
            let date = Date(timeIntervalSince1970: 1_790_000_000)
            lastAccepted = date
            events = [Event(id: UUID(), date: date, kind: .accepted),
                      Event(id: UUID(), date: date.addingTimeInterval(60), kind: .locked)]
        }
    }

    // Closed event vocabulary: no credentials, URLs, payloads, or error text.
    func record(_ kind: Kind) {
        let date = clock()
        events.append(Event(id: UUID(), date: date, kind: kind))
        events = Array(events.suffix(40))
        if kind == .accepted || kind == .partial {
            lastAccepted = date
            defaults.set(date, forKey: receiptKey)
        }
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: eventsKey) }
    }

    func recordOutcome(_ outcome: SyncOutcome) {
        switch outcome {
        case .accepted: record(.accepted)
        case .acceptedNoData: record(.noData)
        case .partial: record(.partial)
        case .locked: record(.locked)
        case .deferred(let failure): record(failure.code == .locked ? .locked : .deferred)
        case .cancelled: record(.cancelled)
        case .disabled: record(.disabled)
        case .alreadyRunning: record(.deferred)
        }
    }
}

struct BackgroundDiagnosticsView: View {
    private let diagnostics = BackgroundSyncDiagnostics.shared
    @State private var refreshStatus = UIApplication.shared.backgroundRefreshStatus
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: .dsSpacingSm) {
            SectionHeader(title: "Background diagnostics")
                .accessibilityIdentifier("background-diagnostics-title")
            Text("Background timing is controlled by iOS. HealthKit updates can trigger additional syncs.")
                .foregroundStyle(Color.dsTextSecondary)
            Text(refreshStatus == .available ? String(localized: "System background refresh is available") : String(localized: "System background refresh is restricted or disabled"))
            Text(lowPower ? String(localized: "Low Power Mode is on") : String(localized: "Low Power Mode is off"))
            if let date = diagnostics.lastAccepted {
                Text("Last background receipt on this device")
                Text(date, format: .dateTime.day().month().hour().minute())
            }
            if diagnostics.events.isEmpty {
                Text("No background events recorded yet")
            }
            ForEach(diagnostics.events.suffix(8).reversed()) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.kind.label)
                    Text(event.date, format: .dateTime.day().month().hour().minute().second())
                        .foregroundStyle(Color.dsTextTertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("background-event-" + event.kind.rawValue)
            }
        }
        .font(.dsCaption)
        .foregroundStyle(Color.dsText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dsSpacing)
        .dsCard()
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in refreshSystemState() }
    }

    private func refreshSystemState() {
        refreshStatus = UIApplication.shared.backgroundRefreshStatus
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
