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

/// `resolvedCode` is what both `/wait` paths now read: it holds a lone
/// wait-failure sentinel back briefly so a concurrent observer's real code can
/// replace it, and it must not busy-spin when its task is cancelled.
@Suite("ContainerExitCodeStore — resolvedCode grace period")
struct ExitCodeStoreResolvedCodeTests {

    private let id = "resolved-code-test-ctr"

    @Test("an already-recorded real code returns immediately")
    func realCodeImmediate() async {
        let store = ContainerExitCodeStore()
        await store.set(id: id, code: 4)
        let started = ContinuousClock.Instant.now
        #expect(await store.resolvedCode(id: id, sentinelGrace: .seconds(30)) == 4)
        #expect(ContinuousClock.Instant.now - started < .seconds(2))
    }

    @Test("an unknown container returns nil immediately")
    func unknownReturnsNil() async {
        let store = ContainerExitCodeStore()
        #expect(await store.resolvedCode(id: "never-set", sentinelGrace: .seconds(30)) == nil)
    }

    @Test("a real code arriving during the grace period is returned, not the sentinel")
    func realCodeDuringGraceWins() async throws {
        let store = ContainerExitCodeStore()
        await store.set(id: id, code: ContainerExitCodeStore.waitFailureSentinel)

        let upgrade = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            await store.set(id: id, code: 11)  // replaces the sentinel
        }
        let code = await store.resolvedCode(id: id, sentinelGrace: .seconds(30))
        _ = await upgrade.value
        #expect(code == 11)
    }

    @Test("a lone sentinel is returned only after the grace period")
    func loneSentinelAfterGrace() async {
        let store = ContainerExitCodeStore()
        await store.set(id: id, code: ContainerExitCodeStore.waitFailureSentinel)
        let started = ContinuousClock.Instant.now
        let code = await store.resolvedCode(id: id, sentinelGrace: .milliseconds(150))
        #expect(code == ContainerExitCodeStore.waitFailureSentinel)
        #expect(ContinuousClock.Instant.now - started >= .milliseconds(150))
    }

    @Test("a cancelled grace returns at once instead of spinning")
    func cancellationEndsGrace() async {
        let store = ContainerExitCodeStore()
        await store.set(id: id, code: ContainerExitCodeStore.waitFailureSentinel)
        let started = ContinuousClock.Instant.now
        let task = Task { await store.resolvedCode(id: id, sentinelGrace: .seconds(600)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let code = await task.value
        #expect(code == ContainerExitCodeStore.waitFailureSentinel)
        #expect(ContinuousClock.Instant.now - started < .seconds(30))
    }

    @Test("a boot clears BOTH the native and hex aliases, so the next run is not stuck on a stale code")
    func removeAllClearsBothAliases() async {
        let store = ContainerExitCodeStore()
        await store.set(id: "native-1", code: 3)
        await store.set(id: "hex-1", code: 3)
        await store.removeAll(nativeId: "native-1", hexId: "hex-1")
        #expect(await store.get(id: "native-1") == nil)
        #expect(await store.get(id: "hex-1") == nil)

        // The new run's first real code is therefore accepted under both ids...
        await store.set(id: "native-1", code: 0)
        await store.set(id: "hex-1", code: 0)
        #expect(await store.get(id: "hex-1") == 0)
    }
}

/// A boot resets the store, but an observer from the PREVIOUS run can still be
/// in flight (the start route's detached waiter, an attach monitor). With
/// "a real code is authoritative once recorded", that late write would pin the
/// old status for the whole new boot. Observers therefore present the boot
/// generation they were armed for.
@Suite("ContainerExitCodeStore — boot generations")
struct ExitCodeStoreBootGenerationTests {

    @Test("an observer armed for a replaced boot cannot record its code")
    func staleObserverRejected() async {
        let nativeId = "gen-native-\(UUID().uuidString)"
        let hexId = "gen-hex-\(UUID().uuidString)"
        let first = await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId)
        let second = await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId)
        #expect(first != second)
        defer { Task { await ContainerExitCodeStore.shared.removeAll(nativeId: nativeId, hexId: hexId) } }

        // The previous run's observer finishes late with that run's status.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 7, generation: first)
        await ContainerExitCodeStore.shared.set(id: hexId, code: 7, generation: first)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == nil)
        #expect(await ContainerExitCodeStore.shared.get(id: hexId) == nil)

        // The current run's real code is still accepted.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0, generation: second)
        await ContainerExitCodeStore.shared.set(id: hexId, code: 0, generation: second)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == 0)
        #expect(await ContainerExitCodeStore.shared.get(id: hexId) == 0)
    }

    @Test("a sentinel from a replaced boot cannot block the new run either")
    func staleSentinelRejected() async {
        let nativeId = "gen-sentinel-\(UUID().uuidString)"
        let hexId = "gen-sentinel-hex-\(UUID().uuidString)"
        let first = await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId)
        let second = await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId)
        defer { Task { await ContainerExitCodeStore.shared.removeAll(nativeId: nativeId, hexId: hexId) } }

        await ContainerExitCodeStore.shared.set(
            id: nativeId, code: ContainerExitCodeStore.waitFailureSentinel, generation: first)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == nil)

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 3, generation: second)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == 3)
    }
}

/// Two attaches can race on the same stopped container. Only the request whose
/// start actually won allocates a generation; the loser observes the winner's
/// token (allocating one would invalidate the winner's, and its real exit code
/// would then be rejected).
@Suite("ContainerExitCodeStore — losing boot observes the winner")
struct ExitCodeStoreLosingBootTests {

    @Test("a loser reads the winner's generation and its writes are accepted")
    func loserObservesWinnerToken() async {
        let nativeId = "lose-native-\(UUID().uuidString)"
        let hexId = "lose-hex-\(UUID().uuidString)"
        defer { Task { await ContainerExitCodeStore.shared.removeAll(nativeId: nativeId, hexId: hexId) } }

        let winner = await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId)
        let observed = await ContainerExitCodeStore.shared.currentGeneration(id: nativeId)
        #expect(observed == winner, "the loser must not allocate a new generation")

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 5, generation: observed)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == 5)
    }
}
