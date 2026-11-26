import CryptoKit
import DeviceCheck
import Foundation
import Security

enum RelayPushConstants {
    static let trustedProductionOrigin = "https://push.dzarlax.dev"
    static let appID = "health_sync"
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    static let attestKeyAccount = "health-sync.push.relay.attest-key"
    static let pendingGrantAttemptsAccount = "health-sync.push.relay.pending-grant-attempts"
    static let pendingRevocationsAccount = "health-sync.push.relay.pending-revocations"

    static let opAttestRegister = "attest.register"
    static let opGrantCreate = "grant.create"
    static let opGrantRefresh = "grant.refresh"
    static let opGrantRevoke = "grant.revoke"
    static let opGrantCancelByClientKey = "grant.cancel_by_client_key"
    static let opDeviceUpdateToken = "device.update_token"
}

enum RelayPushError: Error, Equatable, LocalizedError {
    case untrustedRelayOrigin
    case redirectForbidden
    case appAttestUnsupported
    case http(Int, String)
    case invalidResponse
    case secretGenerationFailed

    var isTerminalGrantError: Bool {
        switch self {
        case .http(let code, _):
            return code == 404 || code == 409 || code == 410
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .untrustedRelayOrigin:
            return String(localized: "Untrusted push relay configuration")
        case .redirectForbidden:
            return String(localized: "Redirects are not allowed for APNs relay requests")
        case .appAttestUnsupported:
            return String(localized: "App Attest is not supported on this device")
        case .http(let code, let message):
            return message.isEmpty ? "Relay HTTP \(code)" : "Relay HTTP \(code): \(message)"
        case .invalidResponse:
            return "Invalid APNs relay response"
        case .secretGenerationFailed:
            return "Failed to generate delivery secret"
        }
    }
}

enum RelayOriginValidator {
    /// Verifies exact origin equality (`scheme + host + port`, no userinfo,
    /// query, fragment, or path) against the pinned trusted Relay origin(s).
    static func validatedOrigin(
        _ rawURL: String?,
        trustedOrigins: Set<String> = [RelayPushConstants.trustedProductionOrigin]
    ) -> URL? {
        guard let raw = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            return nil
        }
        let portSuffix: String
        if let port = components.port, port != 443 {
            portSuffix = ":\(port)"
        } else {
            portSuffix = ""
        }
        let normalized = "\(scheme)://\(host)\(portSuffix)"
        guard trustedOrigins.contains(normalized) else {
            return nil
        }
        return URL(string: normalized)
    }
}

struct RelayChallengeResponse: Codable, Equatable, Sendable {
    let challengeID: String
    let nonce: String
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case nonce
        case expiresAt = "expires_at"
    }
}

struct RelayGrantCreateResponse: Codable, Equatable, Sendable {
    let grantID: String
    let expiresAt: String?
    let tokenHash: String?

    enum CodingKeys: String, CodingKey {
        case grantID = "grant_id"
        case expiresAt = "expires_at"
        case tokenHash = "token_hash"
    }

    init(grantID: String, expiresAt: String? = nil, tokenHash: String? = nil) {
        self.grantID = grantID
        self.expiresAt = expiresAt
        self.tokenHash = tokenHash
    }
}

struct RelayUpdateDeviceTokenResponse: Decodable, Equatable, Sendable {
    let updated: Int
    let activeGrantIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case updated
        case activeGrantIDs = "active_grant_ids"
    }

    func confirmsGrantActive(_ grantID: String) -> Bool {
        if let activeGrantIDs {
            return activeGrantIDs.contains { $0.caseInsensitiveCompare(grantID) == .orderedSame }
        }
        return updated > 0
    }
}

struct StoredRelayAttestKey: Codable, Equatable {
    let keyID: String
    let relayOrigin: String
    var registered: Bool
}

