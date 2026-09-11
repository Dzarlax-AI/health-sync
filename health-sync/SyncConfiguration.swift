import CryptoKit
import Foundation

@MainActor
final class UserDefaultsSyncConfiguration: SyncConfigurationProviding {
    static let shared = UserDefaultsSyncConfiguration()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func snapshot() throws -> SyncConfiguration {
        let rawURL = defaults.string(forKey: "serverURL") ?? ""
        let key = KeychainStore.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let endpoint = Self.normalizedEndpoint(rawURL), !key.isEmpty else {
            throw SyncTransportError.configuration
        }

        var groups = Set<MetricGroup>()
        if bool("syncVitals", defaultValue: true) { groups.insert(.vitals) }
        if bool("syncActivity", defaultValue: true) { groups.insert(.activity) }
        if bool("syncSleep", defaultValue: true) { groups.insert(.sleep) }
        if bool("syncOther", defaultValue: true) { groups.insert(.other) }
        let storedMinutes = defaults.object(forKey: "syncIntervalMinutes") as? Int
        let minutes = max(1, storedMinutes ?? 15)
        return SyncConfiguration(
            endpoint: endpoint,
            apiKey: key,
            fingerprint: Self.fingerprint(endpoint: endpoint, apiKey: key),
            metricGroups: groups,
            workoutsEnabled: bool("syncWorkouts", defaultValue: true),
            backgroundEnabled: bool("backgroundSync", defaultValue: true),
            syncOnLaunch: bool("syncOnLaunch", defaultValue: true),
            interval: TimeInterval(minutes * 60),
            workoutHRTimeline: bool("workoutHRTimeline", defaultValue: true)
        )
    }

    private func bool(_ key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    static func normalizedEndpoint(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        if components.path == "/" { components.path = "" }
        return components.url
    }

    static func fingerprint(endpoint: URL, apiKey: String) -> String {
        func append(_ value: String, to data: inout Data) {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        var input = Data()
        append(endpoint.absoluteString, to: &input)
        append(apiKey, to: &input)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

enum SyncRuntime {
    static var isTestMode: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil ||
            env["XCTestBundlePath"] != nil ||
            ProcessInfo.processInfo.arguments.contains("--ui-test-mode") ||
            env["HEALTH_SYNC_TEST_MODE"] == "1" ||
            UserDefaults.standard.bool(forKey: "health-sync.test-mode")
    }

    static var uiFixture: SyncStatus? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--sync-ui-fixture"), args.indices.contains(index + 1) else { return nil }
        switch args[index + 1] {
        case "not-configured": return .notConfigured
        case "no-data": return .noData
        case "accepted": return .accepted
        case "partial": return .partial
        case "retry-pending": return .retryPending
        default: return nil
        }
    }
}
