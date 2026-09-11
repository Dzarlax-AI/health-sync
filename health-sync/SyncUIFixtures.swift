import Foundation

/// UI-only fixture projection used by isolated simulator tests. It is gated
/// by the explicit test-mode launch argument and never participates in the
/// production engine or transport composition.
enum SyncUIFixtures {
    static var state: SyncUIState? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test-mode"), let status = SyncRuntime.uiFixture else {
            return nil
        }

        let acceptedAt = Date().addingTimeInterval(-600)
        let pendingSince = Date().addingTimeInterval(-300)
        let retryAt = Date().addingTimeInterval(120)
        let retryFailure = SyncFailure(code: .transport, message: "Retry scheduled")

        switch status {
        case .notConfigured:
            return SyncUIState(
                status: .notConfigured,
                metrics: .idle,
                workouts: .idle,
                primaryAction: .configure,
                canSync: false
            )
        case .noData:
            let channel = SyncChannelSnapshot(
                status: .noData,
                lastAcceptedAt: nil,
                pendingSince: nil,
                retryAt: nil,
                acceptedCount: 0,
                failure: nil
            )
            return SyncUIState(
                status: .noData,
                metrics: channel,
                workouts: channel,
                primaryAction: .sync,
                canSync: true
            )
        case .accepted:
            let metrics = SyncChannelSnapshot(
                status: .accepted,
                lastAcceptedAt: acceptedAt,
                pendingSince: nil,
                retryAt: nil,
                acceptedCount: 42,
                failure: nil
            )
            let workouts = SyncChannelSnapshot(
                status: .accepted,
                lastAcceptedAt: acceptedAt,
                pendingSince: nil,
                retryAt: nil,
                acceptedCount: 2,
                failure: nil
            )
            return SyncUIState(
                status: .accepted,
                metrics: metrics,
                workouts: workouts,
                primaryAction: .sync,
                canSync: true
            )
        case .partial:
            let metrics = SyncChannelSnapshot(
                status: .accepted,
                lastAcceptedAt: acceptedAt,
                pendingSince: nil,
                retryAt: nil,
                acceptedCount: 42,
                failure: nil
            )
            let workouts = SyncChannelSnapshot(
                status: .retryPending,
                lastAcceptedAt: nil,
                pendingSince: pendingSince,
                retryAt: retryAt,
                acceptedCount: 0,
                failure: retryFailure
            )
            return SyncUIState(
                status: .partial,
                metrics: metrics,
                workouts: workouts,
                primaryAction: .retry,
                canSync: true
            )
        case .retryPending:
            let channel = SyncChannelSnapshot(
                status: .retryPending,
                lastAcceptedAt: nil,
                pendingSince: pendingSince,
                retryAt: retryAt,
                acceptedCount: 0,
                failure: retryFailure
            )
            return SyncUIState(
                status: .retryPending,
                metrics: channel,
                workouts: channel,
                primaryAction: .retry,
                canSync: true
            )
        case .sending, .error, .disabled:
            return nil
        }
    }
}