struct PendingRelayGrantAttempt: Codable, Equatable {
    let clientGrantKey: UUID
    let regID: UUID
    let deliverySecret: String
    let endpointFingerprint: String
    let relayOrigin: String
    let apnsEnv: String
    let inboxContractVersion: Int
    let createdAt: Date
    var confirmedGrantID: String?
    var confirmedTokenHash: String? = nil
    var confirmedExpiresAt: Date? = nil
    var attestKeyID: String? = nil
}

struct PendingRelayRevocation: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case grantID
        case clientGrantKey
    }

    let kind: Kind
    let identifier: String
    let relayOrigin: String
    let queuedAt: Date
    var attestKeyID: String? = nil
}

protocol AppAttestProviding: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

struct AppleAppAttestProvider: AppAttestProviding {
    var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    func generateKey() async throws -> String {
        guard isSupported else { throw RelayPushError.appAttestUnsupported }
        return try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateKey { keyID, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let keyID {
                    continuation.resume(returning: keyID)
                } else {
                    continuation.resume(throwing: RelayPushError.appAttestUnsupported)
                }
            }
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        guard isSupported else { throw RelayPushError.appAttestUnsupported }
        return try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: RelayPushError.appAttestUnsupported)
                }
            }
        }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        guard isSupported else { throw RelayPushError.appAttestUnsupported }
        return try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: RelayPushError.appAttestUnsupported)
                }
            }
        }
    }
}

protocol RelayHTTPTransport: Sendable {
    func send(
        method: String,
        url: URL,
        body: Data,
        headers: [String: String]
    ) async throws -> (Int, Data)
}

/// URLSession transport that strictly refuses all HTTP redirects so App Attest
/// assertions, device tokens, and grant secrets can never be redirected.
final class NoRedirectRelayHTTPTransport: NSObject, RelayHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func send(
        method: String,
        url: URL,
        body: Data,
        headers: [String: String]
    ) async throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RelayPushError.invalidResponse
        }
        if (300...399).contains(http.statusCode) {
            throw RelayPushError.redirectForbidden
        }
        return (http.statusCode, data)
    }
}

@MainActor
final class RelayGrantCoordinator {
    private let store: PushKeychainStorage
    private let appAttest: AppAttestProviding
    private let transport: RelayHTTPTransport
    private let trustedOrigins: Set<String>
    private let now: () -> Date
    private var keyRegistrationTasks: [String: Task<String, Error>] = [:]

    init(
        keychain: KeychainAccess? = nil,
        appAttest: AppAttestProviding = AppleAppAttestProvider(),
        transport: RelayHTTPTransport = NoRedirectRelayHTTPTransport(),
        trustedOrigins: Set<String> = [RelayPushConstants.trustedProductionOrigin],
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = PushKeychainStorage(access: keychain ?? PushSystemKeychainAccess())
        self.appAttest = appAttest
        self.transport = transport
        self.trustedOrigins = trustedOrigins
        self.now = now
    }

    func validateOrigin(_ rawURL: String?) -> URL? {
        RelayOriginValidator.validatedOrigin(rawURL, trustedOrigins: trustedOrigins)
    }

    var isAppAttestSupported: Bool {
        appAttest.isSupported
    }

    func loadPendingGrantAttempts() -> [String: PendingRelayGrantAttempt] {
        (try? readPendingGrantAttempts()) ?? [:]
    }

    func loadPendingRevocations() -> [PendingRelayRevocation] {
        (try? readPendingRevocations()) ?? []
    }

    private func readPendingGrantAttempts() throws -> [String: PendingRelayGrantAttempt] {
        guard let data = try store.readData(account: RelayPushConstants.pendingGrantAttemptsAccount) else {
            return [:]
        }
        return try JSONDecoder().decode([String: PendingRelayGrantAttempt].self, from: data)
    }

    private func readPendingRevocations() throws -> [PendingRelayRevocation] {
        guard let data = try store.readData(account: RelayPushConstants.pendingRevocationsAccount) else {
            return []
        }
        return try JSONDecoder().decode([PendingRelayRevocation].self, from: data)
    }

