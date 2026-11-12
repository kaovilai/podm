import Foundation
import Testing

@testable import podmd

private struct SyntheticError: Error {}

@Suite("VMLifecycleAdmission")
struct VMLifecycleAdmissionTests {

    @Test("Runs immediately while slots are available")
    func runsImmediatelyUnderLimit() async throws {
        let admission = VMLifecycleAdmission(limit: 2)
        let result = try await admission.withSlot { 42 }
        #expect(result == 42)
    }

    @Test("A call beyond the limit blocks until a slot is released")
    func blocksBeyondLimit() async throws {
        let admission = VMLifecycleAdmission(limit: 1)

        // Occupy the only slot first, confirmed via a signal, before the waiter can race for it.
        let holderAcquired = AsyncStream<Void>.makeStream()
        let releaseHolder = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await admission.withSlot {
                holderAcquired.continuation.yield(())
                for await _ in releaseHolder.stream { break }
            }
        }
        var acquiredIterator = holderAcquired.stream.makeAsyncIterator()
        _ = await acquiredIterator.next()

        let releasedAt = Date()
        let waiterTask = Task { () -> Date in
            try await admission.withSlot { Date() }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        releaseHolder.continuation.yield(())
        releaseHolder.continuation.finish()
        try await holder.value

        let acquiredAt = try await waiterTask.value
        #expect(acquiredAt.timeIntervalSince(releasedAt) >= 0.05)
    }

    @Test("Releases the slot even when body throws")
    func releasesOnThrow() async {
        let admission = VMLifecycleAdmission(limit: 1)

        await #expect(throws: SyntheticError.self) {
            try await admission.withSlot { throw SyntheticError() }
        }

