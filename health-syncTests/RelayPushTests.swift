import CryptoKit
import Foundation
import Security
import XCTest
@testable import health_sync

private final class MockAppAttestProvider: AppAttestProviding, @unchecked Sendable {
    var isSupported: Bool = true
    var generatedKeyID: String = Data(repeating: 0x42, count: 32).base64EncodedString()
    var attestCalls: Int = 0
    var assertionCalls: Int = 0

    func generateKey() async throws -> String {
        generatedKeyID
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestCalls += 1
        return Data("mock-attest-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionCalls += 1
        return Data("mock-assertion-\(assertionCalls)".utf8)
    }
}

private final class MockRelayHTTPTransport: RelayHTTPTransport, @unchecked Sendable {
    struct RecordedRequest {
        let method: String
        let url: URL
        let body: Data
        let headers: [String: String]
    }

    private let lock = NSLock()
    private(set) var requests: [RecordedRequest] = []
    var handler: (@Sendable (String, URL, Data, [String: String]) async throws -> (Int, Data))?

    func send(
        method: String,
        url: URL,
        body: Data,
        headers: [String: String]
    ) async throws -> (Int, Data) {
        lock.lock()
        requests.append(RecordedRequest(method: method, url: url, body: body, headers: headers))
        let h = handler
        lock.unlock()
        if let h {
            return try await h(method, url, body, headers)
        }
        return (200, Data("{}".utf8))
    }
}

@MainActor
private final class InMemoryRelayKeychain: KeychainAccess {
    var items: [String: Data] = [:]
    var failedReads: Set<String> = []
    var failedWrites: Set<String> = []

    func copy(_ query: [CFString: Any]) -> (OSStatus, Any?) {
        guard let account = query[kSecAttrAccount] as? String else { return (errSecParam, nil) }
        guard !failedReads.contains(account) else { return (errSecInteractionNotAllowed, nil) }
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
final class RelayPushTests: XCTestCase {
    private let serverURL = URL(string: "https://selfhosted.example.com")!
    private let apiKey = "selfhosted-api-key-123"
    private let tokenA = String(repeating: "a1", count: 32)
    private let tokenB = String(repeating: "b2", count: 32)

    private func makeConfig() -> SyncConfiguration {
        SyncConfiguration(
            endpoint: serverURL,
            apiKey: apiKey,
            fingerprint: UserDefaultsSyncConfiguration.fingerprint(endpoint: serverURL, apiKey: apiKey),
            metricGroups: [.vitals],
            workoutsEnabled: true,
            backgroundEnabled: true,
            syncOnLaunch: true,
            interval: 900,
            workoutHRTimeline: true
        )
    }

    private func makePreferences(
        apnsPushEnabled: Bool = true,
        apnsPushConfigured: Bool? = true,
        apnsTransportMode: String? = nil,
        apnsRelayURL: String? = nil
    ) -> NotificationPreferencesResponse {
        NotificationPreferencesResponse(
            morningWeekdayHour: 8,
            morningWeekendHour: 9,
            eveningWeekdayHour: 20,
            eveningWeekendHour: 21,
            daytimeEnabled: true,
            daytimeStartHour: 9,
            daytimeEndHour: 21,
            pushMorningReport: true,
            pushEveningReport: true,
            pushCheckins: true,
            pushDaytimeUpdates: true,
            pushDigestsNudges: true,
            telegramNotificationsEnabled: true,
            inboxEnabled: true,
            apnsPushEnabled: apnsPushEnabled,
            apnsPushConfigured: apnsPushConfigured,
            apnsTransportMode: apnsTransportMode,
            apnsRelayURL: apnsRelayURL,
            telegramConfigured: false,
            activePushDevicesCount: 0
        )
    }

    func testOriginValidationPinsExactProductionOrigin() {
        XCTAssertEqual(
            RelayOriginValidator.validatedOrigin("https://push.dzarlax.dev")?.absoluteString,
            "https://push.dzarlax.dev"
        )
        XCTAssertEqual(
            RelayOriginValidator.validatedOrigin("https://PUSH.DZARLAX.DEV/")?.absoluteString,
            "https://push.dzarlax.dev"
        )
        XCTAssertNil(RelayOriginValidator.validatedOrigin("http://push.dzarlax.dev"))
        XCTAssertNil(RelayOriginValidator.validatedOrigin("https://evil.dzarlax.dev"))
        XCTAssertNil(RelayOriginValidator.validatedOrigin("https://push.dzarlax.dev:8443"))
        XCTAssertNil(RelayOriginValidator.validatedOrigin("https://push.dzarlax.dev/v1"))
        XCTAssertNil(RelayOriginValidator.validatedOrigin("https://user@push.dzarlax.dev"))
        XCTAssertNil(RelayOriginValidator.validatedOrigin("https://push.dzarlax.dev?foo=1"))
    }

    func testDirectFallbackOn404PreferencesAndOnStage3200WithoutTransportMode() async {
        // Case 1: Stage 2 server returns 404 on /api/notifications/preferences -> Direct fallback.
        var stage2Requests: [PushDeviceRegisterRequest] = []
        let kc1 = InMemoryRelayKeychain()
        let mgrStage2 = PushRegistrationManager(
            keychain: kc1,
            registerCall: { req, _, _ in
                stage2Requests.append(req)
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: UUID().uuidString.lowercased(),
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv,
                    inboxContractVersion: 2
                )
            },
            deleteCall: { _, _, _, _ in },
            cancelAttemptCall: { _, _, _, _ in },
            fetchPreferencesCall: { _, _ in
                throw ServerError.http(404, "not found")
            },
            configSnapshot: { self.makeConfig() },
            isPushEnabled: { true },
            resolveAPNsEnv: { "production" },
            resetBadge: {}
        )
        await mgrStage2.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(stage2Requests.count, 1)
        XCTAssertEqual(stage2Requests.first?.apnsToken, tokenA)
        XCTAssertNil(stage2Requests.first?.transport)
        XCTAssertEqual(mgrStage2.pushServerStatus, PushServerStatus.direct)

        // Case 2: Deployed Stage 3 server returns 200 JSON WITHOUT apns_transport_mode -> Direct fallback.
        let stage3JSON = """
        {
          "morning_weekday_hour": 8,
          "morning_weekend_hour": 9,
          "evening_weekday_hour": 20,
          "evening_weekend_hour": 21,
          "daytime_enabled": true,
          "daytime_start_hour": 9,
          "daytime_end_hour": 21,
          "push_morning_report": true,
          "push_evening_report": true,
          "push_checkins": true,
          "push_daytime_updates": true,
          "push_digests_nudges": true,
          "telegram_notifications_enabled": true,
          "inbox_enabled": true,
          "apns_push_enabled": true,
          "telegram_configured": true,
          "active_push_devices_count": 1
        }
        """
        let decodedStage3 = try! JSONDecoder().decode(NotificationPreferencesResponse.self, from: Data(stage3JSON.utf8))
        XCTAssertNil(decodedStage3.apnsTransportMode)

        var stage3Requests: [PushDeviceRegisterRequest] = []
        let kc2 = InMemoryRelayKeychain()
        let mgrStage3 = PushRegistrationManager(
            keychain: kc2,
            registerCall: { req, _, _ in
                stage3Requests.append(req)
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: UUID().uuidString.lowercased(),
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv,
                    inboxContractVersion: 2
                )
            },
            deleteCall: { _, _, _, _ in },
            cancelAttemptCall: { _, _, _, _ in },
            fetchPreferencesCall: { _, _ in decodedStage3 },
            configSnapshot: { self.makeConfig() },
            isPushEnabled: { true },
            resolveAPNsEnv: { "production" },
            resetBadge: {}
        )
        await mgrStage3.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(stage3Requests.count, 1)
        XCTAssertEqual(stage3Requests.first?.apnsToken, tokenA)
        XCTAssertNil(stage3Requests.first?.transport)
        XCTAssertEqual(mgrStage3.pushServerStatus, PushServerStatus.direct)
    }