    private func savePendingGrantAttempts(_ attempts: [String: PendingRelayGrantAttempt]) throws {
        let data = attempts.isEmpty ? nil : try JSONEncoder().encode(attempts)
        try store.writeData(data, account: RelayPushConstants.pendingGrantAttemptsAccount)
    }

    private func savePendingRevocations(_ list: [PendingRelayRevocation]) throws {
        let data = list.isEmpty ? nil : try JSONEncoder().encode(list)
        try store.writeData(data, account: RelayPushConstants.pendingRevocationsAccount)
    }

    private func readAttestKey() throws -> StoredRelayAttestKey? {
        guard let data = try store.readData(account: RelayPushConstants.attestKeyAccount) else {
            return nil
        }
        return try JSONDecoder().decode(StoredRelayAttestKey.self, from: data)
    }

    private func saveAttestKey(_ key: StoredRelayAttestKey?) throws {
        let data = try key.map { try JSONEncoder().encode($0) }
        try store.writeData(data, account: RelayPushConstants.attestKeyAccount)
    }

    func enqueueGrantRevocation(grantID: String, relayOrigin: String, attestKeyID: String? = nil) throws {
        let entry = PendingRelayRevocation(
            kind: .grantID,
            identifier: grantID,
            relayOrigin: relayOrigin,
            queuedAt: now(),
            attestKeyID: attestKeyID
        )
        try enqueueRevocationEntry(entry)
    }

    func enqueueClientGrantKeyCancellation(clientGrantKey: UUID, relayOrigin: String, attestKeyID: String? = nil) throws {
        let entry = PendingRelayRevocation(
            kind: .clientGrantKey,
            identifier: clientGrantKey.uuidString.lowercased(),
            relayOrigin: relayOrigin,
            queuedAt: now(),
            attestKeyID: attestKeyID
        )
        try enqueueRevocationEntry(entry)
    }

    /// Cancels any unconfirmed pending grant attempt for `fingerprint` (e.g., when
    /// the user disables pushes or switches profiles after a lost POST /v1/grants
    /// response before `grant_id` was received). Preserves the original attempt in
    /// Keychain if reading or persisting the revocation queue fails.
    func movePendingGrantAttemptToRevocationQueue(forFingerprint fingerprint: String) {
        guard var attempts = try? readPendingGrantAttempts(),
              let pending = attempts[fingerprint] else { return }
        do {
            if let grantID = pending.confirmedGrantID, !grantID.isEmpty {
                try enqueueGrantRevocation(grantID: grantID, relayOrigin: pending.relayOrigin, attestKeyID: pending.attestKeyID)
            } else {
                try enqueueClientGrantKeyCancellation(clientGrantKey: pending.clientGrantKey, relayOrigin: pending.relayOrigin, attestKeyID: pending.attestKeyID)
            }
            attempts.removeValue(forKey: fingerprint)
            try? savePendingGrantAttempts(attempts)
        } catch {
            // Keep the pending attempt intact in Keychain so a later drain can
            // persist the revocation once Keychain becomes readable/writable again.
        }
    }

    func moveAllPendingGrantAttemptsToRevocationQueue(exceptFingerprint keepFingerprint: String? = nil) {
        guard var attempts = try? readPendingGrantAttempts() else { return }
        var changed = false
        for (fp, pending) in attempts where fp != keepFingerprint {
            do {
                if let grantID = pending.confirmedGrantID, !grantID.isEmpty {
                    try enqueueGrantRevocation(grantID: grantID, relayOrigin: pending.relayOrigin, attestKeyID: pending.attestKeyID)
                } else {
                    try enqueueClientGrantKeyCancellation(clientGrantKey: pending.clientGrantKey, relayOrigin: pending.relayOrigin, attestKeyID: pending.attestKeyID)
                }
                attempts.removeValue(forKey: fp)
                changed = true
            } catch {
                // Retain this pending attempt until the revocation queue read/write succeeds.
            }
        }
        if changed {
            try? savePendingGrantAttempts(attempts)
        }
    }

