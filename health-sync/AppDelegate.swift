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

        // Must register before app finishes launching
        BackgroundSyncManager.shared.registerBGTask()

        guard HKHealthStore.isHealthDataAvailable() else { return true }

        // Register observers SYNCHRONOUSLY — HealthKit may fire callbacks on this
        // same launch, so they must be running before we return.
        BackgroundSyncManager.shared.setupObserverQueriesIfNeeded()
        BackgroundSyncManager.shared.scheduleNextSync()
        BackgroundSyncManager.shared.scheduleDailyResync()

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
