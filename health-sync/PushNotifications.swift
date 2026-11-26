import CryptoKit
import Foundation
import Security
import UIKit
import UserNotifications

enum PushNotificationConstants {
    static let checkinCategoryID = "CHECKIN_MORNING"
    static let checkinOpenActionID = "checkin.open"
    static let enabledDefaultsKey = "morningPushEnabled"

    static let deviceIDAccount = "health-sync.push.device-id"
    static let activeRegistrationAccount = "health-sync.push.active-registration"
    static let pendingDeregistrationsAccount = "health-sync.push.pending-deregistrations"

    static let deregistrationTTL: TimeInterval = 7 * 24 * 60 * 60
    static let heartbeatRefreshInterval: TimeInterval = 24 * 60 * 60
    static let unsupportedRetryInterval: TimeInterval = 15 * 60
}

struct PushDeviceRegisterRequest: Encodable, Equatable {
    let deviceID: String
    let apnsToken: String
    let apnsEnv: String
    let bundleID: String
    let locale: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case apnsToken = "apns_token"
        case apnsEnv = "apns_env"
        case bundleID = "bundle_id"
        case locale
    }
}

struct PushDeviceRegisterResponse: Decodable, Equatable {
    let deviceID: String
    let bindingID: String
    let enabled: Bool
    let registrationVersion: Int64
    let apnsEnv: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case bindingID = "binding_id"
        case enabled
        case registrationVersion = "registration_version"
        case apnsEnv = "apns_env"
    }
}

struct ActivePushRegistration: Codable, Equatable {
    let deviceID: String
    let bindingID: String
    let endpoint: URL
    let apiKey: String
    let endpointFingerprint: String
    let tokenHash: String
    let apnsEnv: String
    let locale: String
    let confirmedAt: Date
}

struct PendingPushDeregistration: Codable, Equatable {
    let deviceID: String
    let bindingID: String
    let endpoint: URL
    let apiKey: String
    let queuedAt: Date
}

enum PushDestination: Equatable, Identifiable {
    case morningReport(itemID: String)
    case checkinPrompt(promptID: String)

    var id: String {
        switch self {
        case .morningReport(let id): return "mr-\(id)"
        case .checkinPrompt(let id): return "ci-\(id)"
        }
    }

    var itemID: String {
        switch self {
        case .morningReport(let id): return id
        case .checkinPrompt(let id): return id
        }
    }
}