    func clearPendingGrantAttempt(forFingerprint fingerprint: String, clientGrantKey: UUID) {
        guard var attempts = try? readPendingGrantAttempts(),
              attempts[fingerprint]?.clientGrantKey == clientGrantKey else { return }
        attempts.removeValue(forKey: fingerprint)
        try? savePendingGrantAttempts(attempts)
    }

    /// Ensures a durable client-generated `delivery_secret` and `client_grant_key`
    /// exist in Keychain BEFORE the first `POST /v1/grants`, then creates or
    /// idempotently recovers the grant from the trusted Relay and guarantees that
    /// both `apnsToken` and the grant's validity (`expires_at`) are confirmed on
    /// Relay before returning.
    func obtainGrant(
        relayURL: URL,
        endpointFingerprint: String,
        apnsToken: String,
        apnsEnv: String,
        inboxContractVersion: Int
    ) async throws -> (attempt: PendingRelayGrantAttempt, grantID: String) {
        let keyID = try await ensureRegisteredAttestKey(relayURL: relayURL)
        let origin = relayURL.absoluteString
        let currentTokenHash = Self.sha256Hex(apnsToken)
        let currentNow = now()
        var attempts = try readPendingGrantAttempts()

        func makeFreshAttempt() throws -> PendingRelayGrantAttempt {
            let secret = try Self.generateDeliverySecret()
            let fresh = PendingRelayGrantAttempt(
                clientGrantKey: UUID(),
                regID: UUID(),
                deliverySecret: secret,
                endpointFingerprint: endpointFingerprint,
                relayOrigin: origin,
                apnsEnv: apnsEnv,
                inboxContractVersion: inboxContractVersion,
                createdAt: now(),
                confirmedGrantID: nil,
                confirmedTokenHash: nil,
                confirmedExpiresAt: nil,
                attestKeyID: keyID
            )
            attempts[endpointFingerprint] = fresh
            try savePendingGrantAttempts(attempts)
            return fresh
        }

        var attempt: PendingRelayGrantAttempt
        if let existing = attempts[endpointFingerprint],
           existing.relayOrigin == origin,
           existing.apnsEnv == apnsEnv,
           existing.inboxContractVersion == inboxContractVersion,
           existing.attestKeyID == nil || existing.attestKeyID == keyID {
            attempt = existing
        } else {
            if let old = attempts[endpointFingerprint] {
                if let gid = old.confirmedGrantID, !gid.isEmpty {
                    try enqueueGrantRevocation(grantID: gid, relayOrigin: old.relayOrigin, attestKeyID: old.attestKeyID)
                } else {
                    try enqueueClientGrantKeyCancellation(clientGrantKey: old.clientGrantKey, relayOrigin: old.relayOrigin, attestKeyID: old.attestKeyID)
                }
            }
            attempt = try makeFreshAttempt()
        }

        if let existingGrantID = attempt.confirmedGrantID, !existingGrantID.isEmpty {
            let tokenMismatch = attempt.confirmedTokenHash != currentTokenHash
            let nearOrPastExpiry: Bool
            if let exp = attempt.confirmedExpiresAt {
                nearOrPastExpiry = exp <= currentNow.addingTimeInterval(RelayPushConstants.refreshInterval)
            } else {
                nearOrPastExpiry = currentNow.timeIntervalSince(attempt.createdAt) >= RelayPushConstants.refreshInterval
            }

            if !tokenMismatch && !nearOrPastExpiry {
                return (attempt, existingGrantID)
            }

            do {
                let refreshedExp = try await refreshGrant(
                    relayURL: relayURL,
                    grantID: existingGrantID,
                    apnsToken: apnsToken,
                    inboxContractVersion: inboxContractVersion
                )
                attempt.confirmedTokenHash = currentTokenHash
                if let refreshedExp {
                    attempt.confirmedExpiresAt = refreshedExp
                }
                var latestAttempts = try readPendingGrantAttempts()
                if latestAttempts[endpointFingerprint]?.clientGrantKey == attempt.clientGrantKey {
                    latestAttempts[endpointFingerprint] = attempt
                    try savePendingGrantAttempts(latestAttempts)
                }
                return (attempt, existingGrantID)
            } catch let err as RelayPushError where err.isTerminalGrantError {
                // Pending grant expired, was revoked, or was invalidated while the
                // self-hosted server was unreachable: drop it and mint a fresh grant.
                attempts = try readPendingGrantAttempts()
                guard attempts[endpointFingerprint]?.clientGrantKey == attempt.clientGrantKey else {
                    throw CancellationError()
                }
                attempt = try makeFreshAttempt()
            }
        }

        let challenge = try await fetchChallenge(relayURL: relayURL, keyID: keyID, op: RelayPushConstants.opGrantCreate)
        let secretHash = Self.base64URL(Data(SHA256.hash(data: Data(attempt.deliverySecret.utf8))))
        let clientGrantKeyStr = attempt.clientGrantKey.uuidString.lowercased()
        let payload = RelayCreateGrantBody(
            appID: RelayPushConstants.appID,
            op: RelayPushConstants.opGrantCreate,
            resourceID: clientGrantKeyStr,
            challengeID: challenge.challengeID,
            nonce: challenge.nonce,
            clientGrantKey: clientGrantKeyStr,
            secretHash: secretHash,
            regID: attempt.regID.uuidString.lowercased(),
            inboxContractVersion: inboxContractVersion,
            apnsToken: apnsToken,
            apnsEnv: apnsEnv
        )
        let rawBody = try JSONEncoder().encode(payload)
        let assertion = try await appAttest.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: rawBody)))
        let url = relayURL.appendingPathComponent("v1/grants")
        let (status, data) = try await transport.send(
            method: "POST",
            url: url,
            body: rawBody,
            headers: [
                "X-App-Attest-Key-ID": keyID,
                "X-App-Attest-Assertion": assertion.base64EncodedString(),
            ]
        )
        if status == 409 {
            // Cancelled or conflicting client_grant_key: drop local pending attempt so next pass generates a fresh one.
            clearPendingGrantAttempt(forFingerprint: endpointFingerprint, clientGrantKey: attempt.clientGrantKey)
            throw RelayPushError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard (200...299).contains(status) else {
            throw RelayPushError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(RelayGrantCreateResponse.self, from: data)
        var updated = attempt
        updated.confirmedGrantID = decoded.grantID
        updated.confirmedExpiresAt = Self.parseISO8601Date(decoded.expiresAt)
        if let returnedHash = decoded.tokenHash?.lowercased(), returnedHash == currentTokenHash {
            updated.confirmedTokenHash = currentTokenHash
        } else {
            // Relay did not confirm the latest APNs token in the grant response
            // (e.g. older Relay replay or concurrent rotation): explicitly refresh
            // the grant with the latest token before confirming registration.
            let refreshedExp = try await refreshGrant(
                relayURL: relayURL,
                grantID: decoded.grantID,
                apnsToken: apnsToken,
                inboxContractVersion: inboxContractVersion
            )
            updated.confirmedTokenHash = currentTokenHash
            if let refreshedExp {
                updated.confirmedExpiresAt = refreshedExp
            }
        }
        var latestAttempts = try readPendingGrantAttempts()
        if latestAttempts[endpointFingerprint]?.clientGrantKey == attempt.clientGrantKey {
            latestAttempts[endpointFingerprint] = updated
            try savePendingGrantAttempts(latestAttempts)
        }
        return (updated, decoded.grantID)
    }

    func updateDeviceToken(relayURL: URL, apnsToken: String, apnsEnv: String) async throws -> RelayUpdateDeviceTokenResponse {
        let keyID = try await ensureRegisteredAttestKey(relayURL: relayURL)
        let challenge = try await fetchChallenge(relayURL: relayURL, keyID: keyID, op: RelayPushConstants.opDeviceUpdateToken)
        let payload = RelayUpdateDeviceTokenBody(
            appID: RelayPushConstants.appID,
            op: RelayPushConstants.opDeviceUpdateToken,
            resourceID: keyID,
            challengeID: challenge.challengeID,
            nonce: challenge.nonce,
            apnsToken: apnsToken,
            apnsEnv: apnsEnv
        )
        let rawBody = try JSONEncoder().encode(payload)
        let assertion = try await appAttest.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: rawBody)))
        let url = relayURL.appendingPathComponent("v1/attest/token")
        let (status, data) = try await transport.send(
            method: "PUT",
            url: url,
            body: rawBody,
            headers: [
                "X-App-Attest-Key-ID": keyID,
                "X-App-Attest-Assertion": assertion.base64EncodedString(),
            ]
        )
        guard (200...299).contains(status) else {
            throw RelayPushError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(RelayUpdateDeviceTokenResponse.self, from: data)
    }

    @discardableResult
    func refreshGrant(
        relayURL: URL,
        grantID: String,
        apnsToken: String?,
        inboxContractVersion: Int
    ) async throws -> Date? {
        let keyID = try await ensureRegisteredAttestKey(relayURL: relayURL)
        let challenge = try await fetchChallenge(relayURL: relayURL, keyID: keyID, op: RelayPushConstants.opGrantRefresh)
        let payload = RelayRefreshGrantBody(
            appID: RelayPushConstants.appID,
            op: RelayPushConstants.opGrantRefresh,
            resourceID: grantID,
            challengeID: challenge.challengeID,
            nonce: challenge.nonce,
            apnsToken: apnsToken,
            inboxContractVersion: inboxContractVersion
        )
        let rawBody = try JSONEncoder().encode(payload)
        let assertion = try await appAttest.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: rawBody)))
        let url = relayURL.appendingPathComponent("v1/grants/\(grantID)/refresh")
        let (status, data) = try await transport.send(
            method: "PUT",
            url: url,
            body: rawBody,
            headers: [
                "X-App-Attest-Key-ID": keyID,
                "X-App-Attest-Assertion": assertion.base64EncodedString(),
            ]
        )
        guard (200...299).contains(status) else {
            throw RelayPushError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        if let decoded = try? JSONDecoder().decode(RelayGrantCreateResponse.self, from: data) {
            return Self.parseISO8601Date(decoded.expiresAt)
        }
        return nil
    }

    func drainPendingRevocations(retainingGrantID: String? = nil) async {
        guard let snapshot = try? readPendingRevocations() else { return }
        for entry in snapshot {
            guard let relayURL = validateOrigin(entry.relayOrigin) else {
                removeRevocation(entry)
                continue
            }
            let maybeKey: StoredRelayAttestKey?
            do {
                maybeKey = try readAttestKey()
            } catch {
                // Transient Keychain read failure: keep the pending revocation intact
                // and retry once the App Attest key is readable again.
                continue
            }
            // A replacement key cannot revoke its predecessor's grants.
            guard let keyID = entry.attestKeyID ?? (maybeKey?.relayOrigin == entry.relayOrigin && maybeKey?.registered == true ? maybeKey?.keyID : nil)
            else { continue }
            do {
                let op: String
                let url: URL
                switch entry.kind {
                case .grantID:
                    op = RelayPushConstants.opGrantRevoke
                    url = relayURL.appendingPathComponent("v1/grants/\(entry.identifier)")
                case .clientGrantKey:
                    op = RelayPushConstants.opGrantCancelByClientKey
                    url = relayURL.appendingPathComponent("v1/grants/by-client-key/\(entry.identifier)")
                }
                let challenge = try await fetchChallenge(relayURL: relayURL, keyID: keyID, op: op)
                let payload = RelayRevokeBody(
                    appID: RelayPushConstants.appID,
                    op: op,
                    resourceID: entry.identifier,
                    challengeID: challenge.challengeID,
                    nonce: challenge.nonce
                )
                let rawBody = try JSONEncoder().encode(payload)
                let assertion = try await appAttest.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: rawBody)))
                let (status, _) = try await transport.send(
                    method: "DELETE",
                    url: url,
                    body: rawBody,
                    headers: [
                        "X-App-Attest-Key-ID": keyID,
                        "X-App-Attest-Assertion": assertion.base64EncodedString(),
                    ]
                )
                if ((200...299).contains(status) || status == 404 || status == 410),
                   entry.kind != .grantID || entry.identifier != retainingGrantID {
                    removeRevocation(entry)
                }
            } catch {
                // Retain revocation in Keychain until Relay confirms it.
            }
        }
    }

    private func enqueueRevocationEntry(_ entry: PendingRelayRevocation) throws {
        var list = try readPendingRevocations()
        if !list.contains(where: { $0.kind == entry.kind && $0.identifier == entry.identifier && $0.relayOrigin == entry.relayOrigin }) {
            list.append(entry)
            try savePendingRevocations(list)
        }
    }

    private func removeRevocation(_ entry: PendingRelayRevocation) {
        guard var list = try? readPendingRevocations() else { return }
        let before = list.count
        list.removeAll { $0.kind == entry.kind && $0.identifier == entry.identifier && $0.relayOrigin == entry.relayOrigin }
        if list.count != before {
            try? savePendingRevocations(list)
        }
    }

    func hasPendingGrantRevocation(grantID: String, relayOrigin: String) throws -> Bool {
        try readPendingRevocations().contains {
            $0.kind == .grantID && $0.identifier == grantID && $0.relayOrigin == relayOrigin
        }
    }

    private func ensureRegisteredAttestKey(relayURL: URL) async throws -> String {
        let origin = relayURL.absoluteString
        if let task = keyRegistrationTasks[origin] {
            return try await task.value
        }

        let task = Task { try await self.registerAttestKeyIfNeeded(relayURL: relayURL) }
        keyRegistrationTasks[origin] = task
        defer { keyRegistrationTasks.removeValue(forKey: origin) }
        return try await task.value
    }

    private func registerAttestKeyIfNeeded(relayURL: URL) async throws -> String {
        guard appAttest.isSupported else {
            throw RelayPushError.appAttestUnsupported
        }
        let origin = relayURL.absoluteString
        let existingKey = try readAttestKey()
        if let existing = existingKey, existing.relayOrigin == origin, existing.registered {
            return existing.keyID
        }

        let keyID: String
        if let existing = existingKey, existing.relayOrigin == origin {
            keyID = existing.keyID
        } else {
            keyID = try await appAttest.generateKey()
            try saveAttestKey(StoredRelayAttestKey(keyID: keyID, relayOrigin: origin, registered: false))
        }

        let challenge = try await fetchChallenge(relayURL: relayURL, keyID: nil, op: RelayPushConstants.opAttestRegister)
        let canonical = Self.canonicalRegisterPayload(
            appID: RelayPushConstants.appID,
            keyID: keyID,
            challengeID: challenge.challengeID,
            nonce: challenge.nonce
        )
        let clientDataHash = Data(SHA256.hash(data: canonical))
        let attestationObject: Data
        do {
            attestationObject = try await appAttest.attestKey(keyID, clientDataHash: clientDataHash)
        } catch {
            let deviceCheckError = error as NSError
            if deviceCheckError.domain == DCError.errorDomain,
               deviceCheckError.code == DCError.Code.invalidKey.rawValue,
               try readAttestKey()?.keyID == keyID {
                try saveAttestKey(nil)
            }
            throw error
        }
        let reqBody = RelayAttestRegisterBody(
            appID: RelayPushConstants.appID,
            keyID: keyID,
            challengeID: challenge.challengeID,
            attestationObject: attestationObject.base64EncodedString()
        )
        let rawBody = try JSONEncoder().encode(reqBody)
        let url = relayURL.appendingPathComponent("v1/attest/register")
        let (status, data) = try await transport.send(method: "POST", url: url, body: rawBody, headers: [:])
        guard (200...299).contains(status) || status == 409 else {
            throw RelayPushError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        try saveAttestKey(StoredRelayAttestKey(keyID: keyID, relayOrigin: origin, registered: true))
        return keyID
    }

    private func fetchChallenge(relayURL: URL, keyID: String?, op: String) async throws -> RelayChallengeResponse {
        let reqBody = RelayChallengeRequestBody(
            appID: RelayPushConstants.appID,
            keyID: keyID,
            op: op
        )
        let raw = try JSONEncoder().encode(reqBody)
        let url = relayURL.appendingPathComponent("v1/attest/challenge")
        let (status, data) = try await transport.send(method: "POST", url: url, body: raw, headers: [:])
        guard (200...299).contains(status) else {
            throw RelayPushError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(RelayChallengeResponse.self, from: data)
    }

    /// Matches Go `apnsrelay.CanonicalRegisterPayload` field order and JSON encoding.
    static func canonicalRegisterPayload(appID: String, keyID: String, challengeID: String, nonce: String) -> Data {
        struct Canonical: Encodable {
            let app_id: String
            let op: String
            let resource_id: String
            let challenge_id: String
            let nonce: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(Canonical(
            app_id: appID,
            op: RelayPushConstants.opAttestRegister,
            resource_id: keyID,
            challenge_id: challengeID,
            nonce: nonce
        ))) ?? Data()
    }

    private static func generateDeliverySecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RelayPushError.secretGenerationFailed
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func parseISO8601Date(_ raw: String?) -> Date? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractional.date(from: value) {
            return parsed
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: value)
    }
}

