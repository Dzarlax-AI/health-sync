import CryptoKit
import Foundation
import Security
import UIKit
import UserNotifications

enum PushNotificationConstants {
    static let checkinCategoryID = "CHECKIN_MORNING"
    static let checkinOpenActionID = "checkin.open"
    static let promptOpenCategoryID = "PROMPT_OPEN"
    static let promptOpenActionID = "prompt.open"
    static let inboxContractVersion = 2
    static let enabledDefaultsKey = "morningPushEnabled"

    static let deviceIDAccount = "health-sync.push.device-id"
    static let activeRegistrationAccount = "health-sync.push.active-registration"
    static let pendingDeregistrationsAccount = "health-sync.push.pending-deregistrations"
    static let registrationAttemptsAccount = "health-sync.push.registration-attempts"
    static let registrationAttemptLifetime: TimeInterval = 7 * 24 * 60 * 60

    static let heartbeatRefreshInterval: TimeInterval = 24 * 60 * 60
    static let unsupportedRetryInterval: TimeInterval = 15 * 60
}

@MainActor
enum AppBadgeSync {
    private static var pendingCount: Int?
    private static var isApplying = false

    static func iconCount(unreadCount: Int, pushesEnabled: Bool) -> Int {
        pushesEnabled ? max(0, unreadCount) : 0
    }

    static func update(unreadCount: Int) {
        guard !SyncRuntime.isTestMode else { return }
        pendingCount = unreadCount
        guard !isApplying else { return }
        isApplying = true
        Task {
            while let count = pendingCount {
                pendingCount = nil
                let enabled = UserDefaults.standard.bool(forKey: PushNotificationConstants.enabledDefaultsKey)
                try? await UNUserNotificationCenter.current().setBadgeCount(iconCount(unreadCount: count, pushesEnabled: enabled))
            }
            isApplying = false
        }
    }
}

enum PushServerStatus: Equatable {
    case unknown
    case direct
    case relay
    case notConfiguredOnServer
    case untrustedRelayURL
    case appAttestUnsupported
}

struct PushDeviceRegisterRequest: Codable, Equatable {
    let deviceID: String
    var transport: String? = nil
    var bindingID: String? = nil
    let apnsToken: String?
    var relayGrantID: String? = nil
    var relayGrantSecret: String? = nil
    let apnsEnv: String
    let bundleID: String
    let locale: String
    var inboxContractVersion: Int? = PushNotificationConstants.inboxContractVersion
    var registrationAttemptID: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case transport
        case bindingID = "binding_id"
        case apnsToken = "apns_token"
        case relayGrantID = "relay_grant_id"
        case relayGrantSecret = "relay_grant_secret"
        case apnsEnv = "apns_env"
        case bundleID = "bundle_id"
        case locale
        case inboxContractVersion = "inbox_contract_version"
        case registrationAttemptID = "registration_attempt_id"
    }

    init(
        deviceID: String,
        apnsToken: String?,
        apnsEnv: String,
        bundleID: String,
        locale: String,
        inboxContractVersion: Int? = PushNotificationConstants.inboxContractVersion,
        registrationAttemptID: UUID? = nil,
        transport: String? = nil,
        bindingID: String? = nil,
        relayGrantID: String? = nil,
        relayGrantSecret: String? = nil
    ) {
        self.deviceID = deviceID
        self.transport = transport
        self.bindingID = bindingID
        self.apnsToken = apnsToken
        self.relayGrantID = relayGrantID
        self.relayGrantSecret = relayGrantSecret
        self.apnsEnv = apnsEnv
        self.bundleID = bundleID
        self.locale = locale
        self.inboxContractVersion = inboxContractVersion
        self.registrationAttemptID = registrationAttemptID
    }
}

struct PushDeviceRegisterResponse: Decodable, Equatable {
    let deviceID: String
    let bindingID: String
    let enabled: Bool
    let registrationVersion: Int64
    let apnsEnv: String
    var inboxContractVersion: Int? = nil

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case bindingID = "binding_id"
        case enabled
        case registrationVersion = "registration_version"
        case apnsEnv = "apns_env"
        case inboxContractVersion = "inbox_contract_version"
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
    var inboxContractVersion: Int? = nil
    var registrationAttemptID: UUID? = nil
    var transportMode: String? = nil
    var relayGrantID: String? = nil
    var relayClientGrantKey: UUID? = nil
    var relayOrigin: String? = nil
    var relayLastRefreshedAt: Date? = nil
    var relayAttestKeyID: String? = nil
}

private struct PendingPushRegistrationAttempt: Codable {
    let id: UUID
    let deviceID: String
    let endpoint: URL
    let apiKey: String
    let fingerprint: String
    let requestHash: String
    let createdAt: Date
    var cancellationRequested: Bool

    static func makeID(at date: Date) -> UUID {
        let timestamp = UInt64(date.timeIntervalSince1970 * 1_000)
        let (_, _, _, _, _, _, seventh, eighth, ninth, tenth, eleventh, twelfth, thirteenth, fourteenth, fifteenth, sixteenth) = UUID().uuid
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: timestamp >> 40),
            UInt8(truncatingIfNeeded: timestamp >> 32),
            UInt8(truncatingIfNeeded: timestamp >> 24),
            UInt8(truncatingIfNeeded: timestamp >> 16),
            UInt8(truncatingIfNeeded: timestamp >> 8),
            UInt8(truncatingIfNeeded: timestamp),
            (seventh & 0x0f) | 0x70, eighth, (ninth & 0x3f) | 0x80,
            tenth, eleventh, twelfth, thirteenth, fourteenth, fifteenth, sixteenth
        ))
    }
}

