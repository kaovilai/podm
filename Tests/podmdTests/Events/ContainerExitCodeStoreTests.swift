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

        // The write is released by the resolver itself once it has chosen the
        // sentinel-grace path — a fixed sleep would flake under scheduler
        // delay and could pass without exercising that path at all.
        let enteredGrace = AsyncStream<Void>.makeStream()
        let upgrade = Task {
            var iterator = enteredGrace.stream.makeAsyncIterator()
            _ = await iterator.next()
            await store.set(id: id, code: 11)  // replaces the sentinel
        }
        let code = await store.resolvedCode(id: id, sentinelGrace: .seconds(30)) {
            enteredGrace.continuation.yield()
        }
        _ = await upgrade.value
        #expect(code == 11)
    }

    @Test("a new boot during the grace period answers the original observation, never nil")
    func newBootDuringGraceKeepsObservation() async {
        let store = ContainerExitCodeStore()
        let nativeId = "grace-reboot-\(UUID().uuidString)"
        let hexId = "grace-reboot-hex-\(UUID().uuidString)"
        defer { Task { await store.removeAll(nativeId: nativeId, hexId: hexId) } }
        await store.beginBoot(nativeId: nativeId, hexId: hexId)
        await store.set(id: nativeId, code: ContainerExitCodeStore.waitFailureSentinel)

        let enteredGrace = AsyncStream<Void>.makeStream()
        let reboot = Task {
            var iterator = enteredGrace.stream.makeAsyncIterator()
            _ = await iterator.next()
            // A restart resets every alias while the old wait is in its grace.
            _ = await store.beginBoot(nativeId: nativeId, hexId: hexId)
        }
        let code = await store.resolvedCode(id: nativeId, sentinelGrace: .seconds(30)) {
            enteredGrace.continuation.yield()
        }
        _ = await reboot.value
        #expect(
            code == ContainerExitCodeStore.waitFailureSentinel,
            "a cleared record must not become a fabricated exit 0 or the next boot's code")
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

/// Two attaches can race on the same stopped container. Only the winner
/// allocates a generation; the loser passes NO token (reading the current
/// generation would race the winner's publication and could capture the
/// previous boot's token, having its real code rejected). An untokened write
/// is subject only to set()'s precedence, and both observers of one init
/// process resolve the same exit code.
@Suite("ContainerExitCodeStore — a losing boot records without a token")
struct ExitCodeStoreLosingBootTests {

    @Test("a loser's untokened write is accepted after the winner booted")
    func loserWritesWithoutToken() async {
        let nativeId = "lose-native-\(UUID().uuidString)"
        let hexId = "lose-hex-\(UUID().uuidString)"
        defer { Task { await ContainerExitCodeStore.shared.removeAll(nativeId: nativeId, hexId: hexId) } }

        _ = await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId)

        // The losing attach's monitor records the same init process's code.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 5)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == 5)
    }

    @Test("a stale token from the previous boot is still rejected")
    func staleTokenStillRejected() async {
        let nativeId = "lose-stale-\(UUID().uuidString)"
        let hexId = "lose-stale-hex-\(UUID().uuidString)"
        defer { Task { await ContainerExitCodeStore.shared.removeAll(nativeId: nativeId, hexId: hexId) } }

        let first = await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId)
        _ = await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId)
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 7, generation: first)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == nil)
    }
}

@Suite("ContainerExitCodeStore — alias clearing")
struct ExitCodeStoreAliasClearTests {

    @Test("removeAll clears both the native id and the hex id")
    func removeAllClearsBothAliases() async {
        let nativeId = "alias-native-\(UUID().uuidString)"
        let hexId = "alias-hex-\(UUID().uuidString)"
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 42)
        await ContainerExitCodeStore.shared.set(id: hexId, code: 42)

        await ContainerExitCodeStore.shared.removeAll(nativeId: nativeId, hexId: hexId)

        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == nil)
        #expect(await ContainerExitCodeStore.shared.get(id: hexId) == nil)
    }
}

