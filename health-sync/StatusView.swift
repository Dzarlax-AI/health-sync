import SwiftUI

struct StatusView: View {
    private let engine = SyncEngine.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: .dsSpacingLg) {
                    summaryCard
                    if let error = engine.lastError {
                        errorCard(error)
                    }
                    historyCard
                }
                .padding(.dsSpacing)
            }
            .background(Color.dsBackground)
            .navigationTitle("Health Sync")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { Task { await engine.syncNow() } }) {
                        if engine.isSyncing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label("Sync", systemImage: "arrow.trianglehead.2.clockwise")
                        }
                    }
                    .disabled(engine.isSyncing)
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
                    if let lastSync = engine.lastSync {
                        Text(lastSync, style: .relative)
                            .font(.dsHeading)
                            .foregroundStyle(Color.dsText)
                        Text("\(engine.lastPointCount) points")
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

            Button(action: { Task { await engine.syncNow() } }) {
                HStack {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                    Text(engine.isSyncing ? "Syncing…" : "Sync Now")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(engine.isSyncing)
        }
        .padding(.dsSpacing)
        .dsCard()
    }

    @ViewBuilder
    private var syncStatusBadge: some View {
        if engine.isSyncing {
            DSStatusBadge(text: "Syncing", status: .warn)
        } else if let lastSync = engine.lastSync, Date().timeIntervalSince(lastSync) < 3600 {
            DSStatusBadge(text: "Up to date", status: .good)
        } else if engine.lastSync != nil {
            DSStatusBadge(text: "Stale", status: .warn)
        } else {
            DSStatusBadge(text: "Never synced", status: .neutral)
        }
    }

    // MARK: - Error card

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: .dsSpacingSm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.dsDanger)
            Text(message)
                .font(.dsBodySm)
                .foregroundStyle(Color.dsDanger)
            Spacer()
        }
        .padding(.dsSpacing)
        .dsCard()
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

            if engine.history.isEmpty {
                Text("No sync history yet.")
                    .font(.dsBodySm)
                    .foregroundStyle(Color.dsTextTertiary)
                    .padding(.horizontal, .dsSpacing)
                    .padding(.bottom, .dsSpacing)
            } else {
                ForEach(Array(engine.history.enumerated()), id: \.element.id) { idx, entry in
                    if idx > 0 { Divider().padding(.leading, .dsSpacing) }
                    SyncEntryRow(entry: entry)
                }
            }
        }
        .dsCard()
    }
}

// MARK: - SyncEntry model

struct SyncEntry: Identifiable {
    let id = UUID()
    let date: Date
    let points: Int
    let success: Bool
    let error: String?
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
