import Foundation
import Security
import Testing
@testable import health_sync

@MainActor
private final class InMemoryKeychainAccess: KeychainAccess {
    var items: [String: Data] = [:]

    func copy(_ query: [CFString: Any]) -> (OSStatus, Any?) {
        guard let account = query[kSecAttrAccount] as? String else { return (errSecParam, nil) }
        guard let data = items[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount] as? String else { return errSecParam }
        guard items[account] != nil else { return errSecItemNotFound }
        guard let data = attributes[kSecValueData] as? Data else { return errSecParam }
        items[account] = data
        return errSecSuccess
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        guard let account = attributes[kSecAttrAccount] as? String,
              let data = attributes[kSecValueData] as? Data
        else { return errSecParam }
        items[account] = data
        return errSecSuccess
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount] as? String else { return errSecParam }
        if items.removeValue(forKey: account) == nil { return errSecItemNotFound }
        return errSecSuccess
    }
}

@MainActor
struct PushNotificationTests {
    @Test
    func resolvesAPNsEnvironmentFromSignedProvisioningProfile() {
        let devProfile = """
        CMS-HEADER-BYTES
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>aps-environment</key>
                <string>development</string>
            </dict>
        </dict>
        </plist>
        CMS-FOOTER-BYTES
        """.data(using: .utf8)!
        #expect(APNsEnvironmentResolver.resolve(mobileProvisionData: devProfile) == "sandbox")

        let prodProfile = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>aps-environment</key>
                <string>production</string>
            </dict>
        </dict>
        </plist>
        """.data(using: .utf8)!
        #expect(APNsEnvironmentResolver.resolve(mobileProvisionData: prodProfile) == "production")
    }

    @Test
    func payloadRoutingRequiresMatchingBindingIDAndRejectsStaleProfilePush() {
        let bindingA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let bindingB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let itemID = "11111111-1111-4111-8111-111111111111"

        let reportPayload: [AnyHashable: Any] = [
            "v": 1,
            "kind": "morning_report",
            "inbox_item_id": itemID,
            "reg_id": bindingA
        ]
        #expect(PushNotificationPayload.parseDestination(userInfo: reportPayload, expectedBindingID: bindingA) == .morningReport(itemID: itemID))
        // After switching to profile B, stale notification from profile A must be discarded.
        #expect(PushNotificationPayload.parseDestination(userInfo: reportPayload, expectedBindingID: bindingB) == nil)
        #expect(PushNotificationPayload.parseDestination(userInfo: reportPayload, expectedBindingID: nil) == nil)

        let checkinPayload: [AnyHashable: Any] = [
            "v": 1,
            "kind": "prompt_checkin",
            "prompt_id": itemID,
            "reg_id": bindingA
        ]
        #expect(PushNotificationPayload.parseDestination(userInfo: checkinPayload, expectedBindingID: bindingA) == .checkinPrompt(promptID: itemID))
    }

    @Test
    func registrationCaches404AndQueuesRetryableBindingDeregistrationOnOfflineSwitch() async {
        let keychain = InMemoryKeychainAccess()
        let endpointA = URL(string: "https://server-a.example.com")!
        let endpointB = URL(string: "https://server-b.example.com")!
        var activeEndpoint = endpointA
        var activeKey = "key-a"

        var registerRequests: [PushDeviceRegisterRequest] = []
        var deleteAttempts: [(deviceID: String, bindingID: String, endpoint: URL, apiKey: String)] = []
        var failDeletes = true
        var return404OnRegister = false

        let bindingA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let bindingB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { req in
                registerRequests.append(req)
                if return404OnRegister {
                    throw ServerError.http(404, "disabled")
                }
                let binding = activeEndpoint == endpointA ? bindingA : bindingB
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: binding,
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv
                )
            },
            deleteCall: { deviceID, bindingID, endpoint, apiKey in
                deleteAttempts.append((deviceID, bindingID, endpoint, apiKey))
                if failDeletes {
                    throw ServerError.http(503, "offline")
                }
            },
            configSnapshot: {
                SyncConfiguration(
                    endpoint: activeEndpoint,
                    apiKey: activeKey,
                    fingerprint: UserDefaultsSyncConfiguration.fingerprint(endpoint: activeEndpoint, apiKey: activeKey),
                    metricGroups: [.vitals],
                    workoutsEnabled: true,
                    backgroundEnabled: true,
                    syncOnLaunch: true,
                    interval: 900,
                    workoutHRTimeline: true
                )
            },
            resolveAPNsEnv: { "sandbox" },
            bundleIDProvider: { "com.dzarlax.health-sync" },
            localeProvider: { "ru" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let tokenHex = String(repeating: "a", count: 64)
        await manager.syncRegistration(tokenHex: tokenHex)
        #expect(registerRequests.count == 1)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingA)

        // Duplicate sync within 24h with unchanged token/env/locale is a no-op.
        await manager.syncRegistration(tokenHex: tokenHex)
        #expect(registerRequests.count == 1)

        // Switch to server B while server A is unreachable (503) -> queues DELETE with exact bindingA.
        activeEndpoint = endpointB
        activeKey = "key-b"
        await manager.handleConfigurationChanged(pushEnabled: true)
        #expect(deleteAttempts.count == 1)
        #expect(deleteAttempts[0].bindingID == bindingA)
        #expect(deleteAttempts[0].endpoint == endpointA)
        #expect(deleteAttempts[0].apiKey == "key-a")
        #expect(manager.loadPendingDeregistrations().count == 1)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingB)

        // Stale push from server A is rejected after switch to server B.
        let router = PushNavigationRouter()
        let routedStale = manager.routeNotification(userInfo: [
            "v": 1,
            "kind": "prompt_checkin",
            "prompt_id": "22222222-2222-4222-8222-222222222222",
            "reg_id": bindingA
        ], router: router)
        #expect(routedStale == nil)
        #expect(router.pendingDestination == nil)

        // Push from server B routes cleanly and is consumed once.
        let routedFresh = manager.routeNotification(userInfo: [
            "v": 1,
            "kind": "morning_report",
            "inbox_item_id": "33333333-3333-4333-8333-333333333333",
            "reg_id": bindingB
        ], router: router)
        #expect(routedFresh == .morningReport(itemID: "33333333-3333-4333-8333-333333333333"))
        #expect(router.consume() == .morningReport(itemID: "33333333-3333-4333-8333-333333333333"))
        #expect(router.consume() == nil)

        // Network returns -> pending deregistration drains and clears queue.
        failDeletes = false
        await manager.drainPendingDeregistrations()
        #expect(deleteAttempts.count == 2)
        #expect(manager.loadPendingDeregistrations().isEmpty)

        // Legacy/disabled server returning 404 caches unsupportedFingerprint and stops retrying.
        activeKey = "key-legacy"
        return404OnRegister = true
        await manager.handleConfigurationChanged(pushEnabled: true)
        let countAfterFirst404 = registerRequests.count
        await manager.syncRegistration(tokenHex: tokenHex)
        #expect(registerRequests.count == countAfterFirst404)
    }
}
