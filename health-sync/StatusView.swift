import SwiftUI

struct StatusView: View {
    // Placeholder — SyncEngine will populate these
    @State private var lastSync: Date? = nil
    @State private var lastPointCount: Int = 0
    @State private var isSyncing = false
    @State private var history: [SyncEntry] = SyncEntry.placeholders

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: .dsSpacingLg) {
                    summaryCard
                    historyCard
                }
                .padding(.dsSpacing)
            }
            .background(Color.dsBackground)
            .navigationTitle("Health Sync")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: syncNow) {
                        if isSyncing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label("Sync", systemImage: "arrow.trianglehead.2.clockwise")
                        }
                    }
                    .disabled(isSyncing)
                }
            }
        }
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        VStack(spacing: .dsSpacingLg) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Sync")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                    if let lastSync {
                        Text(lastSync, style: .relative)
                            .font(.dsHeading)
                            .foregroundStyle(Color.dsText)
                        Text("\(lastPointCount) points")
                            .font(.dsBodySm)
                            .foregroundStyle(Color.dsTextSecondary)
                    } else {
                        Text("Never")
                            .font(.dsHeading)
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                }
                Spacer()
                syncStatusBadge
            }

            Button(action: syncNow) {
                HStack {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                    Text(isSyncing ? "Syncing…" : "Sync Now")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(isSyncing)
        }
        .padding(.dsSpacing)
        .dsCard()
    }

    @ViewBuilder
    private var syncStatusBadge: some View {
        if isSyncing {
            DSStatusBadge(text: "Syncing", status: .warn)
        } else if let lastSync, Date().timeIntervalSince(lastSync) < 3600 {
            DSStatusBadge(text: "Up to date", status: .good)
        } else if lastSync != nil {
            DSStatusBadge(text: "Stale", status: .warn)
        } else {
            DSStatusBadge(text: "Never synced", status: .neutral)
        }
    }

    // MARK: - History card

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Syncs")
                .font(.dsSubhead)
                .foregroundStyle(Color.dsText)
                .padding(.horizontal, .dsSpacing)
                .padding(.top, .dsSpacing)
                .padding(.bottom, .dsSpacingSm)

            if history.isEmpty {
                Text("No sync history yet.")
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextTertiary)
                    .padding(.horizontal, .dsSpacing)
                    .padding(.bottom, .dsSpacing)
            } else {
                ForEach(Array(history.enumerated()), id: \.element.id) { idx, entry in
                    if idx > 0 { Divider().padding(.leading, .dsSpacing) }
                    SyncEntryRow(entry: entry)
                }
            }
        }
        .dsCard()
    }

    // MARK: - Actions

    private func syncNow() {
        isSyncing = true
        // TODO: call SyncEngine.shared.syncNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isSyncing = false
            lastSync = Date()
            lastPointCount = 142
        }
    }
}

// MARK: - SyncEntry model (placeholder until SwiftData model is wired)

struct SyncEntry: Identifiable {
    let id = UUID()
    let date: Date
    let points: Int
    let success: Bool
    let error: String?

    static let placeholders: [SyncEntry] = []
}

// MARK: - Row

private struct SyncEntryRow: View {
    let entry: SyncEntry

    var body: some View {
        HStack(spacing: .dsSpacingSm) {
            Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.success ? Color.dsGood : Color.dsDanger)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date, style: .relative)
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsText)
                if let error = entry.error {
                    Text(error)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsDanger)
                } else {
                    Text("\(entry.points) points")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }
            Spacer()
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.dsMono)
                .foregroundStyle(Color.dsTextTertiary)
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, 10)
    }
}

#Preview {
    StatusView()
}