/// A losing observer cannot know the winner's generation token (reading it
/// would race its publication), so boots are ALSO identified by the
/// container's own start date: every observer of one boot sees the same
/// `startedDate`, while a straggler from an earlier boot carries an older one.
@Suite("ContainerExitCodeStore — boot identity by start date")
struct ExitCodeStoreBootDateTests {

    private func tempIds() -> (String, String) {
        ("date-native-\(UUID().uuidString)", "date-hex-\(UUID().uuidString)")
    }

    @Test("an untokened loser sharing the current boot's start date is accepted")
    func sameBootAccepted() async {
        let (nativeId, hexId) = tempIds()
        let bootDate = Date(timeIntervalSince1970: 1_000)
        defer { Task { await ContainerExitCodeStore.shared.removeAll(nativeId: nativeId, hexId: hexId) } }
        await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId, bootDate: bootDate)

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 5, bootDate: bootDate)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == 5)
    }

    @Test("a straggler from an earlier boot is rejected without any token")
    func olderBootRejected() async {
        let (nativeId, hexId) = tempIds()
        let firstBoot = Date(timeIntervalSince1970: 1_000)
        let secondBoot = Date(timeIntervalSince1970: 2_000)
        defer { Task { await ContainerExitCodeStore.shared.removeAll(nativeId: nativeId, hexId: hexId) } }

        await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId, bootDate: firstBoot)
        await ContainerExitCodeStore.shared.beginBoot(nativeId: nativeId, hexId: hexId, bootDate: secondBoot)

        // The previous run's monitor completes late, untokened.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 7, bootDate: firstBoot)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == nil)

        // The current boot's own observer still records.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0, bootDate: secondBoot)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == 0)
    }
}

/// A start fetches its post-start snapshot before it registers the boot, so a
/// concurrent observer of the SAME boot can record the real exit code first.
/// Registration must keep that result. And a delayed start that finishes after
/// a restart must not disturb the newer boot's registration.
@Suite("ContainerExitCodeStore — boot registration ordering")
struct ExitCodeStoreBootRegistrationTests {

    private func tempIds() -> (String, String) {
        ("reg-native-\(UUID().uuidString)", "reg-hex-\(UUID().uuidString)")
    }

    @Test("registration keeps a code the same boot already recorded")
    func sameBootCodeSurvivesRegistration() async {
        let (nativeId, hexId) = tempIds()
        let bootDate = Date(timeIntervalSince1970: 1_000)
        defer { Task { await ContainerExitCodeStore.shared.removeAll(nativeId: nativeId, hexId: hexId) } }

        // The concurrent observer records while the starter fetches its snapshot.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 3, bootDate: bootDate)
        _ = await ContainerExitCodeStore.shared.beginBoot(
            nativeId: nativeId, hexId: hexId, bootDate: bootDate)

        #expect(
            await ContainerExitCodeStore.shared.get(id: nativeId) == 3,
            "the starter's own registration must not discard its boot's result")
    }

    @Test("a stale registration is refused and leaves the newer boot untouched")
    func staleRegistrationRefused() async {
        let (nativeId, hexId) = tempIds()
        let olderBoot = Date(timeIntervalSince1970: 1_000)
        let newerBoot = Date(timeIntervalSince1970: 2_000)
        defer { Task { await ContainerExitCodeStore.shared.removeAll(nativeId: nativeId, hexId: hexId) } }

        // The restart registers first and its observer records the real code.
        let newerGeneration = await ContainerExitCodeStore.shared.beginBoot(
            nativeId: nativeId, hexId: hexId, bootDate: newerBoot)
        await ContainerExitCodeStore.shared.set(
            id: nativeId, code: 0, generation: newerGeneration, bootDate: newerBoot)

        // A delayed start of the OLDER boot finally registers.
        let stale = await ContainerExitCodeStore.shared.beginBoot(
            nativeId: nativeId, hexId: hexId, bootDate: olderBoot)

        #expect(stale == nil, "an older registration must be refused")
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == 0, "the newer boot's result must survive")
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 7, bootDate: olderBoot)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == 0, "the older boot cannot overwrite it either")
    }
}
