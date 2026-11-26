import Foundation
import Security
import Testing
@testable import health_sync

@MainActor
private final class InMemoryKeychainAccess: KeychainAccess {
    var items: [String: Data] = [:]
    var failedWrites: Set<String> = []

    func copy(_ query: [CFString: Any]) -> (OSStatus, Any?) {
        guard let account = query[kSecAttrAccount] as? String else { return (errSecParam, nil) }
        guard let data = items[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount] as? String else { return errSecParam }
        guard !failedWrites.contains(account) else { return errSecInteractionNotAllowed }
        guard items[account] != nil else { return errSecItemNotFound }
        guard let data = attributes[kSecValueData] as? Data else { return errSecParam }
        items[account] = data
        return errSecSuccess
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        guard let account = attributes[kSecAttrAccount] as? String,
              let data = attributes[kSecValueData] as? Data
        else { return errSecParam }
        guard !failedWrites.contains(account) else { return errSecInteractionNotAllowed }
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
    private func waitForSignal(_ arrived: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !arrived(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return arrived()
    }

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
        #expect(deleteAttempts.first?.bindingID == bindingA)
        #expect(deleteAttempts.first?.endpoint == endpointA)
        #expect(deleteAttempts.first?.apiKey == "key-a")
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
        guard await waitForSignal({ releasePostA != nil }) else {
            Issue.record("Timed out waiting for the held request")
            return
        }

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
        #expect(deleted.first?.bindingID == bindingA)
        #expect(deleted.first?.endpoint == endpointA)
        #expect(deleted.first?.apiKey == "key-a")
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
        guard await waitForSignal({ releasePost != nil }) else {
            Issue.record("Timed out waiting for the held request")
            return
        }

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
        var pushEnabled = true

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
            isPushEnabled: { pushEnabled },
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
        guard await waitForSignal({ releaseDeleteA != nil }) else {
            Issue.record("Timed out waiting for the held request")
            return
        }

        // While DELETE(bindingA) is awaiting, register on B and disable pushes:
        // bindingB is appended to Keychain and fails 503 so it stays queued.
        await manager.syncRegistration(tokenHex: tokenHex, drainDeregistrations: false)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingB)
        pushEnabled = false
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

    @Test(arguments: [true, false])
    func rapidProfileSwitchABAReusingBindingDoesNotDeleteActiveRegistration(followupSucceeds: Bool) async {
        let keychain = InMemoryKeychainAccess()
        let endpointA = URL(string: "https://server-a.example.com")!
        let endpointB = URL(string: "https://server-b.example.com")!
        var activeEndpoint = endpointA
        var activeKey = "key-a"
        var enabled = true

        // Matches server UpsertPushDevice behavior: active device on server A
        // keeps the same binding_id across both POST requests.
        let bindingA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let bindingB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        var postACount = 0
        var releaseFirstPostA: CheckedContinuation<PushDeviceRegisterResponse, Error>?
        var deleted: [(bindingID: String, endpoint: URL, apiKey: String)] = []

        var registrationWaits = 0
        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { req, endpoint, _ in
                if endpoint == endpointA {
                    postACount += 1
                    if postACount == 1 {
                        return try await withCheckedThrowingContinuation { cont in
                            releaseFirstPostA = cont
                        }
                    }
                    guard followupSucceeds else { throw URLError(.notConnectedToInternet) }
                    return PushDeviceRegisterResponse(
                        deviceID: req.deviceID,
                        bindingID: bindingA,
                        enabled: true,
                        registrationVersion: 1,
                        apnsEnv: req.apnsEnv
                    )
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
            isPushEnabled: { enabled },
            resolveAPNsEnv: { "sandbox" },
            bundleIDProvider: { "com.dzarlax.health-sync" },
            localeProvider: { "en" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            onRegistrationWait: { registrationWaits += 1 }
        )

        let tokenHex = String(repeating: "a", count: 64)

        // 1. Start POST #1 on profile A and hold it in flight.
        let firstPostATask = Task { await manager.syncRegistration(tokenHex: tokenHex) }
        guard await waitForSignal({ releaseFirstPostA != nil }) else {
            Issue.record("Timed out waiting for the held request")
            return
        }

        // 2. Switch A -> B: registers bindingB on server B.
        activeEndpoint = endpointB
        activeKey = "key-b"
        await manager.handleConfigurationChanged(pushEnabled: true)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingB)

        // 3. Switch B -> A while POST #1 for server A is still in flight:
        // DELETE(bindingB) runs immediately, while POST #2 for server A waits
        // for POST #1 to finish (strict per-profile POST serialization).
        activeEndpoint = endpointA
        activeKey = "key-a"
        let switchBackTask = Task { await manager.handleConfigurationChanged(pushEnabled: true) }
        #expect(await waitForSignal { registrationWaits == 1 })
        #expect(postACount == 1)
        #expect(deleted.count == 1)
        #expect(deleted.first?.bindingID == bindingB)

        // 4. Delayed POST #1 from the earlier epoch finally returns the same bindingA.
        // It must NOT delete bindingA, and the serialized follow-up POST #2 must
        // confirm and save bindingA under the current epoch.
        let deviceID = try! manager.ensureDeviceID()
        releaseFirstPostA?.resume(returning: PushDeviceRegisterResponse(
            deviceID: deviceID,
            bindingID: bindingA,
            enabled: true,
            registrationVersion: 1,
            apnsEnv: "sandbox"
        ))
        await firstPostATask.value
        await switchBackTask.value

        #expect(postACount == 2)
        if followupSucceeds {
            #expect(manager.activeBindingIDForCurrentProfile() == bindingA)
            #expect(deleted.map(\.bindingID) == [bindingB])
        } else {
            #expect(manager.activeBindingIDForCurrentProfile() == nil)
            #expect(manager.loadPendingDeregistrations().map(\.bindingID) == [bindingA])
            enabled = false
            await manager.disablePushNotifications()
            #expect(deleted.map(\.bindingID) == [bindingB, bindingA])
        }
        #expect(manager.loadPendingDeregistrations().isEmpty)
    }

    @Test
    func rapidProfileSwitchABAWithInFlightDeleteSerializesBeforeReregistration() async {
        let keychain = InMemoryKeychainAccess()
        let endpointA = URL(string: "https://server-a.example.com")!
        let endpointB = URL(string: "https://server-b.example.com")!
        var activeEndpoint = endpointA
        var activeKey = "key-a"

        let bindingA1 = "11111111-1111-4111-8111-111111111111"
        let bindingA2 = "22222222-2222-4222-8222-222222222222"
        let bindingB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        var serverADisabled = false
        var releaseDeleteA: CheckedContinuation<Void, Error>?
        var events: [String] = []

        var registrationWaits = 0
        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { req, endpoint, _ in
                if endpoint == endpointA {
                    let binding = serverADisabled ? bindingA2 : bindingA1
                    events.append("post-a:\(binding)")
                    return PushDeviceRegisterResponse(
                        deviceID: req.deviceID,
                        bindingID: binding,
                        enabled: true,
                        registrationVersion: serverADisabled ? 2 : 1,
                        apnsEnv: req.apnsEnv
                    )
                }
                events.append("post-b:\(bindingB)")
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: bindingB,
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv
                )
            },
            deleteCall: { _, bindingID, endpoint, _ in
                if endpoint == endpointA {
                    try await withCheckedThrowingContinuation { cont in
                        releaseDeleteA = cont
                    }
                    serverADisabled = true
                    events.append("delete-a:\(bindingID)")
                } else {
                    events.append("delete-b:\(bindingID)")
                }
            },
            configSnapshot: { self.makeConfig(endpoint: activeEndpoint, apiKey: activeKey) },
            isPushEnabled: { true },
            resolveAPNsEnv: { "sandbox" },
            bundleIDProvider: { "com.dzarlax.health-sync" },
            localeProvider: { "en" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            onRegistrationWait: { registrationWaits += 1 }
        )

        let tokenHex = String(repeating: "b", count: 64)

        // 1. Register bindingA1 on profile A.
        await manager.syncRegistration(tokenHex: tokenHex)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingA1)

        // 2. Switch A -> B: DELETE(bindingA1) starts and suspends in flight.
        activeEndpoint = endpointB
        activeKey = "key-b"
        let switchAToB = Task { await manager.handleConfigurationChanged(pushEnabled: true) }
        guard await waitForSignal({ releaseDeleteA != nil }) else {
            Issue.record("Timed out waiting for the held request")
            return
        }

        // 3. Switch back B -> A while DELETE(bindingA1) is still in flight.
        activeEndpoint = endpointA
        activeKey = "key-a"
        let switchBToA = Task { await manager.handleConfigurationChanged(pushEnabled: true) }
        #expect(await waitForSignal { registrationWaits == 1 })

        // POST #2 for server A must wait for the in-flight DELETE(bindingA1) to finish.
        #expect(events == ["post-a:\(bindingA1)"])

        // 4. Complete DELETE(bindingA1): server disables bindingA1, then POST #2
        // runs and receives a fresh bindingA2.
        releaseDeleteA?.resume(returning: ())
        await switchAToB.value
        await switchBToA.value

        #expect(events == [
            "post-a:\(bindingA1)",
            "delete-a:\(bindingA1)",
            "post-a:\(bindingA2)"
        ])
        #expect(manager.activeBindingIDForCurrentProfile() == bindingA2)
        #expect(manager.loadPendingDeregistrations().isEmpty)
    }

    @Test
    func pendingDeleteDoesNotRunDuringInFlightPostForSameProfileAndIsPurgedWhenBindingReused() async {
        let keychain = InMemoryKeychainAccess()
        let endpointA = URL(string: "https://server-a.example.com")!
        let endpointB = URL(string: "https://server-b.example.com")!
        var activeEndpoint = endpointA
        var activeKey = "key-a"

        let bindingA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let bindingB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        var serverAOnline = true
        var serverADisabled = false
        var holdNextPostA = false
        var releasePostA: CheckedContinuation<PushDeviceRegisterResponse, Error>?
        var deleteCallsAfterPostStarted = 0

        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { req, endpoint, _ in
                if endpoint == endpointA {
                    if holdNextPostA {
                        holdNextPostA = false
                        return try await withCheckedThrowingContinuation { cont in
                            releasePostA = cont
                        }
                    }
                    return PushDeviceRegisterResponse(
                        deviceID: req.deviceID,
                        bindingID: bindingA,
                        enabled: true,
                        registrationVersion: 1,
                        apnsEnv: req.apnsEnv
                    )
                }
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: bindingB,
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv
                )
            },
            deleteCall: { _, bindingID, endpoint, _ in
                if endpoint == endpointA {
                    if !serverAOnline {
                        throw ServerError.http(503, "server A offline")
                    }
                    if releasePostA != nil {
                        deleteCallsAfterPostStarted += 1
                    }
                    if bindingID == bindingA {
                        serverADisabled = true
                    }
                }
            },
            configSnapshot: { self.makeConfig(endpoint: activeEndpoint, apiKey: activeKey) },
            isPushEnabled: { true },
            resolveAPNsEnv: { "sandbox" },
            bundleIDProvider: { "com.dzarlax.health-sync" },
            localeProvider: { "en" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let tokenHex = String(repeating: "7", count: 64)

        // 1. Register bindingA on server A.
        await manager.syncRegistration(tokenHex: tokenHex)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingA)

        // 2. Switch A -> B while server A is offline -> DELETE(bindingA) stays queued.
        serverAOnline = false
        activeEndpoint = endpointB
        activeKey = "key-b"
        await manager.handleConfigurationChanged(pushEnabled: true)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingB)
        #expect(manager.loadPendingDeregistrations().map(\.bindingID) == [bindingA])

        // 3. Switch B -> A: initial drain still hits 503 for server A, then
        // POST(A) starts and suspends waiting for server A's response.
        holdNextPostA = true
        activeEndpoint = endpointA
        activeKey = "key-a"
        let switchBackTask = Task { await manager.handleConfigurationChanged(pushEnabled: true) }
        guard await waitForSignal({ releasePostA != nil }) else {
            Issue.record("Timed out waiting for the held request")
            return
        }

        // 4. Server A is now reachable; foreground return triggers drain while
        // POST(A) is still awaiting its response (local active registration is still nil).
        serverAOnline = true
        await manager.drainPendingDeregistrations()
        #expect(deleteCallsAfterPostStarted == 0)
        #expect(!serverADisabled)

        // 5. Server A's POST response arrives reusing bindingA.
        let deviceID = try! manager.ensureDeviceID()
        releasePostA?.resume(returning: PushDeviceRegisterResponse(
            deviceID: deviceID,
            bindingID: bindingA,
            enabled: true,
            registrationVersion: 1,
            apnsEnv: "sandbox"
        ))
        await switchBackTask.value

        // Active registration is saved, server A was NEVER disabled, and queue is empty.
        #expect(manager.activeBindingIDForCurrentProfile() == bindingA)
        #expect(deleteCallsAfterPostStarted == 0)
        #expect(!serverADisabled)
        #expect(manager.loadPendingDeregistrations().isEmpty)
    }

    @Test
    func deferredDeleteRunsAfterInFlightPostReturnsNewBinding() async {
        let keychain = InMemoryKeychainAccess()
        let endpointA = URL(string: "https://server-a.example.com")!
        let endpointB = URL(string: "https://server-b.example.com")!
        var activeEndpoint = endpointA
        var activeKey = "key-a"

        let bindingA1 = "11111111-1111-4111-8111-111111111111"
        let bindingA2 = "22222222-2222-4222-8222-222222222222"
        let bindingB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        var serverAOnline = true
        var holdNextPostA = false
        var releasePostA: CheckedContinuation<PushDeviceRegisterResponse, Error>?
        var deletedOnA: [String] = []

        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { req, endpoint, _ in
                if endpoint == endpointA {
                    if holdNextPostA {
                        holdNextPostA = false
                        return try await withCheckedThrowingContinuation { cont in
                            releasePostA = cont
                        }
                    }
                    return PushDeviceRegisterResponse(
                        deviceID: req.deviceID,
                        bindingID: bindingA1,
                        enabled: true,
                        registrationVersion: 1,
                        apnsEnv: req.apnsEnv
                    )
                }
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: bindingB,
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv
                )
            },
            deleteCall: { _, bindingID, endpoint, _ in
                if endpoint == endpointA {
                    if !serverAOnline {
                        throw ServerError.http(503, "server A offline")
                    }
                    deletedOnA.append(bindingID)
                }
            },
            configSnapshot: { self.makeConfig(endpoint: activeEndpoint, apiKey: activeKey) },
            isPushEnabled: { true },
            resolveAPNsEnv: { "sandbox" },
            bundleIDProvider: { "com.dzarlax.health-sync" },
            localeProvider: { "en" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let tokenHex = String(repeating: "8", count: 64)

        await manager.syncRegistration(tokenHex: tokenHex)
        serverAOnline = false
        activeEndpoint = endpointB
        activeKey = "key-b"
        await manager.handleConfigurationChanged(pushEnabled: true)
        #expect(manager.loadPendingDeregistrations().map(\.bindingID) == [bindingA1])

        holdNextPostA = true
        activeEndpoint = endpointA
        activeKey = "key-a"
        let switchBackTask = Task { await manager.handleConfigurationChanged(pushEnabled: true) }
        guard await waitForSignal({ releasePostA != nil }) else {
            Issue.record("Timed out waiting for the held request")
            return
        }

        // Drain while POST(A) is in flight -> must defer DELETE(bindingA1).
        serverAOnline = true
        await manager.drainPendingDeregistrations()
        #expect(deletedOnA.isEmpty)

        // POST(A) returns a brand-new bindingA2 -> deferred DELETE(bindingA1) now runs cleanly.
        let deviceID = try! manager.ensureDeviceID()
        releasePostA?.resume(returning: PushDeviceRegisterResponse(
            deviceID: deviceID,
            bindingID: bindingA2,
            enabled: true,
            registrationVersion: 2,
            apnsEnv: "sandbox"
        ))
        await switchBackTask.value

        #expect(manager.activeBindingIDForCurrentProfile() == bindingA2)
        #expect(deletedOnA == [bindingA1])
        #expect(manager.loadPendingDeregistrations().isEmpty)
    }

    @Test
    func tokenRotationSerializesPostsForSameProfileAndSendsLatestToken() async {
        let keychain = InMemoryKeychainAccess()
        let endpoint = URL(string: "https://server-a.example.com")!
        let bindingA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

        let token1 = String(repeating: "1", count: 64)
        let token2 = String(repeating: "2", count: 64)
        let token3 = String(repeating: "3", count: 64)

        var sentTokens: [String] = []
        var serverActiveToken: String?
        var releaseFirstPost: CheckedContinuation<PushDeviceRegisterResponse, Error>?

        var registrationWaits = 0
        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { req, _, _ in
                sentTokens.append(req.apnsToken)
                if sentTokens.count == 1 {
                    let response = try await withCheckedThrowingContinuation { cont in
                        releaseFirstPost = cont
                    }
                    serverActiveToken = req.apnsToken
                    return response
                }
                serverActiveToken = req.apnsToken
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: bindingA,
                    enabled: true,
                    registrationVersion: Int64(sentTokens.count),
                    apnsEnv: req.apnsEnv
                )
            },
            deleteCall: { _, _, _, _ in },
            configSnapshot: { self.makeConfig(endpoint: endpoint, apiKey: "key-a") },
            isPushEnabled: { true },
            resolveAPNsEnv: { "sandbox" },
            bundleIDProvider: { "com.dzarlax.health-sync" },
            localeProvider: { "en" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            onRegistrationWait: { registrationWaits += 1 }
        )

        // 1. Start POST for token1 and hold it in flight.
        let post1Task = Task { await manager.syncRegistration(tokenHex: token1) }
        guard await waitForSignal({ releaseFirstPost != nil }) else {
            Issue.record("Timed out waiting for the held request")
            return
        }

        // 2. While token1's POST is in flight, APNs rotates token1 -> token2 -> token3.
        let post2Task = Task { await manager.syncRegistration(tokenHex: token2) }
        #expect(await waitForSignal { registrationWaits == 1 })
        let post3Task = Task { await manager.syncRegistration(tokenHex: token3) }
        #expect(await waitForSignal { registrationWaits == 2 })

        // No second POST may start concurrently while token1 is still in flight.
        #expect(sentTokens == [token1])

        // 3. Complete token1's POST -> serialized loop sends ONLY the latest token3.
        let deviceID = try! manager.ensureDeviceID()
        releaseFirstPost?.resume(returning: PushDeviceRegisterResponse(
            deviceID: deviceID,
            bindingID: bindingA,
            enabled: true,
            registrationVersion: 1,
            apnsEnv: "sandbox"
        ))
        await post1Task.value
        await post2Task.value
        await post3Task.value

        #expect(sentTokens == [token1, token3])
        #expect(serverActiveToken == token3)
        #expect(manager.activeBindingIDForCurrentProfile() == bindingA)
        #expect(manager.loadActiveRegistration()?.tokenHash != nil)
        #expect(manager.loadActiveRegistration()?.tokenHash != manager.loadActiveRegistration().map { _ in "" })

        // Verify a follow-up sync with token3 hits the 24h heartbeat cache (proving
        // local tokenHash matches token3, not token1).
        await manager.syncRegistration(tokenHex: token3)
        #expect(sentTokens == [token1, token3])
    }

    @Test(arguments: [
        PushNotificationConstants.pendingDeregistrationsAccount,
        PushNotificationConstants.activeRegistrationAccount
    ])
    func keychainFailureRetainsBindingUntilOptOutCleanupCanRetry(failedAccount: String) async {
        let endpoint = URL(string: "https://server.example.com")!
        let binding = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let keychain = InMemoryKeychainAccess()
        var enabled = true
        var deleted: [String] = []
        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { request, _, _ in
                PushDeviceRegisterResponse(
                    deviceID: request.deviceID, bindingID: binding, enabled: true,
                    registrationVersion: 1, apnsEnv: "sandbox"
                )
            },
            deleteCall: { _, bindingID, _, _ in deleted.append(bindingID) },
            configSnapshot: { self.makeConfig(endpoint: endpoint, apiKey: "test-key") },
            isPushEnabled: { enabled },
            resolveAPNsEnv: { "sandbox" },
            localeProvider: { "en" }
        )

        if failedAccount == PushNotificationConstants.activeRegistrationAccount {
            keychain.failedWrites.insert(failedAccount)
        }
        await manager.syncRegistration(tokenHex: String(repeating: "a", count: 64))
        if failedAccount == PushNotificationConstants.activeRegistrationAccount {
            #expect(manager.loadActiveRegistration() == nil)
            #expect(manager.loadPendingDeregistrations().map(\.bindingID) == [binding])
        } else {
            #expect(manager.loadActiveRegistration()?.bindingID == binding)
            keychain.failedWrites.insert(failedAccount)
        }

        enabled = false
        await manager.disablePushNotifications()
        if failedAccount == PushNotificationConstants.pendingDeregistrationsAccount {
            #expect(manager.loadActiveRegistration()?.bindingID == binding)
            #expect(manager.activeBindingIDForCurrentProfile() == nil)
            #expect(deleted.isEmpty)
        }

        keychain.failedWrites.removeAll()
        await manager.handleAppBecameActive()
        #expect(deleted == [binding])
        #expect(manager.loadActiveRegistration() == nil)
        #expect(manager.loadPendingDeregistrations().isEmpty)
    }

    @Test
    func offlineOptOutStillRetriesCleanupAfterSevenDays() async {
        let endpoint = URL(string: "https://server.example.com")!
        let binding = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        var enabled = true
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        var deleted: [String] = []
        var connected = false
        let manager = PushRegistrationManager(
            keychain: InMemoryKeychainAccess(),
            registerCall: { request, _, _ in
                PushDeviceRegisterResponse(
                    deviceID: request.deviceID, bindingID: binding, enabled: true,
                    registrationVersion: 1, apnsEnv: "sandbox"
                )
            },
            deleteCall: { _, bindingID, _, _ in
                guard connected else { throw URLError(.notConnectedToInternet) }
                deleted.append(bindingID)
            },
            configSnapshot: { self.makeConfig(endpoint: endpoint, apiKey: "test-key") },
            isPushEnabled: { enabled },
            now: { date }
        )
        await manager.syncRegistration(tokenHex: String(repeating: "a", count: 64))
        enabled = false
        await manager.disablePushNotifications()
        #expect(manager.loadPendingDeregistrations().map(\.bindingID) == [binding])

        date.addTimeInterval(8 * 24 * 60 * 60)
        connected = true
        await manager.handleAppBecameActive()
        #expect(deleted == [binding])
        #expect(manager.loadPendingDeregistrations().isEmpty)
    }

    @Test
    func callbackTasksReadLatestTokenInsteadOfCapturedToken() async {
        let endpoint = URL(string: "https://server.example.com")!
        var sentTokens: [String] = []
        let manager = PushRegistrationManager(
            keychain: InMemoryKeychainAccess(),
            registerCall: { request, _, _ in
                sentTokens.append(request.apnsToken)
                return PushDeviceRegisterResponse(
                    deviceID: request.deviceID, bindingID: UUID().uuidString,
                    enabled: true, registrationVersion: 1, apnsEnv: "sandbox"
                )
            },
            configSnapshot: { self.makeConfig(endpoint: endpoint, apiKey: "test-key") },
            isPushEnabled: { true },
            resolveAPNsEnv: { "sandbox" },
            localeProvider: { "en" }
        )
        manager.handleDeviceToken(Data(repeating: 0x11, count: 32))
        manager.handleDeviceToken(Data(repeating: 0x22, count: 32))
        await manager.handleAppBecameActive()

        #expect(sentTokens == [String(repeating: "22", count: 32)])
    }

    @Test
    func testRuntimeRejectsPushDeregistration() async {
        guard SyncRuntime.isTestMode else {
            Issue.record("Expected the test runtime")
            return
        }
        do {
            try await ServerClient.shared.deletePushDeviceBinding(
                deviceID: UUID().uuidString,
                bindingID: UUID().uuidString,
                endpoint: URL(string: "https://example.invalid")!,
                apiKey: "test-key"
            )
            Issue.record("Unexpected successful request in test mode")
        } catch ServerError.missingConfig {
            // The runtime guard stopped the request before the transport.
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    @Test
    func lostRegistrationResponseReplaysSameDurableAttemptAfterRestart() async throws {
        let endpoint = URL(string: "https://server.example.com")!
        let bindingID = UUID().uuidString
        let keychain = InMemoryKeychainAccess()
        var attemptsSent: [UUID] = []
        var committed: Set<UUID> = []
        let register: PushRegistrationManager.RegisterCall = { request, _, _ in
            let id = try #require(request.registrationAttemptID)
            #expect(keychain.items[PushNotificationConstants.registrationAttemptsAccount] != nil)
            attemptsSent.append(id)
            if committed.insert(id).inserted { throw URLError(.networkConnectionLost) }
            return PushDeviceRegisterResponse(
                deviceID: request.deviceID, bindingID: bindingID,
                enabled: true, registrationVersion: 1, apnsEnv: request.apnsEnv
            )
        }
        func makeManager() -> PushRegistrationManager {
            PushRegistrationManager(
                keychain: keychain,
                registerCall: register,
                configSnapshot: { self.makeConfig(endpoint: endpoint, apiKey: "key-a") },
                isPushEnabled: { true }, resolveAPNsEnv: { "sandbox" }, localeProvider: { "en" }
            )
        }

        let token = String(repeating: "a", count: 64)
        let beforeRestart = makeManager()
        await beforeRestart.syncRegistration(tokenHex: token)
        #expect(beforeRestart.loadActiveRegistration() == nil)
        let id = try #require(attemptsSent.first)
        #expect(id.uuid.6 >> 4 == 7)

        let afterRestart = makeManager()
        await afterRestart.syncRegistration(tokenHex: token)
        #expect(attemptsSent == [id, id])
        #expect(committed == [id])
        #expect(afterRestart.activeBindingIDForCurrentProfile() == bindingID)
        #expect(keychain.items[PushNotificationConstants.registrationAttemptsAccount] == nil)
    }

    @Test(arguments: [true, false])
    func lostRegistrationResponseCancelsOriginalAttemptAfterOfflineRestart(switchProfile: Bool) async throws {
        let endpointA = URL(string: "https://server-a.example.com")!
        let endpointB = URL(string: "https://server-b.example.com")!
        let keychain = InMemoryKeychainAccess()
        var enabled = true
        var endpoint = endpointA
        var connected = false
        var requests: [UUID] = []
        var committed: Set<UUID> = []
        var cancelled: [UUID] = []
        let register: PushRegistrationManager.RegisterCall = { request, _, _ in
            let id = try #require(request.registrationAttemptID)
            requests.append(id)
            committed.insert(id)
            throw URLError(.networkConnectionLost)
        }
        let cancel: PushRegistrationManager.CancelAttemptCall = { _, attemptID, target, apiKey in
            #expect(target == endpointA)
            #expect(apiKey == "key-a")
            guard connected else { throw URLError(.notConnectedToInternet) }
            committed.remove(attemptID)
            cancelled.append(attemptID)
        }
        func makeManager() -> PushRegistrationManager {
            PushRegistrationManager(
                keychain: keychain, registerCall: register, cancelAttemptCall: cancel,
                configSnapshot: { self.makeConfig(endpoint: endpoint, apiKey: endpoint == endpointA ? "key-a" : "key-b") },
                isPushEnabled: { enabled }, resolveAPNsEnv: { "sandbox" }, localeProvider: { "en" }
            )
        }

        let manager = makeManager()
        await manager.syncRegistration(tokenHex: String(repeating: "b", count: 64))
        let id = try #require(requests.first)
        if switchProfile {
            endpoint = endpointB
            await manager.drainPendingDeregistrations()
        } else {
            enabled = false
            await manager.disablePushNotifications()
        }
        #expect(requests == [id])
        #expect(committed == [id])
        #expect(keychain.items[PushNotificationConstants.registrationAttemptsAccount] != nil)

        connected = true
        let afterRestart = makeManager()
        await afterRestart.handleAppBecameActive()
        #expect(requests == [id])
        #expect(cancelled == [id])
        #expect(committed.isEmpty)
        #expect(keychain.items[PushNotificationConstants.registrationAttemptsAccount] == nil)
    }

    @Test
    func lostPostIsCancelledBeforeSubmittingRotatedToken() async throws {
        let endpoint = URL(string: "https://server.example.com")!
        var events: [String] = []
        var attempts: [UUID] = []
        var cancelled: [UUID] = []
        let manager = PushRegistrationManager(
            keychain: InMemoryKeychainAccess(),
            registerCall: { request, _, _ in
                let id = try #require(request.registrationAttemptID)
                attempts.append(id)
                events.append("post")
                if attempts.count == 1 { throw URLError(.timedOut) }
                return PushDeviceRegisterResponse(
                    deviceID: request.deviceID, bindingID: UUID().uuidString,
                    enabled: true, registrationVersion: 1, apnsEnv: request.apnsEnv
                )
            },
            cancelAttemptCall: { _, id, _, _ in
                events.append("cancel")
                cancelled.append(id)
            },
            configSnapshot: { self.makeConfig(endpoint: endpoint, apiKey: "test-key") },
            isPushEnabled: { true }, resolveAPNsEnv: { "sandbox" }, localeProvider: { "en" }
        )
        await manager.syncRegistration(tokenHex: String(repeating: "c", count: 64))
        await manager.syncRegistration(tokenHex: String(repeating: "d", count: 64))
        let original = try #require(attempts.first)
        #expect(events == ["post", "cancel", "post"])
        #expect(cancelled == [original])
        #expect(attempts.last != original)
        #expect(manager.loadActiveRegistration()?.registrationAttemptID == attempts.last)
    }

    @Test
    func journalWriteFailurePreventsRegistrationPOST() async {
        let endpoint = URL(string: "https://server.example.com")!
        let keychain = InMemoryKeychainAccess()
        keychain.failedWrites.insert(PushNotificationConstants.registrationAttemptsAccount)
        var posts = 0
        let manager = PushRegistrationManager(
            keychain: keychain,
            registerCall: { request, _, _ in
                posts += 1
                return PushDeviceRegisterResponse(
                    deviceID: request.deviceID, bindingID: UUID().uuidString,
                    enabled: true, registrationVersion: 1, apnsEnv: request.apnsEnv
                )
            },
            configSnapshot: { self.makeConfig(endpoint: endpoint, apiKey: "test-key") },
            isPushEnabled: { true }
        )
        let token = String(repeating: "b", count: 64)
        await manager.syncRegistration(tokenHex: token)
        #expect(posts == 0)
        #expect(manager.loadActiveRegistration() == nil)
        keychain.failedWrites.removeAll()
        await manager.syncRegistration(tokenHex: token)
        #expect(posts == 1)
    }


    @Test(arguments: [true, false])
    func optOutThenOptInRecoversLostRefreshResponse(reusesBinding: Bool) async {
        let endpoint = URL(string: "https://server.example.com")!
        let originalBinding = UUID().uuidString
        let refreshedBinding = reusesBinding ? originalBinding : UUID().uuidString
        let token1 = String(repeating: "a", count: 64)
        let token2 = String(repeating: "b", count: 64)
        var enabled = true
        var serverBinding: String?
        var received: Set<UUID> = []
        var releaseRefresh: CheckedContinuation<Void, Never>?
        var waited = false
        var bindingDeletes: [String] = []

        let manager = PushRegistrationManager(
            keychain: InMemoryKeychainAccess(),
            registerCall: { request, _, _ in
                let id = try #require(request.registrationAttemptID)
                if received.insert(id).inserted {
                    serverBinding = request.apnsToken == token1 ? originalBinding : refreshedBinding
                    if request.apnsToken == token2 && releaseRefresh == nil {
                        await withCheckedContinuation { releaseRefresh = $0 }
                        throw URLError(.timedOut)
                    }
                } else if serverBinding == nil {
                    throw ServerError.http(409, "registration attempt is superseded")
                }
                return PushDeviceRegisterResponse(
                    deviceID: request.deviceID, bindingID: try #require(serverBinding), enabled: true,
                    registrationVersion: Int64(received.count), apnsEnv: request.apnsEnv
                )
            },
            deleteCall: { _, id, _, _ in
                bindingDeletes.append(id)
                if id == serverBinding { serverBinding = nil }
            },
            cancelAttemptCall: { _, _, _, _ in },
            configSnapshot: { self.makeConfig(endpoint: endpoint, apiKey: "test-key") },
            isPushEnabled: { enabled },
            resolveAPNsEnv: { "sandbox" },
            localeProvider: { "en" },
            onRegistrationWait: { waited = true }
        )
        await manager.syncRegistration(tokenHex: token1)
        let refresh = Task { await manager.syncRegistration(tokenHex: token2) }
        guard await waitForSignal({ releaseRefresh != nil }) else {
            Issue.record("Refresh did not start")
            return
        }
        enabled = false
        await manager.disablePushNotifications()
        enabled = true
        let retry = Task { await manager.syncRegistration(tokenHex: token2) }
        #expect(await waitForSignal { waited })
        releaseRefresh?.resume()
        await refresh.value
        await retry.value
        #expect(received.count == 2)
        #expect(bindingDeletes == (reusesBinding ? [] : [originalBinding]))
        #expect(manager.loadPendingDeregistrations().isEmpty)
        #expect(serverBinding == refreshedBinding)
        #expect(manager.activeBindingIDForCurrentProfile() == refreshedBinding)
    }
}
