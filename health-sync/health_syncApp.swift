import SwiftUI
import SwiftData

@main
struct HealthSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    private var testColorSchemeOverride: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test-mode"),
              arguments.contains("--ui-test-force-dark-mode") else {
            return nil
        }
        return .dark
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(testColorSchemeOverride)
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