struct PendingPushDeregistration: Codable, Equatable {
    let deviceID: String
    let bindingID: String
    let endpoint: URL
    let apiKey: String
    let queuedAt: Date
    var waitsForReplacement: Bool? = nil
    var registrationAttemptID: UUID? = nil

    var fingerprint: String {
        UserDefaultsSyncConfiguration.fingerprint(endpoint: endpoint, apiKey: apiKey)
    }

    func matchesBinding(_ other: Self) -> Bool {
        deviceID == other.deviceID && bindingID == other.bindingID && fingerprint == other.fingerprint
    }

    func matchesTarget(_ other: Self) -> Bool {
        matchesBinding(other) && registrationAttemptID == other.registrationAttemptID
    }
}

enum PushDestination: Equatable, Identifiable {
    case morningReport(itemID: String)
    case checkinPrompt(promptID: String)
    case inboxItem(kind: String, itemID: String)

    var id: String {
        switch self {
        case .morningReport(let id): return "mr-\(id)"
        case .checkinPrompt(let id): return "ci-\(id)"
        case .inboxItem(let kind, let id): return "\(kind)-\(id)"
        }
    }

    var itemID: String {
        switch self {
        case .morningReport(let id): return id
        case .checkinPrompt(let id): return id
        case .inboxItem(_, let id): return id
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
        case "evening_report", "sleep_update", "guidance_change", "weekly_digest", "nudge":
            guard let itemID = (userInfo["inbox_item_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !itemID.isEmpty
            else { return nil }
            return .inboxItem(kind: kind, itemID: itemID)
        case "prompt_wake_feedback", "prompt_context":
            let rawID = (userInfo["inbox_item_id"] as? String) ?? (userInfo["prompt_id"] as? String)
            guard let itemID = rawID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !itemID.isEmpty
            else { return nil }
            return .inboxItem(kind: kind, itemID: itemID)
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
struct PushSystemKeychainAccess: KeychainAccess {
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
    typealias CancelAttemptCall = @MainActor (String, UUID, URL, String) async throws -> Void
    typealias FetchPreferencesCall = @MainActor (URL, String) async throws -> NotificationPreferencesResponse
    typealias ConfigSnapshot = @MainActor () throws -> SyncConfiguration

    static let shared = PushRegistrationManager()

    private(set) var lastRegistrationError: String?
    private(set) var unsupportedRetryAfter: Date?
    private(set) var pushServerStatus: PushServerStatus = .unknown

    private let store: PushKeychainStorage
    private let relayCoordinator: RelayGrantCoordinator
    private let registerCall: RegisterCall
    private let deleteCall: DeleteCall
    private let cancelAttemptCall: CancelAttemptCall
    private let fetchPreferencesCall: FetchPreferencesCall?
    private let configSnapshot: ConfigSnapshot
    private let isPushEnabled: @MainActor () -> Bool
    private let resolveAPNsEnv: () -> String
    private let bundleIDProvider: () -> String
    private let localeProvider: () -> String
    private let now: () -> Date
    private let onRegistrationWait: (() -> Void)?
    private let resetBadge: @MainActor () -> Void
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
    private var unsavedDeregistrations: [PendingPushDeregistration] = []

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
        cancelAttemptCall: @escaping CancelAttemptCall = { deviceID, attemptID, endpoint, apiKey in
            try await ServerClient.shared.cancelPushRegistrationAttempt(
                deviceID: deviceID,
                attemptID: attemptID,
                endpoint: endpoint,
                apiKey: apiKey
            )
        },
        fetchPreferencesCall: FetchPreferencesCall? = nil,
        relayCoordinator: RelayGrantCoordinator? = nil,
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
        now: @escaping () -> Date = { Date() },
        onRegistrationWait: (() -> Void)? = nil,
        resetBadge: @escaping @MainActor () -> Void = { AppBadgeSync.update(unreadCount: 0) }
    ) {
        let resolvedKeychain = keychain ?? PushSystemKeychainAccess()
        self.store = PushKeychainStorage(access: resolvedKeychain)
        self.relayCoordinator = relayCoordinator ?? RelayGrantCoordinator(keychain: resolvedKeychain, now: now)
        self.registerCall = registerCall
        self.deleteCall = deleteCall
        self.cancelAttemptCall = cancelAttemptCall
        self.fetchPreferencesCall = fetchPreferencesCall
        self.configSnapshot = configSnapshot
        self.isPushEnabled = isPushEnabled
        self.resolveAPNsEnv = resolveAPNsEnv
        self.bundleIDProvider = bundleIDProvider
        self.localeProvider = localeProvider
        self.now = now
        self.onRegistrationWait = onRegistrationWait
        self.resetBadge = resetBadge
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
        let promptOpenAction = UNNotificationAction(
            identifier: PushNotificationConstants.promptOpenActionID,
            title: String(localized: "Answer"),
            options: [.foreground]
        )
        let promptOpenCategory = UNNotificationCategory(
            identifier: PushNotificationConstants.promptOpenCategoryID,
            actions: [promptOpenAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([checkinCategory, promptOpenCategory])
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
        (try? readPendingDeregistrations()) ?? []
    }

    private func readPendingDeregistrations() throws -> [PendingPushDeregistration] {
        guard let data = try store.readData(account: PushNotificationConstants.pendingDeregistrationsAccount) else {
            return []
        }
        return try JSONDecoder().decode([PendingPushDeregistration].self, from: data)
    }

    /// Returns the active binding ID ONLY when it matches the currently configured
    /// profile fingerprint. Used to reject notifications from previous profiles.
    func activeBindingIDForCurrentProfile() -> String? {
        guard isPushEnabled(),
              let config = try? configSnapshot(),
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
        Task { await requestRegistration() }
    }

    func syncRegistration(tokenHex: String, drainDeregistrations: Bool = true) async {
        lastKnownTokenHex = tokenHex
        await requestRegistration(drainDeregistrations: drainDeregistrations)
    }

    private func requestRegistration(drainDeregistrations: Bool = true) async {
        let initialEpoch = registrationEpoch
        reconcileActiveRegistration()
        if drainDeregistrations {
            await drainPendingDeregistrations()
        }

        guard initialEpoch == registrationEpoch, isPushEnabled(),
              let config = try? configSnapshot() else { return }
        if let active = loadActiveRegistration(), active.endpointFingerprint != config.fingerprint {
            return
        }
        let fingerprint = config.fingerprint

        // Serialize POSTs per profile: if a registration loop is already running
        // for this profile, mark a coalesced follow-up pass (which will read the
        // latest `lastKnownTokenHex`) and await its completion instead of running
        // two concurrent POSTs that could overwrite a newer APNs token on server.
        if let existingTask = inFlightRegistrationTasks[fingerprint] {
            pendingRegistrationFingerprints.insert(fingerprint)
            onRegistrationWait?()
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
            let bundleID = bundleIDProvider()
            let tokenHash = Self.sha256Hex(latestTokenHex)
            let capturedEpoch = expectedEpoch
            let capturedConfig = refreshedConfig
            let contractVersion = PushNotificationConstants.inboxContractVersion

            // Determine server push transport mode with full backward compatibility:
            // - 404 on /api/notifications/preferences (Stage 2 server) -> Direct fallback
            // - 200 with nil/missing apns_transport_mode (Stage 3 server) -> Direct fallback
            // - 200 with "direct" -> Direct
            // - 200 with "relay" -> Validate pinned origin -> App Attest + Relay grant
            // - 200 with "none" -> Explicit notConfiguredOnServer without POST
            enum ResolvedTransport {
                case direct
                case relay(URL)
                case stop(PushServerStatus, String?)
            }
            let resolvedTransport: ResolvedTransport
            do {
                let prefs: NotificationPreferencesResponse?
                if let customFetch = fetchPreferencesCall {
                    prefs = try await customFetch(capturedConfig.endpoint, capturedConfig.apiKey)
                } else if SyncRuntime.isTestMode {
                    prefs = nil
                } else {
                    prefs = try await ServerClient.shared.notificationPreferences(
                        endpoint: capturedConfig.endpoint,
                        apiKey: capturedConfig.apiKey
                    )
                }
                if let prefs, let rawMode = prefs.apnsTransportMode?.trimmingCharacters(in: .whitespacesAndNewlines), !rawMode.isEmpty {
                    switch rawMode {
                    case "direct":
                        resolvedTransport = .direct
                    case "none":
                        resolvedTransport = .stop(.notConfiguredOnServer, nil)
                    case "relay":
                        if let trustedURL = relayCoordinator.validateOrigin(prefs.apnsRelayURL) {
                            resolvedTransport = .relay(trustedURL)
                        } else {
                            resolvedTransport = .stop(.untrustedRelayURL, RelayPushError.untrustedRelayOrigin.localizedDescription)
                        }
                    default:
                        resolvedTransport = .stop(.notConfiguredOnServer, nil)
                    }
                } else {
                    // Stage 3 server (200 without apns_transport_mode) or test mode without custom fetch.
                    resolvedTransport = .direct
                }
            } catch let serverError as ServerError {
                if case .http(404, _) = serverError {
                    // Stage 2 server without /api/notifications/preferences -> preserve Direct fallback.
                    resolvedTransport = .direct
                } else {
                    lastRegistrationError = serverError.localizedDescription
                    continue
                }
            } catch {
                lastRegistrationError = error.localizedDescription
                continue
            }

            if capturedEpoch != registrationEpoch || !isPushEnabled() || (try? configSnapshot())?.fingerprint != fingerprint {
                continue
            }

            switch resolvedTransport {
            case .stop(let status, let errMessage):
                pushServerStatus = status
                lastRegistrationError = errMessage
                let retryAt = now().addingTimeInterval(PushNotificationConstants.unsupportedRetryInterval)
                unsupportedRetryState = (fingerprint, retryAt)
                unsupportedRetryAfter = retryAt
                continue
            case .direct:
                pushServerStatus = .direct
            case .relay:
                pushServerStatus = .relay
            }

            // Fast-path for existing active Relay registration: rotate APNs token
            // directly in Relay or refresh 90-day TTL without minting a new grant.
            // Re-verify epoch, push toggle, profile fingerprint, and live active
            // registration AFTER every `await` so a late Relay response can never
            // resurrect a disabled or switched-away registration. When Relay reports
            // that this grant is terminal (404/409/410 or absent from active_grant_ids),
            // clear the dead active registration and fall through to mint a fresh grant.
            if case .relay(let relayURL) = resolvedTransport,
               let active = loadActiveRegistration(),
               active.endpointFingerprint == fingerprint,
               active.transportMode == "relay",
               let activeGrantID = active.relayGrantID,
               active.relayOrigin == relayURL.absoluteString,
               active.apnsEnv == env,
               active.locale == locale,
               active.inboxContractVersion == contractVersion,
               (try? relayCoordinator.hasPendingGrantRevocation(grantID: activeGrantID, relayOrigin: relayURL.absoluteString)) == false {
                var mustReissueRelayGrant = false
                if active.tokenHash != tokenHash {
                    do {
                        let resp = try await relayCoordinator.updateDeviceToken(
                            relayURL: relayURL,
                            apnsToken: latestTokenHex,
                            apnsEnv: env
                        )
                        guard isRelayActiveRegistrationStillCurrent(
                            capturedEpoch: capturedEpoch,
                            fingerprint: fingerprint,
                            expectedBindingID: active.bindingID,
                            expectedGrantID: activeGrantID
                        ) else {
                            continue
                        }
                        if resp.confirmsGrantActive(activeGrantID) {
                            let refreshed = ActivePushRegistration(
                                deviceID: active.deviceID,
                                bindingID: active.bindingID,
                                endpoint: active.endpoint,
                                apiKey: active.apiKey,
                                endpointFingerprint: active.endpointFingerprint,
                                tokenHash: tokenHash,
                                apnsEnv: active.apnsEnv,
                                locale: active.locale,
                                confirmedAt: now(),
                                inboxContractVersion: active.inboxContractVersion,
                                registrationAttemptID: active.registrationAttemptID,
                                transportMode: active.transportMode,
                                relayGrantID: active.relayGrantID,
                                relayClientGrantKey: active.relayClientGrantKey,
                                relayOrigin: active.relayOrigin,
                                relayLastRefreshedAt: active.relayLastRefreshedAt,
                                relayAttestKeyID: active.relayAttestKeyID
                            )
                            try saveActiveRegistration(refreshed)
                            lastRegistrationError = nil
                            continue
                        }
                        mustReissueRelayGrant = true
                    } catch let relayErr as RelayPushError where relayErr.isTerminalGrantError {
                        guard isRelayActiveRegistrationStillCurrent(
                            capturedEpoch: capturedEpoch,
                            fingerprint: fingerprint,
                            expectedBindingID: active.bindingID,
                            expectedGrantID: activeGrantID
                        ) else {
                            continue
                        }
                        mustReissueRelayGrant = true
                    } catch {
                        lastRegistrationError = error.localizedDescription
                        continue
                    }
                } else {
                    let lastRefresh = active.relayLastRefreshedAt ?? active.confirmedAt
                    if relayCoordinator.requiresGrantValidation(activeGrantID) ||
                        currentNow.timeIntervalSince(lastRefresh) >= RelayPushConstants.refreshInterval {
                        do {
                            try await relayCoordinator.refreshGrant(
                                relayURL: relayURL,
                                grantID: activeGrantID,
                                apnsToken: latestTokenHex,
                                inboxContractVersion: contractVersion
                            )
                            guard isRelayActiveRegistrationStillCurrent(
                                capturedEpoch: capturedEpoch,
                                fingerprint: fingerprint,
                                expectedBindingID: active.bindingID,
                                expectedGrantID: activeGrantID
                            ) else {
                                continue
                            }
                            let refreshed = ActivePushRegistration(
                                deviceID: active.deviceID,
                                bindingID: active.bindingID,
                                endpoint: active.endpoint,
                                apiKey: active.apiKey,
                                endpointFingerprint: active.endpointFingerprint,
                                tokenHash: active.tokenHash,
                                apnsEnv: active.apnsEnv,
                                locale: active.locale,
                                confirmedAt: now(),
                                inboxContractVersion: active.inboxContractVersion,
                                registrationAttemptID: active.registrationAttemptID,
                                transportMode: active.transportMode,
                                relayGrantID: active.relayGrantID,
                                relayClientGrantKey: active.relayClientGrantKey,
                                relayOrigin: active.relayOrigin,
                                relayLastRefreshedAt: now(),
                                relayAttestKeyID: active.relayAttestKeyID
                            )
                            try saveActiveRegistration(refreshed)
                            lastRegistrationError = nil
                            continue
                        } catch let relayErr as RelayPushError where relayErr.isTerminalGrantError {
                            guard isRelayActiveRegistrationStillCurrent(
                                capturedEpoch: capturedEpoch,
                                fingerprint: fingerprint,
                                expectedBindingID: active.bindingID,
                                expectedGrantID: activeGrantID
                            ) else {
                                continue
                            }
                            mustReissueRelayGrant = true
                        } catch {
                            lastRegistrationError = error.localizedDescription
                            continue
                        }
                    } else {
                        continue
                    }
                }

                if mustReissueRelayGrant {
                    guard isRelayActiveRegistrationStillCurrent(
                        capturedEpoch: capturedEpoch,
                        fingerprint: fingerprint,
                        expectedBindingID: active.bindingID,
                        expectedGrantID: activeGrantID
                    ) else {
                        continue
                    }
                    try? saveActiveRegistration(nil)
                    if let oldClientKey = active.relayClientGrantKey {
                        relayCoordinator.clearPendingGrantAttempt(forFingerprint: fingerprint, clientGrantKey: oldClientKey)
                    }
                    // Fall through to mint a fresh Relay grant and re-register on the self-hosted server.
                }
            }

            let attempt: PendingPushRegistrationAttempt
            let request: PushDeviceRegisterRequest
            var relayAttemptMeta: (attempt: PendingRelayGrantAttempt, grantID: String, relayURL: URL)? = nil
            do {
                let deviceID = try ensureDeviceID()
                let requestHash: String
                if case .relay(let relayURL) = resolvedTransport {
                    guard relayCoordinator.isAppAttestSupported else {
                        pushServerStatus = .appAttestUnsupported
                        lastRegistrationError = RelayPushError.appAttestUnsupported.localizedDescription
                        continue
                    }
                    let obtained = try await relayCoordinator.obtainGrant(
                        relayURL: relayURL,
                        endpointFingerprint: fingerprint,
                        apnsToken: latestTokenHex,
                        apnsEnv: env,
                        inboxContractVersion: contractVersion
                    )
                    if capturedEpoch != registrationEpoch || !isPushEnabled() || (try? configSnapshot())?.fingerprint != fingerprint {
                        relayCoordinator.movePendingGrantAttemptToRevocationQueue(forFingerprint: fingerprint)
                        await relayCoordinator.drainPendingRevocations()
                        continue
                    }
                    relayAttemptMeta = (obtained.attempt, obtained.grantID, relayURL)
                    let secretHash = Self.sha256Hex(obtained.attempt.deliverySecret)
                    requestHash = Self.sha256Hex([
                        "relay", deviceID, obtained.attempt.regID.uuidString.lowercased(),
                        obtained.grantID, secretHash, env, bundleID, locale, String(contractVersion),
                    ].joined(separator: "\0"))
                } else {
                    requestHash = Self.sha256Hex([deviceID, tokenHash, env, bundleID, locale, String(contractVersion)].joined(separator: "\0"))
                }

                var attempts = try readRegistrationAttempts()
                if let previous = attempts[fingerprint] {
                    if previous.cancellationRequested || previous.requestHash != requestHash ||
                        currentNow.timeIntervalSince(previous.createdAt) >= PushNotificationConstants.registrationAttemptLifetime {
                        try requestCancellation(previous)
                        await cancelRegistrationAttempt(fingerprint: fingerprint)
                        if (try readRegistrationAttempts())[fingerprint] == nil {
                            pendingRegistrationFingerprints.insert(fingerprint)
                        }
                        continue
                    }
                    attempt = previous
                } else {
                    if case .direct = resolvedTransport,
                       let active = loadActiveRegistration(),
                       active.endpointFingerprint == fingerprint,
                       (active.transportMode ?? "direct") == "direct",
                       active.tokenHash == tokenHash,
                       active.apnsEnv == env,
                       active.locale == locale,
                       active.inboxContractVersion == contractVersion,
                       currentNow.timeIntervalSince(active.confirmedAt) < PushNotificationConstants.heartbeatRefreshInterval {
                        continue
                    }
                    attempt = PendingPushRegistrationAttempt(
                        id: PendingPushRegistrationAttempt.makeID(at: currentNow),
                        deviceID: deviceID,
                        endpoint: capturedConfig.endpoint,
                        apiKey: capturedConfig.apiKey,
                        fingerprint: fingerprint,
                        requestHash: requestHash,
                        createdAt: currentNow,
                        cancellationRequested: false
                    )
                    attempts[fingerprint] = attempt
                    try saveRegistrationAttempts(attempts)
                }

                if let relayMeta = relayAttemptMeta {
                    request = PushDeviceRegisterRequest(
                        deviceID: deviceID,
                        apnsToken: nil,
                        apnsEnv: env,
                        bundleID: bundleID,
                        locale: locale,
                        inboxContractVersion: contractVersion,
                        registrationAttemptID: attempt.id,
                        transport: "relay",
                        bindingID: relayMeta.attempt.regID.uuidString.lowercased(),
                        relayGrantID: relayMeta.grantID,
                        relayGrantSecret: relayMeta.attempt.deliverySecret
                    )
                } else {
                    request = PushDeviceRegisterRequest(
                        deviceID: deviceID, apnsToken: latestTokenHex, apnsEnv: env,
                        bundleID: bundleID, locale: locale,
                        inboxContractVersion: contractVersion,
                        registrationAttemptID: attempt.id
                    )
                }
            } catch {
                lastRegistrationError = error.localizedDescription
                continue
            }

            // Hold mutual exclusion against DELETE across the POST suspension.
            inFlightRegistrations[fingerprint, default: 0] += 1
            let registerResult: Result<PushDeviceRegisterResponse, Error>
            do {
                let response = try await registerCall(request, attempt.endpoint, attempt.apiKey)
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

                // An obsolete response can share its binding with a newer
                // registration. Cleanup must target only the attempt that produced it.
                let isCurrentResponse = pushStillEnabled && stillSameProfile && capturedEpoch == registrationEpoch
                let cleanup = PendingPushDeregistration(
                    deviceID: response.deviceID,
                    bindingID: response.bindingID,
                    endpoint: capturedConfig.endpoint,
                    apiKey: capturedConfig.apiKey,
                    queuedAt: now(),
                    waitsForReplacement: pushStillEnabled && stillSameProfile,
                    registrationAttemptID: attempt.id
                )
                if isCurrentResponse {
                    let record = ActivePushRegistration(
                        deviceID: response.deviceID,
                        bindingID: response.bindingID,
                        endpoint: capturedConfig.endpoint,
                        apiKey: capturedConfig.apiKey,
                        endpointFingerprint: fingerprint,
                        tokenHash: tokenHash,
                        apnsEnv: response.apnsEnv,
                        locale: locale,
                        confirmedAt: now(),
                        inboxContractVersion: response.inboxContractVersion ?? PushNotificationConstants.inboxContractVersion,
                        registrationAttemptID: attempt.id,
                        transportMode: relayAttemptMeta != nil ? "relay" : "direct",
                        relayGrantID: relayAttemptMeta?.grantID,
                        relayClientGrantKey: relayAttemptMeta?.attempt.clientGrantKey,
                        relayOrigin: relayAttemptMeta?.relayURL.absoluteString,
                        relayLastRefreshedAt: relayAttemptMeta != nil ? now() : nil,
                        relayAttestKeyID: relayAttemptMeta?.attempt.attestKeyID
                    )
                    do {
                        if let previous = loadActiveRegistration(),
                           previous.endpointFingerprint == fingerprint,
                           let oldGrantID = previous.relayGrantID,
                           let oldOrigin = previous.relayOrigin,
                           oldGrantID != record.relayGrantID || oldOrigin != record.relayOrigin {
                            try relayCoordinator.enqueueGrantRevocation(
                                grantID: oldGrantID,
                                relayOrigin: oldOrigin,
                                attestKeyID: previous.relayAttestKeyID
                            )
                        }
                        try saveActiveRegistration(record)
                        // Once the active record commits, cleanup of a journal
                        // entry must not revoke that registration.
                        try? forgetRegistrationAttempt(attempt)
                        if let relayMeta = relayAttemptMeta {
                            relayCoordinator.clearPendingGrantAttempt(
                                forFingerprint: fingerprint,
                                clientGrantKey: relayMeta.attempt.clientGrantKey
                            )
                        }
                        lastRegistrationError = nil
                        unsupportedRetryState = nil
                        unsupportedRetryAfter = nil
                        shouldDrainDeregistrations = !relayCoordinator.loadPendingRevocations().isEmpty ||
                            loadPendingDeregistrations().contains { $0.fingerprint == fingerprint }
                    } catch {
                        if preserveDeregistration(cleanup) {
                            try? forgetRegistrationAttempt(attempt)
                        }
                        if let relayMeta = relayAttemptMeta {
                            if (try? relayCoordinator.enqueueGrantRevocation(
                                grantID: relayMeta.grantID,
                                relayOrigin: relayMeta.relayURL.absoluteString,
                                attestKeyID: relayMeta.attempt.attestKeyID
                            )) != nil {
                                relayCoordinator.clearPendingGrantAttempt(
                                    forFingerprint: fingerprint,
                                    clientGrantKey: relayMeta.attempt.clientGrantKey
                                )
                            }
                        }
                        lastRegistrationError = error.localizedDescription
                    }
                } else {
                    if preserveDeregistration(cleanup) {
                        try? forgetRegistrationAttempt(attempt)
                    }
                    if let relayMeta = relayAttemptMeta {
                        if (try? relayCoordinator.enqueueGrantRevocation(
                            grantID: relayMeta.grantID,
                            relayOrigin: relayMeta.relayURL.absoluteString,
                            attestKeyID: relayMeta.attempt.attestKeyID
                        )) != nil {
                            relayCoordinator.clearPendingGrantAttempt(
                                forFingerprint: fingerprint,
                                clientGrantKey: relayMeta.attempt.clientGrantKey
                            )
                        }
                    }
                    shouldDrainDeregistrations = true
                }

            case .failure(let error):
                let stillSameProfile = (try? configSnapshot())?.fingerprint == fingerprint
                if let serverError = error as? ServerError, case .http(409, _) = serverError {
                    // The server has rejected this attempt as cancelled, expired, or superseded.
                    // Cancel idempotently before a later pass issues a replacement.
                    do {
                        try requestCancellation(attempt)
                        shouldDrainDeregistrations = true
                    } catch {
                        lastRegistrationError = error.localizedDescription
                    }
                }
                if !isPushEnabled() || !stillSameProfile {
                    shouldDrainDeregistrations = true
                }
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
        pushServerStatus = .unknown
        lastRegistrationError = nil
        resetBadge()
        reconcileActiveRegistration()
        await drainPendingDeregistrations()
        guard capturedEpoch == registrationEpoch else { return }
        if pushEnabled, isPushEnabled(), lastKnownTokenHex != nil {
            await requestRegistration(drainDeregistrations: false)
        }
    }

    func disablePushNotifications() async {
        registrationEpoch = UUID()
        unsupportedRetryState = nil
        unsupportedRetryAfter = nil
        pushServerStatus = .unknown
        resetBadge()
        relayCoordinator.moveAllPendingGrantAttemptsToRevocationQueue(exceptFingerprint: nil)
        await drainPendingDeregistrations()
    }

    /// Invoked on foreground activation: drains pending deregistrations and,
    /// when pushes are enabled, retries registration (respecting the bounded
    /// 404 cooldown and 24h heartbeat) so pilot activation is picked up without
    /// requiring an app restart.
    func handleAppBecameActive(requestRemoteRegistration: (@MainActor () -> Void)? = nil) async {
        let capturedEpoch = registrationEpoch
        reconcileActiveRegistration()
        await drainPendingDeregistrations()
        guard capturedEpoch == registrationEpoch, isPushEnabled() else { return }
        if lastKnownTokenHex != nil {
            await requestRegistration(drainDeregistrations: false)
        } else {
            requestRemoteRegistration?()
        }
    }

    func drainPendingDeregistrations() async {
        reconcileActiveRegistration()
        if !isPushEnabled() {
            relayCoordinator.moveAllPendingGrantAttemptsToRevocationQueue(exceptFingerprint: nil)
        } else if let currentFP = try? configSnapshot().fingerprint {
            relayCoordinator.moveAllPendingGrantAttemptsToRevocationQueue(exceptFingerprint: currentFP)
        }
        // If clearing an active record failed, retain its queued revoke after
        // delivery so the record still cannot be reused on the next launch.
        await relayCoordinator.drainPendingRevocations(retainingGrantID: loadActiveRegistration()?.relayGrantID)
        await drainRegistrationAttempts()
        for item in unsavedDeregistrations {
            do {
                try enqueueDeregistration(item)
                unsavedDeregistrations.removeAll { $0.matchesTarget(item) }
            } catch {
                lastRegistrationError = error.localizedDescription
                break
            }
        }
        let snapshot = loadPendingDeregistrations()

        for pending in snapshot {
            // A competing POST may have removed the entry or upgraded its
            // replacement hold while a previous DELETE was awaiting its response.
            guard let item = loadPendingDeregistrations().first(where: { $0.matchesTarget(pending) }) else {
                continue
            }
            let itemFingerprint = item.fingerprint
            let selector = item.registrationAttemptID.map { "attempt:\($0)" } ?? "binding:\(item.bindingID)"
            let dedupKey = "\(itemFingerprint):\(item.deviceID):\(selector)"
            guard inFlightDeregistrations[dedupKey] == nil else { continue }

            // Defer DELETE while a POST for the same profile is in flight so
            // it cannot race and disable a binding_id that POST is receiving.
            if inFlightRegistrations[itemFingerprint, default: 0] > 0 {
                deferredDeregistrationFingerprints.insert(itemFingerprint)
                continue
            }

            if isPushEnabled(), (try? configSnapshot())?.fingerprint == itemFingerprint {
                // The POST may have committed even though its response was lost.
                // Its version can reuse this binding ID, so wait for recovery
                // or precise attempt cancellation before sending a binding DELETE.
                guard let attempts = try? readRegistrationAttempts(),
                      attempts[itemFingerprint] == nil else { continue }

                let active = loadActiveRegistration()
                if active?.endpointFingerprint == itemFingerprint,
                   active?.deviceID == item.deviceID,
                   active?.bindingID == item.bindingID,
                   item.registrationAttemptID == nil || item.registrationAttemptID == active?.registrationAttemptID {
                    removePendingDeregistrations { $0.matchesTarget(item) }
                    continue
                }
                if item.waitsForReplacement == true,
                   active?.endpointFingerprint != itemFingerprint {
                    continue
                }
            }

            let deleteTask = Task { @MainActor [self] in
                defer { self.inFlightDeregistrations.removeValue(forKey: dedupKey) }
                do {
                    if let attemptID = item.registrationAttemptID {
                        try await self.cancelAttemptCall(item.deviceID, attemptID, item.endpoint, item.apiKey)
                    } else {
                        try await self.deleteCall(item.deviceID, item.bindingID, item.endpoint, item.apiKey)
                    }
                    self.removePendingDeregistrations { $0.matchesTarget(item) }
                } catch {
                    // Proxy failures and denied requests do not confirm cleanup.
                }
            }
            inFlightDeregistrations[dedupKey] = InFlightDeregistration(
                endpointFingerprint: itemFingerprint,
                task: deleteTask
            )
            await deleteTask.value
        }
    }

    private func readRegistrationAttempts() throws -> [String: PendingPushRegistrationAttempt] {
        guard let data = try store.readData(account: PushNotificationConstants.registrationAttemptsAccount) else {
            return [:]
        }
        return try JSONDecoder().decode([String: PendingPushRegistrationAttempt].self, from: data)
    }

    private func saveRegistrationAttempts(_ attempts: [String: PendingPushRegistrationAttempt]) throws {
        let data = attempts.isEmpty ? nil : try JSONEncoder().encode(attempts)
        try store.writeData(data, account: PushNotificationConstants.registrationAttemptsAccount)
    }

    private func forgetRegistrationAttempt(_ attempt: PendingPushRegistrationAttempt) throws {
        var attempts = try readRegistrationAttempts()
        guard attempts[attempt.fingerprint]?.id == attempt.id else { return }
        attempts.removeValue(forKey: attempt.fingerprint)
        try saveRegistrationAttempts(attempts)
    }

    private func requestCancellation(_ attempt: PendingPushRegistrationAttempt) throws {
        var attempts = try readRegistrationAttempts()
        guard var current = attempts[attempt.fingerprint],
              current.id == attempt.id, !current.cancellationRequested else { return }
        current.cancellationRequested = true
        attempts[attempt.fingerprint] = current
        try saveRegistrationAttempts(attempts)
    }

    private func drainRegistrationAttempts() async {
        do {
            for attempt in try readRegistrationAttempts().values {
                let fingerprint = attempt.fingerprint
                guard inFlightRegistrations[fingerprint, default: 0] == 0,
                      (try readRegistrationAttempts())[fingerprint]?.id == attempt.id else { continue }

                if !attempt.cancellationRequested && isPushEnabled() {
                    let currentFingerprint: String?
                    do {
                        currentFingerprint = try configSnapshot().fingerprint
                    } catch is APIKeyError {
                        continue
                    } catch {
                        currentFingerprint = nil
                    }
                    if currentFingerprint == fingerprint {
                        if loadActiveRegistration()?.registrationAttemptID == attempt.id {
                            try forgetRegistrationAttempt(attempt)
                        }
                        continue
                    }
                }
                try requestCancellation(attempt)
                await cancelRegistrationAttempt(fingerprint: fingerprint)
            }
        } catch {
            lastRegistrationError = error.localizedDescription
        }
    }

    private func cancelRegistrationAttempt(fingerprint: String) async {
        guard inFlightRegistrations[fingerprint, default: 0] == 0,
              let attempt = (try? readRegistrationAttempts())?[fingerprint],
              attempt.cancellationRequested else { return }

        let key = "attempt:\(attempt.id)"
        if let existing = inFlightDeregistrations[key] {
            await existing.task.value
            return
        }
        let task = Task { @MainActor [self] in
            defer { inFlightDeregistrations.removeValue(forKey: key) }
            do {
                try await cancelAttemptCall(attempt.deviceID, attempt.id, attempt.endpoint, attempt.apiKey)
                try forgetRegistrationAttempt(attempt)
            } catch {
                // Keep the saved intent until the server confirms cleanup.
            }
        }
        inFlightDeregistrations[key] = InFlightDeregistration(endpointFingerprint: fingerprint, task: task)
        await task.value
    }

    private func waitForInFlightDeregistrations(forFingerprint fingerprint: String) async {
        while let pending = inFlightDeregistrations.values.first(where: { $0.endpointFingerprint == fingerprint }) {
            onRegistrationWait?()
            await pending.task.value
        }
    }

    private func isRelayActiveRegistrationStillCurrent(
        capturedEpoch: UUID,
        fingerprint: String,
        expectedBindingID: String,
        expectedGrantID: String
    ) -> Bool {
        guard capturedEpoch == registrationEpoch,
              isPushEnabled(),
              (try? configSnapshot())?.fingerprint == fingerprint,
              let live = loadActiveRegistration(),
              live.endpointFingerprint == fingerprint,
              live.transportMode == "relay",
              live.relayGrantID == expectedGrantID,
              live.bindingID == expectedBindingID
        else {
            return false
        }
        return true
    }

    private func reconcileActiveRegistration() {
        guard let active = loadActiveRegistration() else { return }
        if let grantID = active.relayGrantID,
           let origin = active.relayOrigin,
           (try? relayCoordinator.hasPendingGrantRevocation(grantID: grantID, relayOrigin: origin)) == true {
            moveActiveRegistrationToQueue()
            return
        }
        if !isPushEnabled() {
            moveActiveRegistrationToQueue()
            return
        }
        do {
            if try configSnapshot().fingerprint != active.endpointFingerprint {
                moveActiveRegistrationToQueue()
            }
        } catch is APIKeyError {
            // The foreground/Keychain recovery path retries when the key is accessible.
        } catch {
            moveActiveRegistrationToQueue()
        }
    }

    private func moveActiveRegistrationToQueue() {
        guard let active = loadActiveRegistration() else { return }
        do {
            if active.transportMode == "relay",
               let grantID = active.relayGrantID,
               let relayOrigin = active.relayOrigin {
                try relayCoordinator.enqueueGrantRevocation(
                    grantID: grantID,
                    relayOrigin: relayOrigin,
                    attestKeyID: active.relayAttestKeyID
                )
            }
            try enqueueDeregistration(PendingPushDeregistration(
                deviceID: active.deviceID,
                bindingID: active.bindingID,
                endpoint: active.endpoint,
                apiKey: active.apiKey,
                queuedAt: now(),
                registrationAttemptID: active.registrationAttemptID
            ))
            try saveActiveRegistration(nil)
        } catch {
            lastRegistrationError = error.localizedDescription
        }
    }

    private func preserveDeregistration(_ entry: PendingPushDeregistration) -> Bool {
        do {
            try enqueueDeregistration(entry)
            return true
        } catch {
            Self.mergeDeregistration(entry, into: &unsavedDeregistrations)
            lastRegistrationError = error.localizedDescription
            return false
        }
    }

    private static func mergeDeregistration(_ entry: PendingPushDeregistration, into queue: inout [PendingPushDeregistration]) {
        if entry.waitsForReplacement == true {
            // Preserve the hold for any older binding-wide cleanup of the
            // same registration, as well as repeated cleanup of this attempt.
            for index in queue.indices where queue[index].matchesBinding(entry) {
                queue[index].waitsForReplacement = true
            }
        }
        if !queue.contains(where: { $0.matchesTarget(entry) }) {
            queue.append(entry)
        }
    }

    private func enqueueDeregistration(_ entry: PendingPushDeregistration) throws {
        var queue = try readPendingDeregistrations()
        let previous = queue
        Self.mergeDeregistration(entry, into: &queue)
        if queue != previous {
            try savePendingDeregistrations(queue)
        }
    }

    private func removePendingDeregistrations(where shouldRemove: (PendingPushDeregistration) -> Bool) {
        do {
            var live = try readPendingDeregistrations()
            let count = live.count
            live.removeAll(where: shouldRemove)
            if count != live.count {
                try savePendingDeregistrations(live)
            }
            unsavedDeregistrations.removeAll(where: shouldRemove)
        } catch {
            lastRegistrationError = error.localizedDescription
        }
    }

    private func saveActiveRegistration(_ record: ActivePushRegistration?) throws {
        guard let record else {
            try store.writeData(nil, account: PushNotificationConstants.activeRegistrationAccount)
            return
        }
        let encoded = try JSONEncoder().encode(record)
        try store.writeData(encoded, account: PushNotificationConstants.activeRegistrationAccount)
        removePendingDeregistrations {
            // A successful POST is authoritative for this binding. Same-profile
            // POSTs are serialized, and any old attempt is now superseded.
            $0.fingerprint == record.endpointFingerprint && $0.deviceID == record.deviceID &&
                $0.bindingID == record.bindingID
        }
    }

    private func savePendingDeregistrations(_ items: [PendingPushDeregistration]) throws {
        let data = items.isEmpty ? nil : try JSONEncoder().encode(items)
        try store.writeData(data, account: PushNotificationConstants.pendingDeregistrationsAccount)
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
