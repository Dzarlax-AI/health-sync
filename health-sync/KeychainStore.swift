import Foundation
import Security

enum APIKeyError: Error, Equatable {
    case locked
    case failure(OSStatus)
}

@MainActor
protocol KeychainAccess {
    func copy(_ query: [CFString: Any]) -> (OSStatus, Any?)
    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus
    func add(_ attributes: [CFString: Any]) -> OSStatus
    func delete(_ query: [CFString: Any]) -> OSStatus
}

@MainActor
private struct SystemKeychainAccess: KeychainAccess {
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
final class APIKeyStore {
    private let access: KeychainAccess
    // Preserve the existing item's identity during migration.
    private let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: "health-sync.api-key"]

    init(access: KeychainAccess) { self.access = access }

    func read() throws -> String? {
        let (status, result) = access.copy(query.merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 })
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw APIKeyError.failure(errSecDecode)
        }
        return value
    }

    func write(_ value: String) throws {
        guard !value.isEmpty else {
            let status = access.delete(query)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        let attributes: [CFString: Any] = [kSecValueData: Data(value.utf8),
                                         kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = access.update(query, attributes: attributes)
        if status == errSecItemNotFound { try check(access.add(query.merging(attributes) { $1 })) }
        else { try check(status) }
    }

    /// No delete/reinsert and no secret read. A failed update remains retryable.
    func migrateAccessibility() throws {
        let (status, result) = access.copy(query.merging([kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 })
        if status == errSecItemNotFound { return }
        try check(status)
        let attributes = result as? [CFString: Any]
        if attributes?[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String { return }
        try check(access.update(query, attributes: [kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]))
    }

    private func check(_ status: OSStatus) throws {
        if status == errSecInteractionNotAllowed { throw APIKeyError.locked }
        guard status == errSecSuccess else { throw APIKeyError.failure(status) }
    }
}

@MainActor
enum KeychainStore {
    static let shared = APIKeyStore(access: SystemKeychainAccess())
    /// Convenience for foreground display. Sync uses the throwing accessor.
    static var apiKey: String? { try? shared.read() }
}
