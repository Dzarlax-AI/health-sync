import SwiftUI
import SwiftData

@main
struct HealthSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: SyncHistoryRecord.self)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                SyncEngine.shared.handleAppBecameActive()
            case .background, .inactive:
                SyncEngine.shared.stopForegroundTimer()
                if phase == .background { BackgroundSyncManager.shared.scheduleNextSync() }
            @unknown default:
                break
            }
        }
    }
}
