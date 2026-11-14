import Foundation
import Testing

@testable import podmd

@Suite("ContainerExitCodeStore — waitForCode")
struct ContainerExitCodeStoreTests {

    @Test("waitForCode returns immediately when the code is already recorded")
    func returnsAlreadyRecorded() async throws {
        let store = ContainerExitCodeStore()
        let id = "ctr-pre-\(Int.random(in: 10000...99999))"
        await store.set(id: id, code: 7)
        let code = await store.waitForCode(id: id)
        #expect(code == 7)
    }

    @Test("waitForCode suspends until set() records the code, then returns it")
    func resumesOnSet() async throws {
        let store = ContainerExitCodeStore()
        let id = "ctr-wait-\(Int.random(in: 10000...99999))"

        // Start awaiting before the code exists — this must suspend, not return 0.
        let waiter = Task { await store.waitForCode(id: id) }

        // Give the waiter a moment to register, then record the real code.
        try await Task.sleep(nanoseconds: 100_000_000)
        await store.set(id: id, code: 42)

        let code = await waiter.value
        #expect(code == 42, "must deliver the recorded code, not a 0 fallback")
    }
}

private struct WaitError: Error {}

@Suite("ContainerExitCodeStore — resolveExitCode retry")
struct ResolveExitCodeTests {

    @Test("returns the code immediately when wait() succeeds first try")
    func succeedsFirstTry() async {
        var calls = 0
        let code = await ContainerExitCodeStore.resolveExitCode(retryDelayNs: 0) {
            calls += 1
            return 7
        }
        #expect(code == 7)
        #expect(calls == 1)
    }

    // A transient throw from the wait XPC round-trip must NOT be recorded as a fake exit
    // code of 0. Retrying yields the authoritative code (7).
    @Test("retries past transient throws and returns the real code")
    func retriesPastTransientThrows() async {
        var calls = 0
        let code = await ContainerExitCodeStore.resolveExitCode(retryDelayNs: 0) {
            calls += 1
            if calls < 3 { throw WaitError() }
            return 7
        }
        #expect(code == 7, "transient wait() failures must not collapse into exit code 0")
        #expect(calls == 3)
    }

    @Test("returns the failure sentinel (not 0) when every attempt throws")
    func sentinelOnPersistentFailure() async {
        var calls = 0
        let code = await ContainerExitCodeStore.resolveExitCode(maxAttempts: 4, retryDelayNs: 0) {
            calls += 1
            throw WaitError()
        }
        #expect(code == ContainerExitCodeStore.waitFailureSentinel)
        #expect(code != 0, "a failed wait must be distinguishable from a genuine exit-0")
        #expect(calls == 4)
    }
}

/// A foreground `docker run` has two exit observers (the start route's
/// background waiter and the attach route's monitor). When one observer's
/// `wait()` failed after its retries it recorded `waitFailureSentinel` — and
/// that sentinel OVERWROTE the real code the other observer had just recorded,
/// so `docker run alpine sh -c 'exit 3'` returned 255 roughly two runs in
/// three.
@Suite("ContainerExitCodeStore — the failure sentinel never clobbers a real code")
struct ExitCodeStoreSentinelPrecedenceTests {

    private let id = "exit-code-store-test-ctr"

    @Test("a real code is not replaced by the sentinel")
    func sentinelDoesNotClobber() async {
        let store = ContainerExitCodeStore()
        await store.set(id: id, code: 3)
        await store.set(id: id, code: ContainerExitCodeStore.waitFailureSentinel)
        #expect(await store.get(id: id) == 3)
    }

    @Test("a real code is not replaced by a second, different real code")
    func firstRealCodeWins() async {
        let store = ContainerExitCodeStore()
        await store.set(id: id, code: 3)
        await store.set(id: id, code: 7)
        #expect(await store.get(id: id) == 3)
    }

    @Test("the sentinel may still fill in when no real code exists")
    func sentinelFillsIn() async {
        let store = ContainerExitCodeStore()
        await store.set(id: id, code: ContainerExitCodeStore.waitFailureSentinel)
        #expect(await store.get(id: id) == ContainerExitCodeStore.waitFailureSentinel)
    }

    @Test("a real code that arrives after the sentinel replaces it")
    func realCodeUpgradesSentinel() async {
        let store = ContainerExitCodeStore()
        await store.set(id: id, code: ContainerExitCodeStore.waitFailureSentinel)
        await store.set(id: id, code: 3)
        #expect(await store.get(id: id) == 3)
    }

    @Test("a restart's remove() clears the code so the next run records fresh")
    func removeAllowsFreshCode() async {
        let store = ContainerExitCodeStore()
        await store.set(id: id, code: 3)
        await store.remove(id: id)
        await store.set(id: id, code: 0)
        #expect(await store.get(id: id) == 0)
    }
}
