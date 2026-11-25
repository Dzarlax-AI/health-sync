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
    private func makeConfig(endpoint: URL, apiKey: String) -> SyncConfiguration {
        SyncConfiguration(
            endpoint: endpoint,
            apiKey: apiKey,
            fingerprint: UserDefaultsSyncConfiguration.fingerprint(endpoint: endpoint, apiKey: apiKey),
            metricGroups: [.vitals],
            workoutsEnabled: true,
            backgroundEnabled: true,
            syncOnLaunch: true,
            interval: 900,
            workoutHRTimeline: true
        )
    }

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
    func registrationQueuesRetryableBindingDeregistrationOnOfflineSwitch() async {
        let keychain = InMemoryKeychainAccess()
        let endpointA = URL(string: "https://server-a.example.com")!
        let endpointB = URL(string: "https://server-b.example.com")!
        var activeEndpoint = endpointA
        var activeKey = "key-a"

        var registerRequests: [PushDeviceRegisterRequest] = []
        var deleteAttempts: [(deviceID: String, bindingID: String, endpoint: URL, apiKey: String)] = []
        var failDeletes = true

        let bindingA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let bindingB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { req, endpoint, _ in
                registerRequests.append(req)
                let binding = endpoint == endpointA ? bindingA : bindingB
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
            configSnapshot: { self.makeConfig(endpoint: activeEndpoint, apiKey: activeKey) },
            isPushEnabled: { true },
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
    }

    @Test
    func delayedPostDuringProfileSwitchCancelsOldBindingWithoutOverwritingNewProfile() async {
        let keychain = InMemoryKeychainAccess()
        let endpointA = URL(string: "https://server-a.example.com")!
        let endpointB = URL(string: "https://server-b.example.com")!
        var activeEndpoint = endpointA
        var activeKey = "key-a"

        let bindingA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let bindingB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        var releasePostA: CheckedContinuation<PushDeviceRegisterResponse, Error>?
        var deleted: [(bindingID: String, endpoint: URL, apiKey: String)] = []

        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { req, endpoint, _ in
                if endpoint == endpointA {
                    return try await withCheckedThrowingContinuation { cont in
                        releasePostA = cont
                    }
                }
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: bindingB,
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv
                )
            },
            deleteCall: { _, bindingID, endpoint, apiKey in
                deleted.append((bindingID, endpoint, apiKey))
            },
            configSnapshot: { self.makeConfig(endpoint: activeEndpoint, apiKey: activeKey) },
            isPushEnabled: { true },
            resolveAPNsEnv: { "sandbox" },
            bundleIDProvider: { "com.dzarlax.health-sync" },
            localeProvider: { "en" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let tokenHex = String(repeating: "c", count: 64)
        let postATask = Task { await manager.syncRegistration(tokenHex: tokenHex) }
        while releasePostA == nil { await Task.yield() }

        // User switches to server B while server A's POST is still in flight.
        activeEndpoint = endpointB
        activeKey = "key-b"
        await manager.handleConfigurationChanged(pushEnabled: true)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingB)

        // Now server A's delayed POST finishes with bindingA.
        let deviceID = try! manager.ensureDeviceID()
        releasePostA?.resume(returning: PushDeviceRegisterResponse(
            deviceID: deviceID,
            bindingID: bindingA,
            enabled: true,
            registrationVersion: 1,
            apnsEnv: "sandbox"
        ))
        await postATask.value

        // Must NOT overwrite profile B's registration AND must DELETE bindingA on server A.
        #expect(manager.activeBindingIDForCurrentProfile() == bindingB)
        #expect(deleted.count == 1)
        #expect(deleted[0].bindingID == bindingA)
        #expect(deleted[0].endpoint == endpointA)
        #expect(deleted[0].apiKey == "key-a")
        #expect(manager.loadPendingDeregistrations().isEmpty)
    }

    @Test
    func delayedPostDuringPushDisableCancelsBindingWithoutResavingRegistration() async {
        let keychain = InMemoryKeychainAccess()
        let endpointA = URL(string: "https://server-a.example.com")!
        var pushEnabled = true
        let bindingA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

        var releasePost: CheckedContinuation<PushDeviceRegisterResponse, Error>?
        var deletedBindings: [String] = []

        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { _, _, _ in
                try await withCheckedThrowingContinuation { cont in
                    releasePost = cont
                }
            },
            deleteCall: { _, bindingID, _, _ in
                deletedBindings.append(bindingID)
            },
            configSnapshot: { self.makeConfig(endpoint: endpointA, apiKey: "key-a") },
            isPushEnabled: { pushEnabled },
            resolveAPNsEnv: { "sandbox" },
            bundleIDProvider: { "com.dzarlax.health-sync" },
            localeProvider: { "en" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let tokenHex = String(repeating: "d", count: 64)
        let postTask = Task { await manager.syncRegistration(tokenHex: tokenHex) }
        while releasePost == nil { await Task.yield() }

        // User disables pushes while POST is still in flight.
        pushEnabled = false
        await manager.disablePushNotifications()
        #expect(manager.loadActiveRegistration() == nil)

        // Delayed POST finishes after push was disabled.
        let deviceID = try! manager.ensureDeviceID()
        releasePost?.resume(returning: PushDeviceRegisterResponse(
            deviceID: deviceID,
            bindingID: bindingA,
            enabled: true,
            registrationVersion: 1,
            apnsEnv: "sandbox"
        ))
        await postTask.value

        // Must NOT re-save local registration AND must DELETE bindingA on the server.
        #expect(manager.loadActiveRegistration() == nil)
        #expect(deletedBindings == [bindingA])
        #expect(manager.loadPendingDeregistrations().isEmpty)
    }

    @Test
    func concurrentEnqueueDuringDeregistrationDrainIsNotLost() async {
        let keychain = InMemoryKeychainAccess()
        let endpointA = URL(string: "https://server-a.example.com")!
        let endpointB = URL(string: "https://server-b.example.com")!
        var activeEndpoint = endpointA
        var activeKey = "key-a"

        let bindingA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let bindingB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        var releaseDeleteA: CheckedContinuation<Void, Error>?
        var deletedBindings: [String] = []
        var failDeleteB = true

        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { req, endpoint, _ in
                PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: endpoint == endpointA ? bindingA : bindingB,
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv
                )
            },
            deleteCall: { _, bindingID, _, _ in
                if bindingID == bindingA {
                    try await withCheckedThrowingContinuation { cont in
                        releaseDeleteA = cont
                    }
                } else if bindingID == bindingB && failDeleteB {
                    throw ServerError.http(503, "server B offline")
                }
                deletedBindings.append(bindingID)
            },
            configSnapshot: { self.makeConfig(endpoint: activeEndpoint, apiKey: activeKey) },
            isPushEnabled: { true },
            resolveAPNsEnv: { "sandbox" },
            bundleIDProvider: { "com.dzarlax.health-sync" },
            localeProvider: { "en" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let tokenHex = String(repeating: "e", count: 64)
        await manager.syncRegistration(tokenHex: tokenHex)

        // Start switching A -> B; DELETE for bindingA suspends in flight.
        activeEndpoint = endpointB
        activeKey = "key-b"
        let switchAToB = Task { await manager.handleConfigurationChanged(pushEnabled: true) }
        while releaseDeleteA == nil { await Task.yield() }

        // While DELETE(bindingA) is awaiting, register on B and disable pushes:
        // bindingB is appended to Keychain and fails 503 so it stays queued.
        await manager.syncRegistration(tokenHex: tokenHex, drainDeregistrations: false)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingB)
        await manager.disablePushNotifications()
        #expect(manager.loadPendingDeregistrations().map(\.bindingID).contains(bindingB))

        // Now complete DELETE(bindingA) -> must remove ONLY bindingA and preserve bindingB!
        releaseDeleteA?.resume(returning: ())
        await switchAToB.value

        #expect(deletedBindings == [bindingA])
        #expect(manager.loadPendingDeregistrations().map(\.bindingID) == [bindingB])

        // Next drain completes bindingB cleanly.
        failDeleteB = false
        await manager.drainPendingDeregistrations()
        #expect(deletedBindings == [bindingA, bindingB])
        #expect(manager.loadPendingDeregistrations().isEmpty)
    }

    @Test
    func retries404AfterCooldownAndRegistersWhenPilotFlagEnabled() async {
        let keychain = InMemoryKeychainAccess()
        let endpoint = URL(string: "https://pilot.example.com")!
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        var pilotEnabledOnServer = false
        var registerCalls = 0
        let bindingID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { req, _, _ in
                registerCalls += 1
                if !pilotEnabledOnServer {
                    throw ServerError.http(404, "disabled")
                }
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: bindingID,
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv
                )
            },
            deleteCall: { _, _, _, _ in },
            configSnapshot: { self.makeConfig(endpoint: endpoint, apiKey: "key-pilot") },
            isPushEnabled: { true },
            resolveAPNsEnv: { "sandbox" },
            bundleIDProvider: { "com.dzarlax.health-sync" },
            localeProvider: { "ru" },
            now: { currentTime }
        )

        let tokenHex = String(repeating: "f", count: 64)

        // 1. Server returns 404 before pilot flag is enabled.
        await manager.syncRegistration(tokenHex: tokenHex)
        #expect(registerCalls == 1)
        #expect(manager.activeBindingIDForCurrentProfile() == nil)

        // 2. Within cooldown (5 min later), foreground return does NOT spam POST.
        currentTime = currentTime.addingTimeInterval(5 * 60)
        await manager.handleAppBecameActive()
        #expect(registerCalls == 1)

        // 3. Server enables pilot flag; after cooldown expires (16 min total),
        // foreground activation retries and completes registration without restart.
        pilotEnabledOnServer = true
        currentTime = currentTime.addingTimeInterval(11 * 60)
        await manager.handleAppBecameActive()
        #expect(registerCalls == 2)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingID)
    }
}
