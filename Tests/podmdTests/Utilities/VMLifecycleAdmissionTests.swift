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