        // If the slot weren't released on throw, this would hang.
        let result = try? await admission.withSlot { "recovered" }
        #expect(result == "recovered")
    }

    @Test("A cancelled queued waiter never runs its body, and a later waiter is still admitted")
    func cancelledWaiterDoesNotRunOrBlock() async throws {
        actor Ran {
            private(set) var value = false
            func markRan() { value = true }
        }

        let admission = VMLifecycleAdmission(limit: 1)
        let ran = Ran()
        let holderAcquired = AsyncStream<Void>.makeStream()
        let releaseHolder = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await admission.withSlot {
                holderAcquired.continuation.yield(())
                for await _ in releaseHolder.stream { break }
            }
        }
        var acquiredIterator = holderAcquired.stream.makeAsyncIterator()
        _ = await acquiredIterator.next()

        let cancelledWaiter = Task {
            try await admission.withSlot { await ran.markRan() }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        cancelledWaiter.cancel()

        let nextWaiter = Task {
            try await admission.withSlot { true }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        releaseHolder.continuation.yield(())
        releaseHolder.continuation.finish()
        _ = try await holder.value

        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }
        #expect(try await nextWaiter.value, "a later waiter must still be admitted after the cancelled one")
        #expect(await ran.value == false, "a cancelled waiter must never run its body")
    }

    @Test("A caller cancelled after its acquisition succeeded never runs its body — the slot is handed back")
    func cancelledAfterAcquisitionNeverRunsBody() async throws {
        // The SLOT-LEAK hammer: cancellation is fired from outside, so where
        // it lands relative to withSlot's post-acquisition guard is up to the
        // scheduler (see the comment below the loop). What this test pins is
        // the invariant that holds on every interleaving — the slot always
        // comes back. The guard itself (cancellation observed after
        // acquisition ⇒ body never entered) is pinned deterministically by
        // postAcquisitionCancellationIsGuarded below via the `interpose`
        // seam.
        actor CancelledBodyRuns {
            private(set) var count = 0
            func record(_ cancelled: Bool) {
                if cancelled { count += 1 }
            }
        }

        // Hammer the gap: release the only slot and cancel the queued
        // caller as close behind as the scheduler allows. Some iterations
        // land the cancellation while the caller is still resuming from its
        // SUCCESSFUL acquisition (cancelling a completed acquirer does not
        // change its result, so the race returns .acquired) — the body must
        // never observe a cancelled task, and the slot must come back.
        for _ in 0..<100 {
            let admission = VMLifecycleAdmission(limit: 1)
            let cancelledBodies = CancelledBodyRuns()
            let holderAcquired = AsyncStream<Void>.makeStream()
            let releaseHolder = AsyncStream<Void>.makeStream()

            let holder = Task {
                try await admission.withSlot {
                    holderAcquired.continuation.yield(())
                    for await _ in releaseHolder.stream { break }
                }
            }
            var acquiredIterator = holderAcquired.stream.makeAsyncIterator()
            _ = await acquiredIterator.next()

            let caller = Task {
                try await admission.withSlot(timeoutNs: 60_000_000_000) {
                    // Read synchronously at body entry: the fix's
                    // post-acquire check and this read are one synchronous
                    // sequence, so a body that observes cancellation is a
                    // body that STARTED cancelled.
                    let cancelledAtStart = Task.isCancelled
                    await cancelledBodies.record(cancelledAtStart)
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)  // let the caller queue

            releaseHolder.continuation.yield(())
            releaseHolder.continuation.finish()
            caller.cancel()
            _ = try await holder.value
            _ = (try? await caller.value) ?? nil

            // Deliberately NOT asserting "the body never ran cancelled":
            // `caller.cancel()` can land after withSlot's cancellation
            // check but before the body reads Task.isCancelled — a body
            // observing cancellation then is a schedulable interleaving,
            // not a slot leak or a broken check. What this test CAN
            // observe reliably is the invariant that matters: the slot
            // was released (the next caller is admitted immediately —
            // a leak here hangs to the test's time limit).
            let probe = try await admission.withSlot { true }
            #expect(probe)
        }
    }

    @Test("Cancellation landing between acquisition and the guard never enters the body — the slot is handed back")
    func postAcquisitionCancellationIsGuarded() async throws {
        actor BodyRuns {
            private(set) var count = 0
            func record() { count += 1 }
        }

        let admission = VMLifecycleAdmission(limit: 1)
        let bodyRuns = BodyRuns()
        let holderAcquired = AsyncStream<Void>.makeStream()
        let releaseHolder = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await admission.withSlot {
                holderAcquired.continuation.yield(())
                for await _ in releaseHolder.stream { break }
            }
        }
        var acquiredIterator = holderAcquired.stream.makeAsyncIterator()
        _ = await acquiredIterator.next()

        let caller = Task {
            try await admission.withSlot(
                timeoutNs: 60_000_000_000,
                interpose: {
                    // Cancel the CALLING task exactly between its successful
                    // acquisition and the post-acquisition guard — the gap
                    // the hammer above cannot target deterministically.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            ) {
                await bodyRuns.record()
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)  // let the caller queue

        releaseHolder.continuation.yield(())
        releaseHolder.continuation.finish()

        await #expect(throws: CancellationError.self) {
            try await caller.value
        }
        #expect(
            await bodyRuns.count == 0,
            "cancellation observed after acquisition must prevent the body from ever running")
        // The slot came back: the next caller is admitted immediately (a
        // leak here hangs to the test's time limit).
        let probe = try await admission.withSlot { true }
        #expect(probe)
        _ = try await holder.value
    }

    @Test("A caller already cancelled before acquire() ever runs is still never admitted")
    func preCancelledCallerNeverAdmitted() async throws {
        for _ in 0..<200 {
            let admission = VMLifecycleAdmission(limit: 1)
            let holderAcquired = AsyncStream<Void>.makeStream()
            let releaseHolder = AsyncStream<Void>.makeStream()

            let holder = Task {
                try await admission.withSlot {
                    holderAcquired.continuation.yield(())
                    for await _ in releaseHolder.stream { break }
                }
            }
            var acquiredIterator = holderAcquired.stream.makeAsyncIterator()
            _ = await acquiredIterator.next()

            // No sleep between creation and cancel — racing to catch the task already
            // cancelled by the time acquire() itself runs, not cancelled while queued.
            let task = Task {
                try await admission.withSlot { true }
            }
            task.cancel()

            releaseHolder.continuation.yield(())
            releaseHolder.continuation.finish()
            _ = try await holder.value

            do {
                _ = try await task.value
                Issue.record("a pre-cancelled caller must not be admitted")
            } catch is CancellationError {
                // expected
            }
        }
    }

    @Test("Released slots are handed to waiters in FIFO order")
    func fifoOrdering() async throws {
        actor OrderLog {
            private(set) var order: [Int] = []
            func record(_ value: Int) { order.append(value) }
        }

        let admission = VMLifecycleAdmission(limit: 1)
        let log = OrderLog()
        let gate = AsyncStream<Void>.makeStream()
        let holderAcquired = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await admission.withSlot {
                holderAcquired.continuation.yield(())
                for await _ in gate.stream { break }
            }
        }
        var acquiredIterator = holderAcquired.stream.makeAsyncIterator()
        _ = await acquiredIterator.next()

        let task1 = Task {
            try await admission.withSlot { await log.record(1) }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let task2 = Task {
            try await admission.withSlot { await log.record(2) }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        gate.continuation.yield(())
        gate.continuation.finish()
        _ = try await holder.value
        _ = try await task1.value
        _ = try await task2.value

        #expect(await log.order == [1, 2])
    }

    @Test("defaultLimit is at least 2")
    func defaultLimitHasFloor() {
        #expect(VMLifecycleAdmission.defaultLimit >= 2)
    }

    // MARK: bounded queue wait (review round 2 — all-slots-wedged admission)

    @Test(
        "withSlot(timeoutNs:) fails with a bounded QueueTimeout when every slot stays held",
        .timeLimit(.minutes(1))
    )
    func timeoutThrowsWhenAllSlotsHeld() async throws {
        let admission = VMLifecycleAdmission(limit: 1)

        // A wedged ordinary stop: holds the only slot forever.
        let holderAcquired = AsyncStream<Void>.makeStream()
        let releaseHolder = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await admission.withSlot {
                holderAcquired.continuation.yield(())
                for await _ in releaseHolder.stream { break }
            }
        }
        var acquiredIterator = holderAcquired.stream.makeAsyncIterator()
        _ = await acquiredIterator.next()

        // Before the fix this queued forever — before any recovery window
        // even started. It must now fail with the actionable deadline.
        let startedAt = Date()
        await #expect(throws: VMLifecycleAdmission.QueueTimeout.self) {
            try await admission.withSlot(timeoutNs: 50_000_000) { "never" }
        }
        #expect(Date().timeIntervalSince(startedAt) < 5, "the wait must be bounded by the deadline, not the holder")

        // The wedged holder keeps its slot — the deadline must not have
        // stolen or leaked one: a second bounded wait also times out, and
        // once the holder releases, a bounded wait succeeds.
        await #expect(throws: VMLifecycleAdmission.QueueTimeout.self) {
            try await admission.withSlot(timeoutNs: 50_000_000) { "never" }
        }
        releaseHolder.continuation.yield(())
        releaseHolder.continuation.finish()
        _ = try await holder.value
        let result = try await admission.withSlot(timeoutNs: 5_000_000_000) { "admitted" }
        #expect(result == "admitted")
    }

    @Test("withSlot(timeoutNs:) runs immediately when a slot is free")
    func timeoutFastPathAdmits() async throws {
        let admission = VMLifecycleAdmission(limit: 2)
        let result = try await admission.withSlot(timeoutNs: 1_000_000) { 7 }
        #expect(result == 7)
    }

    @Test("withSlot(timeoutNs:) waits through a healthy backlog instead of timing out")
    func timeoutWaitsThroughHealthyBacklog() async throws {
        let admission = VMLifecycleAdmission(limit: 1)

        let holderAcquired = AsyncStream<Void>.makeStream()
        let releaseHolder = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await admission.withSlot {
                holderAcquired.continuation.yield(())
                for await _ in releaseHolder.stream { break }
            }
        }
        var acquiredIterator = holderAcquired.stream.makeAsyncIterator()
        _ = await acquiredIterator.next()

        // The backlog releases at 100 ms; the deadline is 5 s — a healthy
        // queue must never be mistaken for a wedge.
        let waiter = Task { try await admission.withSlot(timeoutNs: 5_000_000_000) { "ran" } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        releaseHolder.continuation.yield(())
        releaseHolder.continuation.finish()
        _ = try await holder.value
        #expect(try await waiter.value == "ran")
    }

    @Test("withSlot(timeoutNs:) releases its slot when the body throws")
    func timeoutReleasesOnThrow() async throws {
        let admission = VMLifecycleAdmission(limit: 1)
        await #expect(throws: SyntheticError.self) {
            try await admission.withSlot(timeoutNs: 5_000_000_000) { throw SyntheticError() }
        }
        let result = try await admission.withSlot(timeoutNs: 5_000_000_000) { "recovered" }
        #expect(result == "recovered")
    }
}
