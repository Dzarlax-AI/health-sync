import UIKit
import HealthKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Show notifications even when app is in foreground (for debugging)
        UNUserNotificationCenter.current().delegate = self

        // Must register before app finishes launching
        BackgroundSyncManager.shared.registerBGTask()

        guard HKHealthStore.isHealthDataAvailable() else { return true }

        // Register observers SYNCHRONOUSLY — HealthKit may fire callbacks on this
        // same launch, so they must be running before we return.
        BackgroundSyncManager.shared.setupObserverQueriesIfNeeded()
        BackgroundSyncManager.shared.scheduleNextSync()

        // Debug: notify every time app launches (including background wakeups)
        let n = UNMutableNotificationContent()
        n.title = "App launched"
        let isBG = UIApplication.shared.applicationState == .background
        n.body = "background: \(isBG ? "yes" : "no")"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil)
        )

        return true
    }

    // UNUserNotificationCenterDelegate — display notifications in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
