import SwiftUI

@main
struct HealthSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                SyncEngine.shared.startForegroundTimer()
            case .background, .inactive:
                SyncEngine.shared.stopForegroundTimer()
            @unknown default:
                break
            }
        }
    }
}