private struct RelayChallengeRequestBody: Encodable {
    let appID: String
    let keyID: String?
    let op: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case keyID = "key_id"
        case op
    }
}

private struct RelayAttestRegisterBody: Encodable {
    let appID: String
    let keyID: String
    let challengeID: String
    let attestationObject: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case keyID = "key_id"
        case challengeID = "challenge_id"
        case attestationObject = "attestation_object"
    }
}

private struct RelayCreateGrantBody: Encodable {
    let appID: String
    let op: String
    let resourceID: String
    let challengeID: String
    let nonce: String
    let clientGrantKey: String
    let secretHash: String
    let regID: String
    let inboxContractVersion: Int
    let apnsToken: String
    let apnsEnv: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case op
        case resourceID = "resource_id"
        case challengeID = "challenge_id"
        case nonce
        case clientGrantKey = "client_grant_key"
        case secretHash = "secret_hash"
        case regID = "reg_id"
        case inboxContractVersion = "inbox_contract_version"
        case apnsToken = "apns_token"
        case apnsEnv = "apns_env"
    }
}

private struct RelayRefreshGrantBody: Encodable {
    let appID: String
    let op: String
    let resourceID: String
    let challengeID: String
    let nonce: String
    let apnsToken: String?
    let inboxContractVersion: Int?

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case op
        case resourceID = "resource_id"
        case challengeID = "challenge_id"
        case nonce
        case apnsToken = "apns_token"
        case inboxContractVersion = "inbox_contract_version"
    }
}

private struct RelayUpdateDeviceTokenBody: Encodable {
    let appID: String
    let op: String
    let resourceID: String
    let challengeID: String
    let nonce: String
    let apnsToken: String
    let apnsEnv: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case op
        case resourceID = "resource_id"
        case challengeID = "challenge_id"
        case nonce
        case apnsToken = "apns_token"
        case apnsEnv = "apns_env"
    }
}

private struct RelayRevokeBody: Encodable {
    let appID: String
    let op: String
    let resourceID: String
    let challengeID: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case op
        case resourceID = "resource_id"
        case challengeID = "challenge_id"
        case nonce
    }
}
