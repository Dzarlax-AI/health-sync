import SwiftUI
import SwiftData
import UIKit
import UserNotifications

@main
struct HealthSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    private var testColorSchemeOverride: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test-mode") else { return nil }
        if arguments.contains("--ui-test-force-dark-mode") { return .dark }
        if arguments.contains("--ui-test-force-light-mode") { return .light }
        return nil
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
                PushRegistrationManager.registerNotificationCategories()
                if !SyncRuntime.isTestMode {
                    Task {
                        await PushRegistrationManager.shared.handleAppBecameActive {
                            UNUserNotificationCenter.current().getNotificationSettings { settings in
                                guard settings.authorizationStatus == .authorized ||
                                        settings.authorizationStatus == .provisional
                                else { return }
                                DispatchQueue.main.async {
                                    UIApplication.shared.registerForRemoteNotifications()
                                }
                            }
                        }
                    }
                }
            case .background, .inactive:
                SyncEngine.shared.stopForegroundTimer()
                if phase == .background { BackgroundSyncManager.shared.scheduleNextSync() }
            @unknown default:
                break
            }
        }
    }
}