    func testExplicitModeNoneDoesNotPostAndSetsNotConfiguredStatus() async {
        var registerCount = 0
        let mgr = PushRegistrationManager(
            keychain: InMemoryRelayKeychain(),
            registerCall: { _, _, _ in
                registerCount += 1
                throw ServerError.http(500, "unexpected")
            },
            deleteCall: { _, _, _, _ in },
            cancelAttemptCall: { _, _, _, _ in },
            fetchPreferencesCall: { _, _ in
                self.makePreferences(
                    apnsPushEnabled: false,
                    apnsPushConfigured: false,
                    apnsTransportMode: "none",
                    apnsRelayURL: nil
                )
            },
            configSnapshot: { self.makeConfig() },
            isPushEnabled: { true },
            resolveAPNsEnv: { "production" },
            resetBadge: {}
        )
        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(registerCount, 0)
        XCTAssertEqual(mgr.pushServerStatus, PushServerStatus.notConfiguredOnServer)
    }

    func testUntrustedRelayURLRejectedWithoutCallingRelayOrServer() async {
        let relayTransport = MockRelayHTTPTransport()
        let coordinator = RelayGrantCoordinator(
            keychain: InMemoryRelayKeychain(),
            appAttest: MockAppAttestProvider(),
            transport: relayTransport
        )
        var serverPosts = 0
        let mgr = PushRegistrationManager(
            keychain: InMemoryRelayKeychain(),
            registerCall: { _, _, _ in
                serverPosts += 1
                throw ServerError.http(500, "unexpected")
            },
            deleteCall: { _, _, _, _ in },
            cancelAttemptCall: { _, _, _, _ in },
            fetchPreferencesCall: { _, _ in
                self.makePreferences(
                    apnsPushEnabled: true,
                    apnsPushConfigured: true,
                    apnsTransportMode: "relay",
                    apnsRelayURL: "https://evil-relay.example.com"
                )
            },
            relayCoordinator: coordinator,
            configSnapshot: { self.makeConfig() },
            isPushEnabled: { true },
            resolveAPNsEnv: { "production" },
            resetBadge: {}
        )
        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(serverPosts, 0)
        XCTAssertTrue(relayTransport.requests.isEmpty)
        XCTAssertEqual(mgr.pushServerStatus, PushServerStatus.untrustedRelayURL)
    }

