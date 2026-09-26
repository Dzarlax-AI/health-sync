import Foundation

/// Keeps optional server content independent of core charts and rejects late
/// responses after navigation, configuration changes, or a newer refresh.
@MainActor
@Observable
final class TodayInsightsController {
    private(set) var response: TodayInsightsResponse?
    private(set) var isStale = false
    private(set) var unavailable = false
    private var requestID = UUID()
    private var appliedContext: String?
    private var lastAttemptContext: String?
    private let loader: @MainActor () async throws -> TodayInsightsResponse
    private let context: @MainActor () throws -> String
    private let prepare: @MainActor () async -> Void
    private let sleep: @MainActor (Int) async throws -> Void

    init(loader: @escaping @MainActor () async throws -> TodayInsightsResponse = { try await ServerClient.shared.todayInsights() },
         context: @escaping @MainActor () throws -> String = { try ServerClient.shared.dashboardContext() },
         prepare: @escaping @MainActor () async -> Void = { await ServerClient.shared.refreshServerLang() },
         sleep: @escaping @MainActor (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.loader = loader
        self.context = context
        self.prepare = prepare
        self.sleep = sleep
    }

    func reset() {
        requestID = UUID()
        response = nil
        appliedContext = nil
        lastAttemptContext = nil
        isStale = false
        unavailable = false
    }

    func invalidateRequest() { requestID = UUID() }

    func refresh() async {
        let id = UUID()
        requestID = id
        await prepare()
        guard id == requestID, !Task.isCancelled else { return }
        lastAttemptContext = try? context()
        do {
            let requestedContext = try context()
            if appliedContext != requestedContext {
                response = nil
                isStale = false
            }
            let value = try await loader()
            guard id == requestID, !Task.isCancelled else { return }
            guard try context() == requestedContext else { reset(); return }
            response = value
            appliedContext = requestedContext
            isStale = false
            unavailable = false
        } catch {
            guard id == requestID, !Task.isCancelled else { return }
            if (try? context()) != appliedContext || Self.invalidatesContent(error) {
                response = nil
                appliedContext = nil
            }
            isStale = response != nil
            unavailable = true
        }
    }

    /// Runs only for a visible, active screen. Ready snapshots need no network
    /// polling; a lightweight context check still notices day/account changes.
    func run() async {
        await refresh()
        var attempts = 0
        while !Task.isCancelled {
            let delay = response.flatMap { Self.pollDelay($0, attempts: attempts) }
            do { try await sleep(delay ?? 60) } catch { return }
            guard !Task.isCancelled else { return }
            if (try? context()) != lastAttemptContext {
                reset()
                attempts = 0
                await refresh()
            } else if delay != nil || (response == nil && attempts < 10) {
                if response.map(Self.spendsBudget) ?? true { attempts += 1 }
                await refresh()
                if let response, !Self.spendsBudget(response) { attempts = 0 }
            }
        }
    }

    private static func spendsBudget(_ value: TodayInsightsResponse) -> Bool {
        if value.generation.slots?.contains(where: { ["cold", "generating", "failed"].contains($0.state) || !$0.freshForSnapshot }) == true { return true }
        return !["ready", "disabled"].contains(value.generation.state) || !value.generation.freshForSnapshot
    }

    static func pollDelay(_ value: TodayInsightsResponse, attempts: Int) -> Int? {
        let generation = value.generation
        let pending = generation.slots?.filter { ["cold", "generating", "failed"].contains($0.state) || !$0.freshForSnapshot } ?? []
        if generation.state == "disabled", pending.isEmpty { return 60 }
        guard attempts < 10 else { return nil }
        guard ["cold", "generating", "failed"].contains(generation.state)
                || !generation.freshForSnapshot || !pending.isEmpty else { return nil }
        // Honor the longest retry window. Never shorten a provider backoff.
        let retry = max(generation.retryAfterSeconds ?? 0, pending.compactMap(\.retryAfterSeconds).max() ?? 0)
        return max(60, retry)
    }

    private static func invalidatesContent(_ error: Error) -> Bool {
        guard let error = error as? ServerError else { return false }
        switch error {
        case .missingConfig, .configurationChanged, .redirected: return true
        case .http(let code, _): return code == 401 || code == 403
        default: return false
        }
    }
}
