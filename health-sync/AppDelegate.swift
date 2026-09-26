import UIKit
import HealthKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Foreground presentation rules for the user-facing sync notification
        // (gated behind the Settings toggle in SyncEngine.sendSyncNotification).
        UNUserNotificationCenter.current().delegate = self

        guard !SyncRuntime.isTestMode else { return true }

        // Must register before app finishes launching
        BackgroundSyncManager.shared.registerBGTask()

        guard HKHealthStore.isHealthDataAvailable() else { return true }

        // Register queries synchronously without requiring an unlocked API key.
        BackgroundSyncManager.shared.recoverAfterUnlock()

        return true
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        BackgroundSyncManager.shared.recoverAfterUnlock(retryPending: true)
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
