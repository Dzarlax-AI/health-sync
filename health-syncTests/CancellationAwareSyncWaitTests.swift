import Testing
@testable import health_sync

@MainActor
struct CancellationAwareSyncWaitTests {
    @Test func cancellationReturnsPromptlyWithoutCancellingUnderlyingTask() async {
        let suspension = SuspensionGate()
        let underlying = Task { @MainActor in
            await suspension.wait()
            return SyncOutcome.acceptedNoData
        }
        let waiter = Task { @MainActor in
            await waitForSyncTask(underlying)
        }

        await Task.yield()
        waiter.cancel()
        let result = await waiter.value

        #expect(result == .cancelled)
        #expect(!underlying.isCancelled)

        await suspension.release()
        #expect(await underlying.value == .acceptedNoData)
    }
}

private actor SuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            if released {
                self.continuation = nil
                continuation.resume()
            }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
