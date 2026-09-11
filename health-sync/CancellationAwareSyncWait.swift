import Foundation

/// Waits for an existing sync task while allowing the caller to stop waiting.
/// Caller cancellation returns `.cancelled` and never cancels the underlying
/// task, which may still be completing work needed by another owner.
@MainActor
func waitForSyncTask(_ task: Task<SyncOutcome, Never>) async -> SyncOutcome {
    let gate = SyncWaitGate()

    return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { continuation in
            gate.register(continuation)

            // The cancellation handler can run before registration. This
            // second check closes that pre-cancellation window without
            // touching the underlying task.
            if Task.isCancelled {
                gate.resolve(.cancelled)
            }

            // An unstructured observer deliberately outlives this caller.
            // It only publishes the result to the gate and never cancels task.
            Task {
                gate.resolve(await task.value)
            }
        }
    }, onCancel: {
        gate.resolve(.cancelled)
    })
}

private nonisolated final class SyncWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SyncOutcome, Never>?
    private var pending: SyncOutcome?
    private var resolved = false

    nonisolated func register(_ continuation: CheckedContinuation<SyncOutcome, Never>) {
        let result: SyncOutcome?
        lock.lock()
        if let pending {
            self.pending = nil
            result = pending
        } else if resolved {
            result = .cancelled
        } else {
            self.continuation = continuation
            result = nil
        }
        lock.unlock()

        result.map { continuation.resume(returning: $0) }
    }

    nonisolated func resolve(_ result: SyncOutcome) {
        let continuation: CheckedContinuation<SyncOutcome, Never>?
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pending = result
        }
        lock.unlock()

        continuation?.resume(returning: result)
    }
}