enum APNsEnvironmentResolver {
    /// Reads `aps-environment` from the signed app's `embedded.mobileprovision`
    /// when present, falling back to build configuration on Simulator/tests.
    static func resolve(mobileProvisionData: Data? = loadEmbeddedMobileProvision()) -> String {
        if let data = mobileProvisionData, let env = parseAPNsEnvironment(from: data) {
            return env
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    static func parseAPNsEnvironment(from profileData: Data) -> String? {
        guard let startTag = "<plist".data(using: .utf8),
              let endTag = "</plist>".data(using: .utf8),
              let startRange = profileData.range(of: startTag),
              let endRange = profileData.range(of: endTag, in: startRange.lowerBound..<profileData.endIndex)
        else {
            return nil
        }
        let plistData = profileData.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let raw = entitlements["aps-environment"] as? String
        else {
            return nil
        }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }

    private static func loadEmbeddedMobileProvision() -> Data? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}

enum PushNotificationPayload {
    /// Parses an incoming APNs userInfo dictionary ONLY when its opaque `reg_id`
    /// matches the active local registration's `binding_id`. Stale pushes from
    /// previous profiles/servers are discarded before routing.
    static func parseDestination(
        userInfo: [AnyHashable: Any],
        expectedBindingID: String?
    ) -> PushDestination? {
        guard let expected = expectedBindingID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !expected.isEmpty,
              let regID = (userInfo["reg_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              regID == expected,
              let kind = userInfo["kind"] as? String
        else {
            return nil
        }
        switch kind {
        case "morning_report":
            guard let itemID = (userInfo["inbox_item_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !itemID.isEmpty
            else { return nil }
            return .morningReport(itemID: itemID)
        case "prompt_checkin":
            guard let promptID = (userInfo["prompt_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !promptID.isEmpty
            else { return nil }
            return .checkinPrompt(promptID: promptID)
        default:
            return nil
        }
    }
}

@MainActor
@Observable
final class PushNavigationRouter {
    static let shared = PushNavigationRouter()

    private(set) var pendingDestination: PushDestination?

    func enqueue(_ destination: PushDestination) {
        pendingDestination = destination
    }

    func consume() -> PushDestination? {
        defer { pendingDestination = nil }
        return pendingDestination
    }
}

@MainActor
final class PushKeychainStorage {
    private let access: KeychainAccess

    init(access: KeychainAccess) {
        self.access = access
    }

    func readData(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        let (status, result) = access.copy(query)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed { throw APIKeyError.locked }
        guard status == errSecSuccess else { throw APIKeyError.failure(status) }
        return result as? Data
    }

    func writeData(_ data: Data?, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account
        ]
        guard let data else {
            let status = access.delete(query)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw APIKeyError.failure(status)
            }
            return
        }
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = access.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            let addStatus = access.add(query.merging(attributes) { $1 })
            if addStatus == errSecInteractionNotAllowed { throw APIKeyError.locked }
            guard addStatus == errSecSuccess else { throw APIKeyError.failure(addStatus) }
        } else if status == errSecInteractionNotAllowed {
            throw APIKeyError.locked
        } else if status != errSecSuccess {
            throw APIKeyError.failure(status)
        }
    }
}

@MainActor
private struct PushSystemKeychainAccess: KeychainAccess {
    func copy(_ query: [CFString: Any]) -> (OSStatus, Any?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [CFString: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func delete(_ query: [CFString: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

@MainActor
@Observable
final class PushRegistrationManager {
    typealias RegisterCall = @MainActor (PushDeviceRegisterRequest, URL, String) async throws -> PushDeviceRegisterResponse
    typealias DeleteCall = @MainActor (String, String, URL, String) async throws -> Void
    typealias ConfigSnapshot = @MainActor () throws -> SyncConfiguration

    static let shared = PushRegistrationManager()

    private(set) var lastRegistrationError: String?
    private(set) var unsupportedRetryAfter: Date?

    private let store: PushKeychainStorage
    private let registerCall: RegisterCall
    private let deleteCall: DeleteCall
    private let configSnapshot: ConfigSnapshot
    private let isPushEnabled: @MainActor () -> Bool
    private let resolveAPNsEnv: () -> String
    private let bundleIDProvider: () -> String
    private let localeProvider: () -> String
    private let now: () -> Date
    private struct InFlightDeregistration {
        let endpointFingerprint: String
        let task: Task<Void, Never>
    }

    private var lastKnownTokenHex: String?
    private var registrationEpoch = UUID()
    private var unsupportedRetryState: (fingerprint: String, retryAfter: Date)?
    private var inFlightDeregistrations: [String: InFlightDeregistration] = [:]
    private var inFlightRegistrations: [String: Int] = [:]
    private var inFlightRegistrationTasks: [String: Task<Void, Never>] = [:]
    private var pendingRegistrationFingerprints: Set<String> = []
    private var deferredDeregistrationFingerprints: Set<String> = []

    init(
        keychain: KeychainAccess? = nil,
        registerCall: @escaping RegisterCall = { req, endpoint, apiKey in
            try await ServerClient.shared.registerPushDevice(req, endpoint: endpoint, apiKey: apiKey)
        },
        deleteCall: @escaping DeleteCall = { deviceID, bindingID, endpoint, apiKey in
            try await ServerClient.shared.deletePushDeviceBinding(
                deviceID: deviceID,
                bindingID: bindingID,
                endpoint: endpoint,
                apiKey: apiKey
            )
        },
        configSnapshot: @escaping ConfigSnapshot = { try UserDefaultsSyncConfiguration.shared.snapshot() },
        isPushEnabled: @escaping @MainActor () -> Bool = {
            UserDefaults.standard.bool(forKey: PushNotificationConstants.enabledDefaultsKey)
        },
        resolveAPNsEnv: @escaping () -> String = { APNsEnvironmentResolver.resolve() },
        bundleIDProvider: @escaping () -> String = { Bundle.main.bundleIdentifier ?? "com.dzarlax.health-sync" },
        localeProvider: @escaping () -> String = {
            switch Locale.current.language.languageCode?.identifier {
            case "ru": return "ru"
            case "sr": return "sr"
            default: return "en"
            }
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = PushKeychainStorage(access: keychain ?? PushSystemKeychainAccess())
        self.registerCall = registerCall
        self.deleteCall = deleteCall
        self.configSnapshot = configSnapshot
        self.isPushEnabled = isPushEnabled
        self.resolveAPNsEnv = resolveAPNsEnv
        self.bundleIDProvider = bundleIDProvider
        self.localeProvider = localeProvider
        self.now = now
    }

    static func registerNotificationCategories(center: UNUserNotificationCenter = .current()) {
        let openAction = UNNotificationAction(
            identifier: PushNotificationConstants.checkinOpenActionID,
            title: String(localized: "Answer"),
            options: [.foreground]
        )
        let checkinCategory = UNNotificationCategory(
            identifier: PushNotificationConstants.checkinCategoryID,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([checkinCategory])
    }

    func ensureDeviceID() throws -> String {
        if let data = try store.readData(account: PushNotificationConstants.deviceIDAccount),
           let existing = String(data: data, encoding: .utf8),
           UUID(uuidString: existing) != nil {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        try store.writeData(Data(fresh.utf8), account: PushNotificationConstants.deviceIDAccount)
        return fresh
    }

    func loadActiveRegistration() -> ActivePushRegistration? {
        guard let data = try? store.readData(account: PushNotificationConstants.activeRegistrationAccount) else {
            return nil
        }
        return try? JSONDecoder().decode(ActivePushRegistration.self, from: data)
    }

    func loadPendingDeregistrations() -> [PendingPushDeregistration] {
        guard let data = try? store.readData(account: PushNotificationConstants.pendingDeregistrationsAccount),
              let items = try? JSONDecoder().decode([PendingPushDeregistration].self, from: data)
        else {
            return []
        }
        return items
    }

    /// Returns the active binding ID ONLY when it matches the currently configured
    /// profile fingerprint. Used to reject notifications from previous profiles.
    func activeBindingIDForCurrentProfile() -> String? {
        guard let config = try? configSnapshot(),
              let active = loadActiveRegistration(),
              active.endpointFingerprint == config.fingerprint
        else {
            return nil
        }
        return active.bindingID
    }

    @discardableResult
    func routeNotification(userInfo: [AnyHashable: Any], router: PushNavigationRouter? = nil) -> PushDestination? {
        let targetRouter = router ?? PushNavigationRouter.shared
        guard let destination = PushNotificationPayload.parseDestination(
            userInfo: userInfo,
            expectedBindingID: activeBindingIDForCurrentProfile()
        ) else {
            return nil
        }
        targetRouter.enqueue(destination)
        return destination
    }

    func handleDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        lastKnownTokenHex = hex
        Task { await syncRegistration(tokenHex: hex) }
    }

    func syncRegistration(tokenHex: String, drainDeregistrations: Bool = true) async {
        lastKnownTokenHex = tokenHex
        let initialEpoch = registrationEpoch
        await reconcileProfileSwitchIfNeeded()
        if drainDeregistrations {
            await drainPendingDeregistrations()
        }

        guard initialEpoch == registrationEpoch, isPushEnabled() else { return }
        guard let config = try? configSnapshot() else { return }
        let fingerprint = config.fingerprint

        // Serialize POSTs per profile: if a registration loop is already running
        // for this profile, mark a coalesced follow-up pass (which will read the
        // latest `lastKnownTokenHex`) and await its completion instead of running
        // two concurrent POSTs that could overwrite a newer APNs token on server.
        if let existingTask = inFlightRegistrationTasks[fingerprint] {
            pendingRegistrationFingerprints.insert(fingerprint)
            await existingTask.value
            return
        }

        let task = Task { @MainActor [self] in
            defer {
                self.inFlightRegistrationTasks.removeValue(forKey: fingerprint)
                self.pendingRegistrationFingerprints.remove(fingerprint)
            }
            await self.runSerializedRegistrationLoop(
                forFingerprint: fingerprint,
                initialEpoch: initialEpoch
            )
        }
        inFlightRegistrationTasks[fingerprint] = task
        await task.value
    }

    private func runSerializedRegistrationLoop(forFingerprint fingerprint: String, initialEpoch: UUID) async {
        var expectedEpoch = initialEpoch
        var isFirstPass = true

        while true {
            if !isFirstPass {
                guard pendingRegistrationFingerprints.remove(fingerprint) != nil else {
                    break
                }
                expectedEpoch = registrationEpoch
            }
            isFirstPass = false

            guard expectedEpoch == registrationEpoch,
                  isPushEnabled(),
                  let config = try? configSnapshot(),
                  config.fingerprint == fingerprint
            else {
                break
            }

            // Ensure any in-flight DELETE targeting this same profile finishes before
            // sending POST so the server cannot reuse a binding_id that a racing
            // DELETE is about to disable.
            await waitForInFlightDeregistrations(forFingerprint: fingerprint)

            guard isPushEnabled(),
                  let refreshedConfig = try? configSnapshot(),
                  refreshedConfig.fingerprint == fingerprint,
                  let latestTokenHex = lastKnownTokenHex
            else {
                break
            }
            if expectedEpoch != registrationEpoch {
                if pendingRegistrationFingerprints.remove(fingerprint) != nil {
                    expectedEpoch = registrationEpoch
                } else {
                    break
                }
            }

            let currentNow = now()
            if let retryState = unsupportedRetryState,
               retryState.fingerprint == fingerprint,
               currentNow < retryState.retryAfter {
                continue
            }

            let env = resolveAPNsEnv()
            let locale = localeProvider()
            let tokenHash = Self.sha256Hex(latestTokenHex)

            if let active = loadActiveRegistration(),
               active.endpointFingerprint == fingerprint,
               active.tokenHash == tokenHash,
               active.apnsEnv == env,
               active.locale == locale,
               currentNow.timeIntervalSince(active.confirmedAt) < PushNotificationConstants.heartbeatRefreshInterval {
                continue
            }

            let capturedEpoch = expectedEpoch
            let capturedConfig = refreshedConfig

            // Hold mutual exclusion against DELETE for the same profile across the
            // entire POST suspension window so a queued DELETE cannot run while
            // POST is in flight and disable a binding_id the server just reused.
            inFlightRegistrations[fingerprint, default: 0] += 1
            let registerResult: Result<PushDeviceRegisterResponse, Error>
            do {
                let deviceID = try ensureDeviceID()
                let response = try await registerCall(
                    PushDeviceRegisterRequest(
                        deviceID: deviceID,
                        apnsToken: latestTokenHex,
                        apnsEnv: env,
                        bundleID: bundleIDProvider(),
                        locale: locale
                    ),
                    capturedConfig.endpoint,
                    capturedConfig.apiKey
                )
                registerResult = .success(response)
            } catch {
                registerResult = .failure(error)
            }

            // Decrement and commit local state synchronously (no `await` in between)
            // before running any deferred or newly-queued deregistrations.
            let remainingRegistrations = (inFlightRegistrations[fingerprint] ?? 1) - 1
            if remainingRegistrations <= 0 {
                inFlightRegistrations.removeValue(forKey: fingerprint)
            } else {
                inFlightRegistrations[fingerprint] = remainingRegistrations
            }

            var shouldDrainDeregistrations = false

            switch registerResult {
            case .success(let response):
                let stillSameProfile = (try? configSnapshot())?.fingerprint == fingerprint
                let pushStillEnabled = isPushEnabled()

                // If the user switched away from this profile or disabled pushes while
                // POST was in flight, do NOT persist the stale registration — enqueue
                // DELETE for the committed binding_id on the original server immediately.
                if !pushStillEnabled || !stillSameProfile {
                    enqueueDeregistration(PendingPushDeregistration(
                        deviceID: response.deviceID,
                        bindingID: response.bindingID,
                        endpoint: capturedConfig.endpoint,
                        apiKey: capturedConfig.apiKey,
                        queuedAt: now()
                    ))
                    shouldDrainDeregistrations = true
                } else if capturedEpoch == registrationEpoch {
                    let record = ActivePushRegistration(
                        deviceID: response.deviceID,
                        bindingID: response.bindingID,
                        endpoint: capturedConfig.endpoint,
                        apiKey: capturedConfig.apiKey,
                        endpointFingerprint: fingerprint,
                        tokenHash: tokenHash,
                        apnsEnv: response.apnsEnv,
                        locale: locale,
                        confirmedAt: now()
                    )
                    do {
                        try saveActiveRegistration(record)
                        lastRegistrationError = nil
                        unsupportedRetryState = nil
                        unsupportedRetryAfter = nil
                    } catch {
                        lastRegistrationError = error.localizedDescription
                    }
                }
                // Rapid A -> B -> A or disable -> re-enable (`capturedEpoch != registrationEpoch`
                // while `pushStillEnabled && stillSameProfile`): drop the stale response
                // without deleting or overwriting; a pending follow-up iteration will
                // re-POST with the current epoch and latest token.

            case .failure(let error):
                let stillSameProfile = (try? configSnapshot())?.fingerprint == fingerprint
                if capturedEpoch == registrationEpoch, stillSameProfile {
                    if let serverError = error as? ServerError, case .http(404, _) = serverError {
                        let retryAt = now().addingTimeInterval(PushNotificationConstants.unsupportedRetryInterval)
                        unsupportedRetryState = (fingerprint, retryAt)
                        unsupportedRetryAfter = retryAt
                        lastRegistrationError = nil
                    } else {
                        lastRegistrationError = error.localizedDescription
                    }
                }
            }

            if remainingRegistrations <= 0,
               deferredDeregistrationFingerprints.remove(fingerprint) != nil {
                shouldDrainDeregistrations = true
            }

            if shouldDrainDeregistrations {
                await drainPendingDeregistrations()
            }
        }
    }

    /// Moves any active registration for a previous server/profile into the
    /// durable deregistration queue, drains it, and re-registers on the new
    /// server when notifications remain enabled.
    func handleConfigurationChanged(pushEnabled: Bool) async {
        let capturedEpoch = UUID()
        registrationEpoch = capturedEpoch
        unsupportedRetryState = nil
        unsupportedRetryAfter = nil
        await reconcileProfileSwitchIfNeeded()
        await drainPendingDeregistrations()
        guard capturedEpoch == registrationEpoch else { return }
        if pushEnabled, isPushEnabled(), let token = lastKnownTokenHex {
            await syncRegistration(tokenHex: token, drainDeregistrations: false)
        }
    }

    func disablePushNotifications() async {
        registrationEpoch = UUID()
        unsupportedRetryState = nil
        unsupportedRetryAfter = nil
        if let active = loadActiveRegistration() {
            enqueueDeregistration(from: active)
            try? saveActiveRegistration(nil)
        }
        await drainPendingDeregistrations()
    }

    /// Invoked on foreground activation: drains pending deregistrations and,
    /// when pushes are enabled, retries registration (respecting the bounded
    /// 404 cooldown and 24h heartbeat) so pilot activation is picked up without
    /// requiring an app restart.
    func handleAppBecameActive(requestRemoteRegistration: (@MainActor () -> Void)? = nil) async {
        let capturedEpoch = registrationEpoch
        await reconcileProfileSwitchIfNeeded()
        await drainPendingDeregistrations()
        guard capturedEpoch == registrationEpoch, isPushEnabled() else { return }
        if let token = lastKnownTokenHex {
            await syncRegistration(tokenHex: token, drainDeregistrations: false)
        } else {
            requestRemoteRegistration?()
        }
    }

    func drainPendingDeregistrations() async {
        let snapshot = loadPendingDeregistrations()
        guard !snapshot.isEmpty else { return }
        let currentNow = now()

        for item in snapshot {
            let dedupKey = "\(item.deviceID):\(item.bindingID)"
            guard inFlightDeregistrations[dedupKey] == nil else { continue }

            // Re-check the live queue in case an earlier iteration's await
            // allowed a POST to purge this entry via saveActiveRegistration.
            guard loadPendingDeregistrations().contains(where: {
                $0.deviceID == item.deviceID && $0.bindingID == item.bindingID
            }) else {
                continue
            }

            let itemFingerprint = UserDefaultsSyncConfiguration.fingerprint(
                endpoint: item.endpoint,
                apiKey: item.apiKey
            )

            // Defer DELETE while a POST for the same profile is in flight so
            // it cannot race and disable a binding_id that POST is receiving.
            if inFlightRegistrations[itemFingerprint, default: 0] > 0 {
                deferredDeregistrationFingerprints.insert(itemFingerprint)
                continue
            }

            // Never deregister a binding that is currently active on the
            // selected profile while push notifications are enabled.
            if isPushEnabled(),
               let currentFingerprint = (try? configSnapshot())?.fingerprint,
               currentFingerprint == itemFingerprint,
               let active = loadActiveRegistration(),
               active.endpointFingerprint == itemFingerprint,
               active.deviceID == item.deviceID,
               active.bindingID == item.bindingID {
                removePendingDeregistration(deviceID: item.deviceID, bindingID: item.bindingID)
                continue
            }

            if currentNow.timeIntervalSince(item.queuedAt) > PushNotificationConstants.deregistrationTTL {
                removePendingDeregistration(deviceID: item.deviceID, bindingID: item.bindingID)
                continue
            }

            let deleteTask = Task { @MainActor [self] in
                defer { self.inFlightDeregistrations.removeValue(forKey: dedupKey) }
                do {
                    try await self.deleteCall(item.deviceID, item.bindingID, item.endpoint, item.apiKey)
                    // Remove ONLY this processed entry from the live queue so
                    // items added concurrently while DELETE was in flight are preserved.
                    self.removePendingDeregistration(deviceID: item.deviceID, bindingID: item.bindingID)
                } catch let error as ServerError {
                    switch error {
                    case .http(let code, _) where code == 400 || code == 401 || code == 403 || code == 404:
                        self.removePendingDeregistration(deviceID: item.deviceID, bindingID: item.bindingID)
                    default:
                        break
                    }
                } catch {
                    // Transient error: leave entry in live queue for later retry.
                }
            }
            inFlightDeregistrations[dedupKey] = InFlightDeregistration(
                endpointFingerprint: itemFingerprint,
                task: deleteTask
            )
            await deleteTask.value
        }
    }

    private func waitForInFlightDeregistrations(forFingerprint fingerprint: String) async {
        while let pending = inFlightDeregistrations.values.first(where: { $0.endpointFingerprint == fingerprint }) {
            await pending.task.value
        }
    }

    private func reconcileProfileSwitchIfNeeded() async {
        guard let active = loadActiveRegistration() else { return }
        let currentFingerprint = (try? configSnapshot())?.fingerprint
        if currentFingerprint != active.endpointFingerprint {
            enqueueDeregistration(from: active)
            try? saveActiveRegistration(nil)
        }
    }

    private func enqueueDeregistration(from active: ActivePushRegistration) {
        enqueueDeregistration(PendingPushDeregistration(
            deviceID: active.deviceID,
            bindingID: active.bindingID,
            endpoint: active.endpoint,
            apiKey: active.apiKey,
            queuedAt: now()
        ))
    }

    private func enqueueDeregistration(_ entry: PendingPushDeregistration) {
        var queue = loadPendingDeregistrations()
        if !queue.contains(where: { $0.deviceID == entry.deviceID && $0.bindingID == entry.bindingID }) {
            queue.append(entry)
            savePendingDeregistrations(queue)
        }
    }

    private func removePendingDeregistration(deviceID: String, bindingID: String) {
        var live = loadPendingDeregistrations()
        live.removeAll { $0.deviceID == deviceID && $0.bindingID == bindingID }
        savePendingDeregistrations(live)
    }

    private func saveActiveRegistration(_ record: ActivePushRegistration?) throws {
        guard let record else {
            try store.writeData(nil, account: PushNotificationConstants.activeRegistrationAccount)
            return
        }
        let encoded = try JSONEncoder().encode(record)
        try store.writeData(encoded, account: PushNotificationConstants.activeRegistrationAccount)
        removePendingDeregistration(deviceID: record.deviceID, bindingID: record.bindingID)
    }

    private func savePendingDeregistrations(_ items: [PendingPushDeregistration]) {
        if items.isEmpty {
            try? store.writeData(nil, account: PushNotificationConstants.pendingDeregistrationsAccount)
            return
        }
        if let encoded = try? JSONEncoder().encode(items) {
            try? store.writeData(encoded, account: PushNotificationConstants.pendingDeregistrationsAccount)
        }
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
