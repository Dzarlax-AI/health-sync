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
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard UserDefaults.standard.bool(forKey: PushNotificationConstants.enabledDefaultsKey),
                  settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            else { return }
            application.registerForRemoteNotifications()

            if await BadgeAuthorizationUpgrade.requestIfNeeded(
                authorization: settings.authorizationStatus,
                badgeSetting: settings.badgeSetting,
                previouslyRequested: UserDefaults.standard.bool(forKey: BadgeAuthorizationUpgrade.defaultsKey),
                request: { try await center.requestAuthorization(options: [.badge]) }
            ) {
                UserDefaults.standard.set(true, forKey: BadgeAuthorizationUpgrade.defaultsKey)
            }
        }
    }
}

@MainActor
enum BadgeAuthorizationUpgrade {
    static let defaultsKey = "health-sync.push.badge-authorization-requested"

    // Existing installations can have alert and sound permission without badges.
    // Respect a completed request, even when the user chose to leave badges off.
    static func requestIfNeeded(
        authorization: UNAuthorizationStatus,
        badgeSetting: UNNotificationSetting,
        previouslyRequested: Bool,
        request: () async throws -> Bool
    ) async -> Bool {
        guard !previouslyRequested, badgeSetting == .disabled,
              authorization == .authorized || authorization == .provisional
        else { return false }
        do {
            _ = try await request()
            return true
        } catch {
            return false
        }
    }
}
