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
    typealias RegisterCall = @MainActor (PushDeviceRegisterRequest) async throws -> PushDeviceRegisterResponse
    typealias DeleteCall = @MainActor (String, String, URL, String) async throws -> Void
    typealias ConfigSnapshot = @MainActor () throws -> SyncConfiguration

    static let shared = PushRegistrationManager()

    private(set) var lastRegistrationError: String?
    private(set) var unsupportedFingerprint: String?

    private let store: PushKeychainStorage
    private let registerCall: RegisterCall
    private let deleteCall: DeleteCall
    private let configSnapshot: ConfigSnapshot
    private let resolveAPNsEnv: () -> String
    private let bundleIDProvider: () -> String
    private let localeProvider: () -> String
    private let now: () -> Date
    private var lastKnownTokenHex: String?

    init(
        keychain: KeychainAccess? = nil,
        registerCall: @escaping RegisterCall = { req in try await ServerClient.shared.registerPushDevice(req) },
        deleteCall: @escaping DeleteCall = { deviceID, bindingID, endpoint, apiKey in
            try await ServerClient.shared.deletePushDeviceBinding(
                deviceID: deviceID,
                bindingID: bindingID,
                endpoint: endpoint,
                apiKey: apiKey
            )
        },
        configSnapshot: @escaping ConfigSnapshot = { try UserDefaultsSyncConfiguration.shared.snapshot() },
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
        await reconcileProfileSwitchIfNeeded()
        if drainDeregistrations {
            await drainPendingDeregistrations()
        }

        guard let config = try? configSnapshot() else { return }
        if unsupportedFingerprint == config.fingerprint { return }

        let env = resolveAPNsEnv()
        let locale = localeProvider()
        let tokenHash = Self.sha256Hex(tokenHex)
        let currentNow = now()

        if let active = loadActiveRegistration(),
           active.endpointFingerprint == config.fingerprint,
           active.tokenHash == tokenHash,
           active.apnsEnv == env,
           active.locale == locale,
           currentNow.timeIntervalSince(active.confirmedAt) < PushNotificationConstants.heartbeatRefreshInterval {
            return
        }

        do {
            let deviceID = try ensureDeviceID()
            let response = try await registerCall(PushDeviceRegisterRequest(
                deviceID: deviceID,
                apnsToken: tokenHex,
                apnsEnv: env,
                bundleID: bundleIDProvider(),
                locale: locale
            ))
            let record = ActivePushRegistration(
                deviceID: response.deviceID,
                bindingID: response.bindingID,
                endpoint: config.endpoint,
                apiKey: config.apiKey,
                endpointFingerprint: config.fingerprint,
                tokenHash: tokenHash,
                apnsEnv: response.apnsEnv,
                locale: locale,
                confirmedAt: currentNow
            )
            try saveActiveRegistration(record)
            lastRegistrationError = nil
            unsupportedFingerprint = nil
        } catch let error as ServerError {
            if case .http(404, _) = error {
                unsupportedFingerprint = config.fingerprint
                lastRegistrationError = nil
            } else {
                lastRegistrationError = error.localizedDescription
            }
        } catch {
            lastRegistrationError = error.localizedDescription
        }
    }

    /// Moves any active registration for a previous server/profile into the
    /// durable deregistration queue, drains it, and re-registers on the new
    /// server when notifications remain enabled.
    func handleConfigurationChanged(pushEnabled: Bool) async {
        unsupportedFingerprint = nil
        await reconcileProfileSwitchIfNeeded()
        await drainPendingDeregistrations()
        if pushEnabled, let token = lastKnownTokenHex {
            await syncRegistration(tokenHex: token, drainDeregistrations: false)
        }
    }

    func disablePushNotifications() async {
        if let active = loadActiveRegistration() {
            enqueueDeregistration(from: active)
            try? saveActiveRegistration(nil)
        }
        await drainPendingDeregistrations()
    }

    func drainPendingDeregistrations() async {
        var queue = loadPendingDeregistrations()
        guard !queue.isEmpty else { return }
        let currentNow = now()
        var remaining: [PendingPushDeregistration] = []

        for item in queue {
            if currentNow.timeIntervalSince(item.queuedAt) > PushNotificationConstants.deregistrationTTL {
                continue
            }
            do {
                try await deleteCall(item.deviceID, item.bindingID, item.endpoint, item.apiKey)
                // 204 success -> drop from queue
            } catch let error as ServerError {
                switch error {
                case .http(let code, _) where code == 400 || code == 401 || code == 403 || code == 404:
                    // Terminal response -> do not retry forever
                    continue
                default:
                    remaining.append(item)
                }
            } catch {
                remaining.append(item)
            }
        }
        queue = remaining
        savePendingDeregistrations(queue)
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
        var queue = loadPendingDeregistrations()
        if !queue.contains(where: { $0.deviceID == active.deviceID && $0.bindingID == active.bindingID }) {
            queue.append(PendingPushDeregistration(
                deviceID: active.deviceID,
                bindingID: active.bindingID,
                endpoint: active.endpoint,
                apiKey: active.apiKey,
                queuedAt: now()
            ))
            savePendingDeregistrations(queue)
        }
    }

    private func saveActiveRegistration(_ record: ActivePushRegistration?) throws {
        guard let record else {
            try store.writeData(nil, account: PushNotificationConstants.activeRegistrationAccount)
            return
        }
        let encoded = try JSONEncoder().encode(record)
        try store.writeData(encoded, account: PushNotificationConstants.activeRegistrationAccount)
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