    func testRelayGrantRecoveryAfterLostResponseTokenRotationAndRevocationOnUnreachableServer() async {
        let kc = InMemoryRelayKeychain()
        let attest = MockAppAttestProvider()
        let relayTransport = MockRelayHTTPTransport()
        let fixedGrantID = UUID().uuidString.lowercased()
        var grantCreateAttempts = 0
        var seenClientGrantKeys: [String] = []
        var seenSecretHashes: [String] = []
        var tokenUpdateCount = 0
        var revokedGrantIDs: [String] = []

        relayTransport.handler = { method, url, body, _ in
            let path = url.path
            if path.hasSuffix("/v1/attest/challenge") {
                let data = try JSONEncoder().encode(RelayChallengeResponse(
                    challengeID: UUID().uuidString.lowercased(),
                    nonce: "nonce-\(UUID().uuidString)",
                    expiresAt: nil
                ))
                return (200, data)
            }
            if path.hasSuffix("/v1/attest/register") {
                return (200, Data(#"{"key_id":"ok"}"#.utf8))
            }
            if method == "POST", path.hasSuffix("/v1/grants") {
                grantCreateAttempts += 1
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                if let cgk = json?["client_grant_key"] as? String {
                    seenClientGrantKeys.append(cgk)
                }
                if let sh = json?["secret_hash"] as? String {
                    seenSecretHashes.append(sh)
                }
                if grantCreateAttempts == 1 {
                    // Simulate network drop AFTER Relay committed grant.
                    throw URLError(.networkConnectionLost)
                }
                let resp = try JSONEncoder().encode(RelayGrantCreateResponse(
                    grantID: fixedGrantID,
                    expiresAt: nil,
                    tokenHash: RelayGrantCoordinator.sha256Hex(self.tokenA)
                ))
                return (200, resp)
            }
            if method == "PUT", path.hasSuffix("/v1/attest/token") {
                tokenUpdateCount += 1
                return (200, Data(#"{"updated":1,"active_grant_ids":["\#(fixedGrantID)"]}"#.utf8))
            }
            if method == "DELETE", path.hasSuffix("/v1/grants/\(fixedGrantID)") {
                revokedGrantIDs.append(fixedGrantID)
                return (200, Data(#"{"revoked":true}"#.utf8))
            }
            return (404, Data())
        }

        let coordinator = RelayGrantCoordinator(
            keychain: kc,
            appAttest: attest,
            transport: relayTransport
        )
        var pushEnabled = true
        var serverRegRequests: [PushDeviceRegisterRequest] = []
        let mgr = PushRegistrationManager(
            keychain: kc,
            registerCall: { req, _, _ in
                serverRegRequests.append(req)
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: req.bindingID ?? UUID().uuidString.lowercased(),
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv,
                    inboxContractVersion: 2
                )
            },
            deleteCall: { _, _, _, _ in
                // Simulate unreachable self-hosted server during disable!
                throw URLError(.cannotConnectToHost)
            },
            cancelAttemptCall: { _, _, _, _ in
                throw URLError(.cannotConnectToHost)
            },
            fetchPreferencesCall: { _, _ in
                self.makePreferences(
                    apnsPushEnabled: true,
                    apnsPushConfigured: true,
                    apnsTransportMode: "relay",
                    apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                )
            },
            relayCoordinator: coordinator,
            configSnapshot: { self.makeConfig() },
            isPushEnabled: { pushEnabled },
            resolveAPNsEnv: { "production" },
            resetBadge: {}
        )

        // 1. First attempt drops network on POST /v1/grants -> pending attempt stays in Keychain.
        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(grantCreateAttempts, 1)
        XCTAssertEqual(serverRegRequests.count, 0)

        // 2. Retry recovers SAME client_grant_key and secret_hash without rotating secret, then registers on server.
        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(grantCreateAttempts, 2)
        XCTAssertEqual(seenClientGrantKeys.count, 2)
        XCTAssertEqual(seenClientGrantKeys[0], seenClientGrantKeys[1])
        XCTAssertEqual(seenSecretHashes[0], seenSecretHashes[1])
        XCTAssertEqual(serverRegRequests.count, 1)
        XCTAssertEqual(serverRegRequests[0].transport, "relay")
        XCTAssertNil(serverRegRequests[0].apnsToken)
        XCTAssertEqual(serverRegRequests[0].relayGrantID, fixedGrantID)
        XCTAssertNotNil(serverRegRequests[0].relayGrantSecret)
        XCTAssertNotNil(serverRegRequests[0].bindingID)

        // 3. Rotating APNs token updates Relay via PUT /v1/attest/keys/{key_id}/token without creating a new grant.
        await mgr.syncRegistration(tokenHex: tokenB)
        XCTAssertEqual(tokenUpdateCount, 1)
        XCTAssertEqual(grantCreateAttempts, 2)
        XCTAssertEqual(serverRegRequests.count, 1)

        // 4. Disabling push revokes grant in Relay EVEN THOUGH self-hosted server is unreachable.
        pushEnabled = false
        await mgr.disablePushNotifications()
        XCTAssertEqual(revokedGrantIDs, [fixedGrantID])
        XCTAssertTrue(coordinator.loadPendingRevocations().isEmpty)
    }

    func testRelayRevocationByClientGrantKeyWhenCreateGrantResponseLost() async {
        let kc = InMemoryRelayKeychain()
        let attest = MockAppAttestProvider()
        let relayTransport = MockRelayHTTPTransport()
        var capturedClientGrantKey: String?
        var cancelledClientGrantKeys: [String] = []

        relayTransport.handler = { method, url, body, _ in
            let path = url.path
            if path.hasSuffix("/v1/attest/challenge") {
                let data = try JSONEncoder().encode(RelayChallengeResponse(
                    challengeID: UUID().uuidString.lowercased(),
                    nonce: "nonce-\(UUID().uuidString)",
                    expiresAt: nil
                ))
                return (200, data)
            }
            if path.hasSuffix("/v1/attest/register") {
                return (200, Data(#"{"key_id":"ok"}"#.utf8))
            }
            if method == "POST", path.hasSuffix("/v1/grants") {
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                capturedClientGrantKey = json?["client_grant_key"] as? String
                throw URLError(.timedOut)
            }
            if method == "DELETE", path.contains("/v1/grants/by-client-key/") {
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(json?["op"] as? String, RelayPushConstants.opGrantCancelByClientKey)
                if let resID = json?["resource_id"] as? String {
                    cancelledClientGrantKeys.append(resID)
                }
                return (200, Data(#"{"cancelled":true}"#.utf8))
            }
            return (404, Data())
        }

        let coordinator = RelayGrantCoordinator(
            keychain: kc,
            appAttest: attest,
            transport: relayTransport
        )
        var pushEnabled = true
        let mgr = PushRegistrationManager(
            keychain: kc,
            registerCall: { _, _, _ in throw ServerError.http(500, "unexpected") },
            deleteCall: { _, _, _, _ in },
            cancelAttemptCall: { _, _, _, _ in },
            fetchPreferencesCall: { _, _ in
                self.makePreferences(
                    apnsPushEnabled: true,
                    apnsPushConfigured: true,
                    apnsTransportMode: "relay",
                    apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                )
            },
            relayCoordinator: coordinator,
            configSnapshot: { self.makeConfig() },
            isPushEnabled: { pushEnabled },
            resolveAPNsEnv: { "production" },
            resetBadge: {}
        )

        // POST /v1/grants times out -> grant_id is unknown, but client_grant_key is durably stored.
        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertNotNil(capturedClientGrantKey)

        // User disables pushes -> Relay receives DELETE /v1/grants/by-client-key/{client_grant_key}.
        pushEnabled = false
        await mgr.disablePushNotifications()
        XCTAssertEqual(cancelledClientGrantKeys, [capturedClientGrantKey!])
        XCTAssertTrue(coordinator.loadPendingGrantAttempts().isEmpty)
        XCTAssertTrue(coordinator.loadPendingRevocations().isEmpty)
    }

    func testLateTokenRotationResponseCannotResurrectDisabledOrSwitchedProfile() async {
        for switchProfile in [false, true] {
            let kc = InMemoryRelayKeychain()
            let attest = MockAppAttestProvider()
            let relayTransport = MockRelayHTTPTransport()
            let initialGrantID = UUID().uuidString.lowercased()
            let secondServerURL = URL(string: "https://second-server.example.com")!
            var currentServerURL = serverURL
            var pushEnabled = true

            var rotationStarted: CheckedContinuation<Void, Never>?
            var releaseRotation: CheckedContinuation<(Int, Data), Error>?

            relayTransport.handler = { method, url, _, _ in
                let path = url.path
                if path.hasSuffix("/v1/attest/challenge") {
                    let data = try JSONEncoder().encode(RelayChallengeResponse(
                        challengeID: UUID().uuidString.lowercased(),
                        nonce: "nonce-\(UUID().uuidString)",
                        expiresAt: nil
                    ))
                    return (200, data)
                }
                if path.hasSuffix("/v1/attest/register") {
                    return (200, Data(#"{"key_id":"ok"}"#.utf8))
                }
                if method == "POST", path.hasSuffix("/v1/grants") {
                    let resp = try JSONEncoder().encode(RelayGrantCreateResponse(
                        grantID: initialGrantID,
                        expiresAt: nil,
                        tokenHash: RelayGrantCoordinator.sha256Hex(self.tokenA)
                    ))
                    return (200, resp)
                }
                if method == "PUT", path.hasSuffix("/v1/attest/token") {
                    return try await withCheckedThrowingContinuation { cont in
                        releaseRotation = cont
                        rotationStarted?.resume()
                        rotationStarted = nil
                    }
                }
                if method == "DELETE" {
                    return (200, Data(#"{"revoked":true}"#.utf8))
                }
                return (404, Data())
            }

            let coordinator = RelayGrantCoordinator(keychain: kc, appAttest: attest, transport: relayTransport)
            let mgr = PushRegistrationManager(
                keychain: kc,
                registerCall: { req, _, _ in
                    PushDeviceRegisterResponse(
                        deviceID: req.deviceID,
                        bindingID: req.bindingID ?? UUID().uuidString.lowercased(),
                        enabled: true,
                        registrationVersion: 1,
                        apnsEnv: req.apnsEnv,
                        inboxContractVersion: 2
                    )
                },
                deleteCall: { _, _, _, _ in },
                cancelAttemptCall: { _, _, _, _ in },
                fetchPreferencesCall: { url, _ in
                    if url == secondServerURL {
                        return self.makePreferences(apnsPushEnabled: false, apnsPushConfigured: false, apnsTransportMode: "none")
                    }
                    return self.makePreferences(
                        apnsPushEnabled: true,
                        apnsPushConfigured: true,
                        apnsTransportMode: "relay",
                        apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                    )
                },
                relayCoordinator: coordinator,
                configSnapshot: {
                    SyncConfiguration(
                        endpoint: currentServerURL,
                        apiKey: self.apiKey,
                        fingerprint: UserDefaultsSyncConfiguration.fingerprint(endpoint: currentServerURL, apiKey: self.apiKey),
                        metricGroups: [.vitals],
                        workoutsEnabled: true,
                        backgroundEnabled: true,
                        syncOnLaunch: true,
                        interval: 900,
                        workoutHRTimeline: true
                    )
                },
                isPushEnabled: { pushEnabled },
                resolveAPNsEnv: { "production" },
                resetBadge: {}
            )

            await mgr.syncRegistration(tokenHex: tokenA)
            XCTAssertEqual(mgr.loadActiveRegistration()?.relayGrantID, initialGrantID)

            // Start token rotation (A -> B) and pause while PUT /v1/attest/token is in flight.
            let rotationTask = Task {
                await mgr.syncRegistration(tokenHex: tokenB)
            }
            await withCheckedContinuation { cont in
                if releaseRotation != nil {
                    cont.resume()
                } else {
                    rotationStarted = cont
                }
            }

            // While PUT /v1/attest/token is suspended, disable pushes OR switch profile.
            if switchProfile {
                currentServerURL = secondServerURL
                await mgr.handleConfigurationChanged(pushEnabled: true)
            } else {
                pushEnabled = false
                await mgr.disablePushNotifications()
            }

            // Release late 200 response from Relay -> MUST NOT resurrect old registration in Keychain!
            releaseRotation?.resume(returning: (200, Data(#"{"updated":1,"active_grant_ids":["\#(initialGrantID)"]}"#.utf8)))
            releaseRotation = nil
            await rotationTask.value

            XCTAssertNil(mgr.loadActiveRegistration(), "Late token rotation response resurrected stale registration (switchProfile=\(switchProfile))")
        }
    }

    func testLateGrantRefreshResponseCannotResurrectDisabledOrSwitchedProfile() async {
        for switchProfile in [false, true] {
            let kc = InMemoryRelayKeychain()
            let attest = MockAppAttestProvider()
            let relayTransport = MockRelayHTTPTransport()
            let initialGrantID = UUID().uuidString.lowercased()
            let secondServerURL = URL(string: "https://second-refresh.example.com")!
            var currentServerURL = serverURL
            var pushEnabled = true
            var currentNow = Date(timeIntervalSince1970: 1_800_000_000)

            var refreshStarted: CheckedContinuation<Void, Never>?
            var releaseRefresh: CheckedContinuation<(Int, Data), Error>?

            relayTransport.handler = { method, url, _, _ in
                let path = url.path
                if path.hasSuffix("/v1/attest/challenge") {
                    let data = try JSONEncoder().encode(RelayChallengeResponse(
                        challengeID: UUID().uuidString.lowercased(),
                        nonce: "nonce-\(UUID().uuidString)",
                        expiresAt: nil
                    ))
                    return (200, data)
                }
                if path.hasSuffix("/v1/attest/register") {
                    return (200, Data(#"{"key_id":"ok"}"#.utf8))
                }
                if method == "POST", path.hasSuffix("/v1/grants") {
                    let resp = try JSONEncoder().encode(RelayGrantCreateResponse(
                        grantID: initialGrantID,
                        expiresAt: nil,
                        tokenHash: RelayGrantCoordinator.sha256Hex(self.tokenA)
                    ))
                    return (200, resp)
                }
                if method == "PUT", path.hasSuffix("/refresh") {
                    return try await withCheckedThrowingContinuation { cont in
                        releaseRefresh = cont
                        refreshStarted?.resume()
                        refreshStarted = nil
                    }
                }
                if method == "DELETE" {
                    return (200, Data(#"{"revoked":true}"#.utf8))
                }
                return (404, Data())
            }

            let coordinator = RelayGrantCoordinator(keychain: kc, appAttest: attest, transport: relayTransport, now: { currentNow })
            let mgr = PushRegistrationManager(
                keychain: kc,
                registerCall: { req, _, _ in
                    PushDeviceRegisterResponse(
                        deviceID: req.deviceID,
                        bindingID: req.bindingID ?? UUID().uuidString.lowercased(),
                        enabled: true,
                        registrationVersion: 1,
                        apnsEnv: req.apnsEnv,
                        inboxContractVersion: 2
                    )
                },
                deleteCall: { _, _, _, _ in },
                cancelAttemptCall: { _, _, _, _ in },
                fetchPreferencesCall: { url, _ in
                    if url == secondServerURL {
                        return self.makePreferences(apnsPushEnabled: false, apnsPushConfigured: false, apnsTransportMode: "none")
                    }
                    return self.makePreferences(
                        apnsPushEnabled: true,
                        apnsPushConfigured: true,
                        apnsTransportMode: "relay",
                        apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                    )
                },
                relayCoordinator: coordinator,
                configSnapshot: {
                    SyncConfiguration(
                        endpoint: currentServerURL,
                        apiKey: self.apiKey,
                        fingerprint: UserDefaultsSyncConfiguration.fingerprint(endpoint: currentServerURL, apiKey: self.apiKey),
                        metricGroups: [.vitals],
                        workoutsEnabled: true,
                        backgroundEnabled: true,
                        syncOnLaunch: true,
                        interval: 900,
                        workoutHRTimeline: true
                    )
                },
                isPushEnabled: { pushEnabled },
                resolveAPNsEnv: { "production" },
                now: { currentNow },
                resetBadge: {}
            )

            await mgr.syncRegistration(tokenHex: tokenA)
            XCTAssertEqual(mgr.loadActiveRegistration()?.relayGrantID, initialGrantID)

            // Advance 8 days to trigger grant refresh.
            currentNow = currentNow.addingTimeInterval(8 * 24 * 60 * 60)
            let refreshTask = Task {
                await mgr.syncRegistration(tokenHex: tokenA)
            }
            await withCheckedContinuation { cont in
                if releaseRefresh != nil {
                    cont.resume()
                } else {
                    refreshStarted = cont
                }
            }

            if switchProfile {
                currentServerURL = secondServerURL
                await mgr.handleConfigurationChanged(pushEnabled: true)
            } else {
                pushEnabled = false
                await mgr.disablePushNotifications()
            }

            releaseRefresh?.resume(returning: (200, Data(#"{"grant_id":"\#(initialGrantID)"}"#.utf8)))
            releaseRefresh = nil
            await refreshTask.value

            XCTAssertNil(mgr.loadActiveRegistration(), "Late grant refresh response resurrected stale registration (switchProfile=\(switchProfile))")
        }
    }

    func testExpiredOrInvalidatedGrantDuringRefreshMintsFreshGrantAndReregisters() async {
        let kc = InMemoryRelayKeychain()
        let attest = MockAppAttestProvider()
        let relayTransport = MockRelayHTTPTransport()
        let oldGrantID = UUID().uuidString.lowercased()
        let newGrantID = UUID().uuidString.lowercased()
        var currentNow = Date(timeIntervalSince1970: 1_800_000_000)
        var grantCreates = 0

        relayTransport.handler = { method, url, _, _ in
            let path = url.path
            if path.hasSuffix("/v1/attest/challenge") {
                let data = try JSONEncoder().encode(RelayChallengeResponse(
                    challengeID: UUID().uuidString.lowercased(),
                    nonce: "nonce-\(UUID().uuidString)",
                    expiresAt: nil
                ))
                return (200, data)
            }
            if path.hasSuffix("/v1/attest/register") {
                return (200, Data(#"{"key_id":"ok"}"#.utf8))
            }
            if method == "POST", path.hasSuffix("/v1/grants") {
                grantCreates += 1
                let gid = grantCreates == 1 ? oldGrantID : newGrantID
                let resp = try JSONEncoder().encode(RelayGrantCreateResponse(
                    grantID: gid,
                    expiresAt: nil,
                    tokenHash: RelayGrantCoordinator.sha256Hex(self.tokenA)
                ))
                return (200, resp)
            }
            if method == "PUT", path.hasSuffix("/v1/grants/\(oldGrantID)/refresh") {
                return (410, Data(#"{"error":"grant expired, revoked, or invalidated"}"#.utf8))
            }
            return (404, Data())
        }

        let coordinator = RelayGrantCoordinator(keychain: kc, appAttest: attest, transport: relayTransport, now: { currentNow })
        var serverRegs: [PushDeviceRegisterRequest] = []
        let mgr = PushRegistrationManager(
            keychain: kc,
            registerCall: { req, _, _ in
                serverRegs.append(req)
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: req.bindingID ?? UUID().uuidString.lowercased(),
                    enabled: true,
                    registrationVersion: Int64(serverRegs.count),
                    apnsEnv: req.apnsEnv,
                    inboxContractVersion: 2
                )
            },
            deleteCall: { _, _, _, _ in },
            cancelAttemptCall: { _, _, _, _ in },
            fetchPreferencesCall: { _, _ in
                self.makePreferences(
                    apnsPushEnabled: true,
                    apnsPushConfigured: true,
                    apnsTransportMode: "relay",
                    apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                )
            },
            relayCoordinator: coordinator,
            configSnapshot: { self.makeConfig() },
            isPushEnabled: { true },
            resolveAPNsEnv: { "production" },
            now: { currentNow },
            resetBadge: {}
        )

        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(mgr.loadActiveRegistration()?.relayGrantID, oldGrantID)
        XCTAssertEqual(serverRegs.count, 1)

        // Advance 8 days -> refresh returns 410 Gone -> iOS must mint newGrantID and re-register on self-hosted server.
        currentNow = currentNow.addingTimeInterval(8 * 24 * 60 * 60)
        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(grantCreates, 2)
        XCTAssertEqual(serverRegs.count, 2)
        XCTAssertEqual(serverRegs[1].relayGrantID, newGrantID)
        XCTAssertNotEqual(serverRegs[1].bindingID, serverRegs[0].bindingID)
        XCTAssertEqual(mgr.loadActiveRegistration()?.relayGrantID, newGrantID)
    }

    func testTokenRotationWithUpdatedZeroMintsFreshGrantAndReregisters() async {
        for includeActiveIDsField in [true, false] {
            let kc = InMemoryRelayKeychain()
            let attest = MockAppAttestProvider()
            let relayTransport = MockRelayHTTPTransport()
            let oldGrantID = UUID().uuidString.lowercased()
            let newGrantID = UUID().uuidString.lowercased()
            var grantCreates = 0

            relayTransport.handler = { method, url, body, _ in
                let path = url.path
                if path.hasSuffix("/v1/attest/challenge") {
                    let data = try JSONEncoder().encode(RelayChallengeResponse(
                        challengeID: UUID().uuidString.lowercased(),
                        nonce: "nonce-\(UUID().uuidString)",
                        expiresAt: nil
                    ))
                    return (200, data)
                }
                if path.hasSuffix("/v1/attest/register") {
                    return (200, Data(#"{"key_id":"ok"}"#.utf8))
                }
                if method == "POST", path.hasSuffix("/v1/grants") {
                    grantCreates += 1
                    let gid = grantCreates == 1 ? oldGrantID : newGrantID
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let tok = (json?["apns_token"] as? String) ?? self.tokenA
                    let resp = try JSONEncoder().encode(RelayGrantCreateResponse(
                        grantID: gid,
                        expiresAt: nil,
                        tokenHash: RelayGrantCoordinator.sha256Hex(tok)
                    ))
                    return (200, resp)
                }
                if method == "PUT", path.hasSuffix("/v1/attest/token") {
                    if includeActiveIDsField {
                        return (200, Data(#"{"updated":0,"active_grant_ids":[]}"#.utf8))
                    }
                    return (200, Data(#"{"updated":0}"#.utf8))
                }
                return (404, Data())
            }

            let coordinator = RelayGrantCoordinator(keychain: kc, appAttest: attest, transport: relayTransport)
            var serverRegs: [PushDeviceRegisterRequest] = []
            let mgr = PushRegistrationManager(
                keychain: kc,
                registerCall: { req, _, _ in
                    serverRegs.append(req)
                    return PushDeviceRegisterResponse(
                        deviceID: req.deviceID,
                        bindingID: req.bindingID ?? UUID().uuidString.lowercased(),
                        enabled: true,
                        registrationVersion: Int64(serverRegs.count),
                        apnsEnv: req.apnsEnv,
                        inboxContractVersion: 2
                    )
                },
                deleteCall: { _, _, _, _ in },
                cancelAttemptCall: { _, _, _, _ in },
                fetchPreferencesCall: { _, _ in
                    self.makePreferences(
                        apnsPushEnabled: true,
                        apnsPushConfigured: true,
                        apnsTransportMode: "relay",
                        apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                    )
                },
                relayCoordinator: coordinator,
                configSnapshot: { self.makeConfig() },
                isPushEnabled: { true },
                resolveAPNsEnv: { "production" },
                resetBadge: {}
            )

            await mgr.syncRegistration(tokenHex: tokenA)
            XCTAssertEqual(mgr.loadActiveRegistration()?.relayGrantID, oldGrantID)

            // Rotating token A -> B receives updated: 0 (grant dead on Relay) -> iOS must mint newGrantID and re-register!
            await mgr.syncRegistration(tokenHex: tokenB)
            XCTAssertEqual(grantCreates, 2, "Expected fresh grant mint on updated=0 (includeActiveIDsField=\(includeActiveIDsField))")
            XCTAssertEqual(serverRegs.count, 2)
            XCTAssertEqual(serverRegs[1].relayGrantID, newGrantID)
            XCTAssertEqual(mgr.loadActiveRegistration()?.relayGrantID, newGrantID)
        }
    }

    func testRelayGrantRecoveryWithTokenRotationBeforeRetryConfirmsLatestTokenOnRelay() async {
        // Case A: First POST /v1/grants commits token A on Relay, response is lost,
        // iPhone rotates to token B before retry, and Relay replay still reports stale token A
        // -> iOS MUST explicitly refresh the grant with token B before saving ActivePushRegistration!
        do {
            let kc = InMemoryRelayKeychain()
            let attest = MockAppAttestProvider()
            let relayTransport = MockRelayHTTPTransport()
            let grantID = UUID().uuidString.lowercased()
            var createCalls = 0
            var relayActiveToken = ""
            var refreshTokens: [String] = []

            relayTransport.handler = { method, url, body, _ in
                let path = url.path
                if path.hasSuffix("/v1/attest/challenge") {
                    let data = try JSONEncoder().encode(RelayChallengeResponse(
                        challengeID: UUID().uuidString.lowercased(),
                        nonce: "nonce-\(UUID().uuidString)",
                        expiresAt: nil
                    ))
                    return (200, data)
                }
                if path.hasSuffix("/v1/attest/register") {
                    return (200, Data(#"{"key_id":"ok"}"#.utf8))
                }
                if method == "POST", path.hasSuffix("/v1/grants") {
                    createCalls += 1
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let tok = (json?["apns_token"] as? String) ?? ""
                    if createCalls == 1 {
                        relayActiveToken = tok // committed token A, then network dropped
                        throw URLError(.networkConnectionLost)
                    }
                    // Simulate replay returning stale token_hash (token A) instead of B.
                    let resp = try JSONEncoder().encode(RelayGrantCreateResponse(
                        grantID: grantID,
                        expiresAt: nil,
                        tokenHash: RelayGrantCoordinator.sha256Hex(relayActiveToken)
                    ))
                    return (200, resp)
                }
                if method == "PUT", path.hasSuffix("/v1/grants/\(grantID)/refresh") {
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let tok = (json?["apns_token"] as? String) ?? ""
                    relayActiveToken = tok
                    refreshTokens.append(tok)
                    return (200, Data(#"{"grant_id":"\#(grantID)"}"#.utf8))
                }
                return (404, Data())
            }

            let coordinator = RelayGrantCoordinator(keychain: kc, appAttest: attest, transport: relayTransport)
            var serverPosts = 0
            let mgr = PushRegistrationManager(
                keychain: kc,
                registerCall: { req, _, _ in
                    serverPosts += 1
                    return PushDeviceRegisterResponse(
                        deviceID: req.deviceID,
                        bindingID: req.bindingID ?? UUID().uuidString.lowercased(),
                        enabled: true,
                        registrationVersion: 1,
                        apnsEnv: req.apnsEnv,
                        inboxContractVersion: 2
                    )
                },
                deleteCall: { _, _, _, _ in },
                cancelAttemptCall: { _, _, _, _ in },
                fetchPreferencesCall: { _, _ in
                    self.makePreferences(
                        apnsPushEnabled: true,
                        apnsPushConfigured: true,
                        apnsTransportMode: "relay",
                        apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                    )
                },
                relayCoordinator: coordinator,
                configSnapshot: { self.makeConfig() },
                isPushEnabled: { true },
                resolveAPNsEnv: { "production" },
                resetBadge: {}
            )

            // 1. Attempt with token A loses response after Relay commit.
            await mgr.syncRegistration(tokenHex: tokenA)
            XCTAssertEqual(relayActiveToken, tokenA)
            XCTAssertEqual(serverPosts, 0)

            // 2. Retry with rotated token B must confirm token B on Relay via refresh before saving registration!
            await mgr.syncRegistration(tokenHex: tokenB)
            XCTAssertEqual(relayActiveToken, tokenB)
            XCTAssertEqual(refreshTokens, [tokenB])
            XCTAssertEqual(serverPosts, 1)
            XCTAssertEqual(mgr.loadActiveRegistration()?.tokenHash, RelayGrantCoordinator.sha256Hex(tokenB))
        }

        // Case B: POST /v1/grants succeeds with token A, POST /api/push/devices fails,
        // token rotates to B before retry -> obtainGrant MUST refresh grant with token B before registering on server!
        do {
            let kc = InMemoryRelayKeychain()
            let attest = MockAppAttestProvider()
            let relayTransport = MockRelayHTTPTransport()
            let grantID = UUID().uuidString.lowercased()
            var relayActiveToken = ""
            var refreshTokens: [String] = []

            relayTransport.handler = { method, url, body, _ in
                let path = url.path
                if path.hasSuffix("/v1/attest/challenge") {
                    let data = try JSONEncoder().encode(RelayChallengeResponse(
                        challengeID: UUID().uuidString.lowercased(),
                        nonce: "nonce-\(UUID().uuidString)",
                        expiresAt: nil
                    ))
                    return (200, data)
                }
                if path.hasSuffix("/v1/attest/register") {
                    return (200, Data(#"{"key_id":"ok"}"#.utf8))
                }
                if method == "POST", path.hasSuffix("/v1/grants") {
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    relayActiveToken = (json?["apns_token"] as? String) ?? ""
                    let resp = try JSONEncoder().encode(RelayGrantCreateResponse(
                        grantID: grantID,
                        expiresAt: nil,
                        tokenHash: RelayGrantCoordinator.sha256Hex(relayActiveToken)
                    ))
                    return (200, resp)
                }
                if method == "PUT", path.hasSuffix("/v1/grants/\(grantID)/refresh") {
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let tok = (json?["apns_token"] as? String) ?? ""
                    relayActiveToken = tok
                    refreshTokens.append(tok)
                    return (200, Data(#"{"grant_id":"\#(grantID)"}"#.utf8))
                }
                return (404, Data())
            }

            let coordinator = RelayGrantCoordinator(keychain: kc, appAttest: attest, transport: relayTransport)
            var serverAttempts = 0
            let mgr = PushRegistrationManager(
                keychain: kc,
                registerCall: { req, _, _ in
                    serverAttempts += 1
                    if serverAttempts == 1 {
                        throw URLError(.timedOut)
                    }
                    return PushDeviceRegisterResponse(
                        deviceID: req.deviceID,
                        bindingID: req.bindingID ?? UUID().uuidString.lowercased(),
                        enabled: true,
                        registrationVersion: 1,
                        apnsEnv: req.apnsEnv,
                        inboxContractVersion: 2
                    )
                },
                deleteCall: { _, _, _, _ in },
                cancelAttemptCall: { _, _, _, _ in },
                fetchPreferencesCall: { _, _ in
                    self.makePreferences(
                        apnsPushEnabled: true,
                        apnsPushConfigured: true,
                        apnsTransportMode: "relay",
                        apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                    )
                },
                relayCoordinator: coordinator,
                configSnapshot: { self.makeConfig() },
                isPushEnabled: { true },
                resolveAPNsEnv: { "production" },
                resetBadge: {}
            )

            // 1. Grant created with token A, server POST fails.
            await mgr.syncRegistration(tokenHex: tokenA)
            XCTAssertEqual(relayActiveToken, tokenA)
            XCTAssertNil(mgr.loadActiveRegistration())

            // 2. Token rotates to B -> retry MUST refresh grant with token B on Relay!
            await mgr.syncRegistration(tokenHex: tokenB)
            XCTAssertEqual(relayActiveToken, tokenB)
            XCTAssertEqual(refreshTokens, [tokenB])
            XCTAssertEqual(mgr.loadActiveRegistration()?.tokenHash, RelayGrantCoordinator.sha256Hex(tokenB))
        }
    }

    func testKeychainFailureWritingRevocationQueuePreservesPendingAttemptUntilWriteSucceeds() async {
        let kc = InMemoryRelayKeychain()
        let attest = MockAppAttestProvider()
        let relayTransport = MockRelayHTTPTransport()
        var capturedClientGrantKey: String?
        var cancelledClientGrantKeys: [String] = []

        relayTransport.handler = { method, url, body, _ in
            let path = url.path
            if path.hasSuffix("/v1/attest/challenge") {
                let data = try JSONEncoder().encode(RelayChallengeResponse(
                    challengeID: UUID().uuidString.lowercased(),
                    nonce: "nonce-\(UUID().uuidString)",
                    expiresAt: nil
                ))
                return (200, data)
            }
            if path.hasSuffix("/v1/attest/register") {
                return (200, Data(#"{"key_id":"ok"}"#.utf8))
            }
            if method == "POST", path.hasSuffix("/v1/grants") {
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                capturedClientGrantKey = json?["client_grant_key"] as? String
                throw URLError(.timedOut)
            }
            if method == "DELETE", path.contains("/v1/grants/by-client-key/") {
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                if let resID = json?["resource_id"] as? String {
                    cancelledClientGrantKeys.append(resID)
                }
                return (200, Data(#"{"cancelled":true}"#.utf8))
            }
            return (404, Data())
        }

        let coordinator = RelayGrantCoordinator(keychain: kc, appAttest: attest, transport: relayTransport)
        var pushEnabled = true
        let mgr = PushRegistrationManager(
            keychain: kc,
            registerCall: { _, _, _ in throw ServerError.http(500, "unexpected") },
            deleteCall: { _, _, _, _ in },
            cancelAttemptCall: { _, _, _, _ in },
            fetchPreferencesCall: { _, _ in
                self.makePreferences(
                    apnsPushEnabled: true,
                    apnsPushConfigured: true,
                    apnsTransportMode: "relay",
                    apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                )
            },
            relayCoordinator: coordinator,
            configSnapshot: { self.makeConfig() },
            isPushEnabled: { pushEnabled },
            resolveAPNsEnv: { "production" },
            resetBadge: {}
        )

        // 1. POST /v1/grants times out -> pending attempt is persisted in Keychain.
        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertNotNil(capturedClientGrantKey)
        XCTAssertEqual(coordinator.loadPendingGrantAttempts().count, 1)

        // 2. Simulate Keychain write failure ONLY for pendingRevocationsAccount when user disables pushes.
        kc.failedWrites.insert(RelayPushConstants.pendingRevocationsAccount)
        pushEnabled = false
        await mgr.disablePushNotifications()

        // Pending attempt MUST STILL BE PRESERVED in Keychain because revocation queue write failed!
        XCTAssertEqual(coordinator.loadPendingGrantAttempts().count, 1)
        XCTAssertTrue(coordinator.loadPendingRevocations().isEmpty)
        XCTAssertTrue(cancelledClientGrantKeys.isEmpty)

        // 3. Keychain recovers -> next drain moves the attempt to revocation queue and cancels it on Relay!
        kc.failedWrites.remove(RelayPushConstants.pendingRevocationsAccount)
        await mgr.drainPendingDeregistrations()
        XCTAssertEqual(cancelledClientGrantKeys, [capturedClientGrantKey!])
        XCTAssertTrue(coordinator.loadPendingGrantAttempts().isEmpty)
        XCTAssertTrue(coordinator.loadPendingRevocations().isEmpty)
    }

    func testKeychainReadFailureDoesNotOverwriteExistingRevocationQueue() async throws {
        let kc = InMemoryRelayKeychain()
        let attest = MockAppAttestProvider()
        let relayTransport = MockRelayHTTPTransport()
        let coordinator = RelayGrantCoordinator(keychain: kc, appAttest: attest, transport: relayTransport)

        let existingGrantID = UUID().uuidString.lowercased()
        let secondGrantID = UUID().uuidString.lowercased()

        // 1. Persist an existing revocation in Keychain.
        try coordinator.enqueueGrantRevocation(
            grantID: existingGrantID,
            relayOrigin: RelayPushConstants.trustedProductionOrigin
        )
        XCTAssertEqual(coordinator.loadPendingRevocations().map(\.identifier), [existingGrantID])

        // 2. Simulate Keychain READ failure for pendingRevocationsAccount (while writes would succeed).
        // Appending a second revocation MUST throw and MUST NOT overwrite the existing revocation!
        kc.failedReads.insert(RelayPushConstants.pendingRevocationsAccount)
        XCTAssertThrowsError(
            try coordinator.enqueueGrantRevocation(
                grantID: secondGrantID,
                relayOrigin: RelayPushConstants.trustedProductionOrigin
            )
        )

        // 3. Keychain read recovers -> existingGrantID MUST still be intact, and now appending secondGrantID keeps BOTH!
        kc.failedReads.remove(RelayPushConstants.pendingRevocationsAccount)
        XCTAssertEqual(coordinator.loadPendingRevocations().map(\.identifier), [existingGrantID])

        try coordinator.enqueueGrantRevocation(
            grantID: secondGrantID,
            relayOrigin: RelayPushConstants.trustedProductionOrigin
        )
        XCTAssertEqual(coordinator.loadPendingRevocations().map(\.identifier), [existingGrantID, secondGrantID])
    }

    func testPendingGrantPastOrNearExpiryRefreshesOrReissuesBeforeServerRegistration() async {
        let kc = InMemoryRelayKeychain()
        let attest = MockAppAttestProvider()
        let relayTransport = MockRelayHTTPTransport()
        let oldGrantID = UUID().uuidString.lowercased()
        let newGrantID = UUID().uuidString.lowercased()
        var currentNow = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var grantCreateCount = 0
        var refreshCalls = 0

        relayTransport.handler = { method, url, body, _ in
            let path = url.path
            if path.hasSuffix("/v1/attest/challenge") {
                let data = try JSONEncoder().encode(RelayChallengeResponse(
                    challengeID: UUID().uuidString.lowercased(),
                    nonce: "nonce-\(UUID().uuidString)",
                    expiresAt: nil
                ))
                return (200, data)
            }
            if path.hasSuffix("/v1/attest/register") {
                return (200, Data(#"{"key_id":"ok"}"#.utf8))
            }
            if method == "POST", path.hasSuffix("/v1/grants") {
                grantCreateCount += 1
                let gid = grantCreateCount == 1 ? oldGrantID : newGrantID
                let expStr = iso.string(from: currentNow.addingTimeInterval(90 * 24 * 60 * 60))
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                let tok = (json?["apns_token"] as? String) ?? self.tokenA
                let resp = try JSONEncoder().encode(RelayGrantCreateResponse(
                    grantID: gid,
                    expiresAt: expStr,
                    tokenHash: RelayGrantCoordinator.sha256Hex(tok)
                ))
                return (200, resp)
            }
            if method == "PUT", path.hasSuffix("/v1/grants/\(oldGrantID)/refresh") {
                refreshCalls += 1
                // Old pending grant already expired on Relay while self-hosted server was unreachable.
                return (410, Data(#"{"error":"grant expired, revoked, or invalidated"}"#.utf8))
            }
            return (404, Data())
        }

        let coordinator = RelayGrantCoordinator(
            keychain: kc,
            appAttest: attest,
            transport: relayTransport,
            now: { currentNow }
        )
        var serverAttempts = 0
        var registeredGrantIDs: [String] = []
        let mgr = PushRegistrationManager(
            keychain: kc,
            registerCall: { req, _, _ in
                serverAttempts += 1
                if serverAttempts == 1 {
                    throw URLError(.cannotConnectToHost)
                }
                if let gid = req.relayGrantID {
                    registeredGrantIDs.append(gid)
                }
                return PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: req.bindingID ?? UUID().uuidString.lowercased(),
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv,
                    inboxContractVersion: 2
                )
            },
            deleteCall: { _, _, _, _ in },
            cancelAttemptCall: { _, _, _, _ in },
            fetchPreferencesCall: { _, _ in
                self.makePreferences(
                    apnsPushEnabled: true,
                    apnsPushConfigured: true,
                    apnsTransportMode: "relay",
                    apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                )
            },
            relayCoordinator: coordinator,
            configSnapshot: { self.makeConfig() },
            isPushEnabled: { true },
            resolveAPNsEnv: { "production" },
            now: { currentNow },
            resetBadge: {}
        )

        // 1. Relay mints oldGrantID (TTL 90d), but self-hosted server is unreachable.
        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(grantCreateCount, 1)
        XCTAssertNil(mgr.loadActiveRegistration())
        XCTAssertEqual(coordinator.loadPendingGrantAttempts().values.first?.confirmedGrantID, oldGrantID)

        // 2. 91 days pass with UNCHANGED tokenA -> oldGrantID is expired.
        // Retry MUST check expires_at, attempt refresh (gets 410), mint newGrantID, and register newGrantID on server!
        currentNow = currentNow.addingTimeInterval(91 * 24 * 60 * 60)
        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(grantCreateCount, 2)
        XCTAssertEqual(registeredGrantIDs, [newGrantID])
        XCTAssertEqual(mgr.loadActiveRegistration()?.relayGrantID, newGrantID)
    }

    func testAttestKeyReadFailureRetainsPendingRevocationAndSucceedsAfterRecovery() async {
        let kc = InMemoryRelayKeychain()
        let attest = MockAppAttestProvider()
        let relayTransport = MockRelayHTTPTransport()
        let grantID = UUID().uuidString.lowercased()
        var revokedGrantIDs: [String] = []

        relayTransport.handler = { method, url, body, _ in
            let path = url.path
            if path.hasSuffix("/v1/attest/challenge") {
                let data = try JSONEncoder().encode(RelayChallengeResponse(
                    challengeID: UUID().uuidString.lowercased(),
                    nonce: "nonce-\(UUID().uuidString)",
                    expiresAt: nil
                ))
                return (200, data)
            }
            if path.hasSuffix("/v1/attest/register") {
                return (200, Data(#"{"key_id":"ok"}"#.utf8))
            }
            if method == "POST", path.hasSuffix("/v1/grants") {
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                let tok = (json?["apns_token"] as? String) ?? self.tokenA
                let resp = try JSONEncoder().encode(RelayGrantCreateResponse(
                    grantID: grantID,
                    expiresAt: nil,
                    tokenHash: RelayGrantCoordinator.sha256Hex(tok)
                ))
                return (200, resp)
            }
            if method == "DELETE", path.hasSuffix("/v1/grants/\(grantID)") {
                revokedGrantIDs.append(grantID)
                return (200, Data(#"{"revoked":true}"#.utf8))
            }
            return (404, Data())
        }

        let coordinator = RelayGrantCoordinator(keychain: kc, appAttest: attest, transport: relayTransport)
        var pushEnabled = true
        let mgr = PushRegistrationManager(
            keychain: kc,
            registerCall: { req, _, _ in
                PushDeviceRegisterResponse(
                    deviceID: req.deviceID,
                    bindingID: req.bindingID ?? UUID().uuidString.lowercased(),
                    enabled: true,
                    registrationVersion: 1,
                    apnsEnv: req.apnsEnv,
                    inboxContractVersion: 2
                )
            },
            deleteCall: { _, _, _, _ in throw URLError(.cannotConnectToHost) },
            cancelAttemptCall: { _, _, _, _ in throw URLError(.cannotConnectToHost) },
            fetchPreferencesCall: { _, _ in
                self.makePreferences(
                    apnsPushEnabled: true,
                    apnsPushConfigured: true,
                    apnsTransportMode: "relay",
                    apnsRelayURL: RelayPushConstants.trustedProductionOrigin
                )
            },
            relayCoordinator: coordinator,
            configSnapshot: { self.makeConfig() },
            isPushEnabled: { pushEnabled },
            resolveAPNsEnv: { "production" },
            resetBadge: {}
        )

        // 1. Complete normal Relay registration.
        await mgr.syncRegistration(tokenHex: tokenA)
        XCTAssertEqual(mgr.loadActiveRegistration()?.relayGrantID, grantID)

        // 2. Simulate transient Keychain read failure for attestKeyAccount when user disables pushes
        // (while self-hosted server is also unreachable). Revocation MUST stay queued, not be dropped!
        kc.failedReads.insert(RelayPushConstants.attestKeyAccount)
        pushEnabled = false
        await mgr.disablePushNotifications()
        XCTAssertTrue(revokedGrantIDs.isEmpty)
        XCTAssertEqual(coordinator.loadPendingRevocations().map(\.identifier), [grantID])

        // 3. Keychain access to App Attest key recovers -> drain retries and completes DELETE on Relay!
        kc.failedReads.remove(RelayPushConstants.attestKeyAccount)
        await mgr.drainPendingDeregistrations()
        XCTAssertEqual(revokedGrantIDs, [grantID])
        XCTAssertTrue(coordinator.loadPendingRevocations().isEmpty)
    }
}
