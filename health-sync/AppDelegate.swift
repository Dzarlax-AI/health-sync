import UIKit
import HealthKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Foreground presentation rules and interactive category for morning check-ins.
        UNUserNotificationCenter.current().delegate = self
        PushRegistrationManager.registerNotificationCategories()

        guard !SyncRuntime.isTestMode else { return true }

        // Must register before app finishes launching
        BackgroundSyncManager.shared.registerBGTask()

        refreshPushRegistrationIfEnabled(application)

        guard HKHealthStore.isHealthDataAvailable() else { return true }

        // Register queries synchronously without requiring an unlocked API key.
        BackgroundSyncManager.shared.recoverAfterUnlock()

        return true
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        BackgroundSyncManager.shared.recoverAfterUnlock(retryPending: true)
        Task { await PushRegistrationManager.shared.drainPendingDeregistrations() }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistrationManager.shared.handleDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Non-fatal: Inbox and Today remain functional without remote push.
    }

    // UNUserNotificationCenterDelegate — display notifications in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let actionID = response.actionIdentifier
        guard actionID == UNNotificationDefaultActionIdentifier ||
                actionID == PushNotificationConstants.checkinOpenActionID ||
                actionID == PushNotificationConstants.promptOpenActionID
        else {
            return
        }
        let userInfo = response.notification.request.content.userInfo
        _ = PushRegistrationManager.shared.routeNotification(userInfo: userInfo)
    }

    private func refreshPushRegistrationIfEnabled(_ application: UIApplication) {
        Task { await PushRegistrationManager.shared.drainPendingDeregistrations() }
        guard UserDefaults.standard.bool(forKey: PushNotificationConstants.enabledDefaultsKey) else {
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional
            else { return }
            DispatchQueue.main.async {
                guard UserDefaults.standard.bool(forKey: PushNotificationConstants.enabledDefaultsKey) else { return }
                application.registerForRemoteNotifications()
            }
        }
    }
}
