import Foundation

/// Limits how many containers may be simultaneously transitioning their `VZVirtualMachine`
/// state (booting or tearing down) rather than how many may run in total. Apple Container's
/// Virtualization.framework has been observed to fail to service virtio-net queues promptly
/// under concurrent VM state transitions (guest kernel `NETDEV WATCHDOG` timeouts cascading
/// into DNS/connect failures and, in the worst case, a guest kernel panic) when many
/// containers boot or stop at once — e.g. `docker compose up`/`down`, `supabase start`/`stop`.
///
/// Boot and stop share ONE pool rather than separate pools: both spike the same finite
/// resource (the host's capacity to service concurrent VZ state transitions), so a boot storm
/// and a stop storm must not be allowed to run concurrently and compound each other. `kill`
/// only delivers a signal (no VZ transition) and isn't gated; the VM teardown that may follow
/// happens through the already-gated stop path.
actor VMLifecycleAdmission {
    static let shared = VMLifecycleAdmission(limit: VMLifecycleAdmission.defaultLimit)

    static var defaultLimit: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount / 4)
    }

    /// `withSlot(timeoutNs:)` could not acquire a slot within its deadline:
    /// every slot in the pool was held for the whole wait. For the delete
    /// path's force-stop this means the ordinary stops holding the pool are
    /// themselves wedged (issue #45) — a wedged `stopInternal` holds its
    /// slot forever, so without this deadline a force-delete would queue
    /// behind them indefinitely, before its own recovery windows even start.
    struct QueueTimeout: Error {
        /// The pool size — how many holders stayed wedged.
        let limit: Int
    }

    private let limit: Int
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    /// Runs `body` while holding one admission slot, queuing (FIFO) if none are free.
    /// A `restart` (stop, then start) should wrap both under a single `withSlot` call rather
    /// than acquiring twice, so the container isn't left stopped while other queued work runs.
    func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    /// `withSlot(_:)` with a bounded QUEUE wait: if no slot frees up within
    /// `timeoutNs`, throws `QueueTimeout` instead of queueing forever. Used
    /// by the delete path's force-stop, which must fail with an actionable
    /// error when every slot is held by operations wedged against a stuck
    /// apiserver (a healthy FIFO backlog still gets the full deadline).
    /// The acquisition itself runs in a child task so it can be raced
    /// against the deadline; `acquire()` stays cancellation-correct on both
    /// sides (a cancelled waiter is removed from the queue, and a waiter
    /// granted a slot just as cancellation lands hands it back).
    /// - Parameters:
    ///   - timeoutNs: how long a queued caller waits for a slot before
    ///     failing with `QueueTimeout`.
    ///   - interpose: test-only hook, invoked synchronously on the calling
    ///     task after the slot is held but immediately BEFORE the
    ///     post-acquisition cancellation guard — the one point a test can
    ///     land a cancellation deterministically between a successful
    ///     acquisition and the guard. No external scheduling can target that
    ///     gap: until moments before the guard runs, the caller is suspended
    ///     inside the acquisition race. Production callers omit it.
    ///   - body: the operation to run while holding the slot.
    func withSlot<T: Sendable>(
        timeoutNs: UInt64,
        interpose: (@Sendable () -> Void)? = nil,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        // Fast path: a free slot needs no timer and no child task.
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
        } else {
            let acquirer = Task { try await acquire() }
            do {
                try await withTaskCancellationHandler {
                    try await raceAcquisition(acquirer, timeoutNs: timeoutNs)
                } onCancel: {
                    acquirer.cancel()
                }
            } catch is CancellationError {
                // The CALLING task was cancelled (not our deadline). The
                // acquirer was cancelled too; if it nevertheless completed
                // successfully in the gap, it holds a slot — hand it back.
                if (try? await acquirer.value) != nil {
                    release()
                }
                throw CancellationError()
            } catch let timeout as QueueTimeout {
                acquirer.cancel()
                // Same gap: the acquirer may have won a slot just before
                // cancellation was observed. It holds one — hand it back,
                // then surface the deadline.
                if (try? await acquirer.value) != nil {
                    release()
                }
                throw timeout
            }
        }
        // Test seam (see `interpose`): lands between acquisition and the
        // guard below. nil for every production caller.
        interpose?()
        // The slot is held on every path that reaches here. One more gap
        // remains on the queued path: the acquirer may have completed
        // successfully BEFORE the calling task was cancelled — cancelling a
        // completed acquirer does not change its successful result, so the
        // race returned .acquired and neither catch branch ran. Without
        // this check the cancelled caller's body (e.g. a force-stop) would
        // run anyway. Hand the slot back and surface the cancellation.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    /// The acquisition's outcome if it finished before `timeoutNs`, nil on
    /// deadline. Same shape as `ContainerRuntimeJobRecovery.race`: the losing
    /// racer finds its one-shot continuation already consumed and is ignored.
    private enum AcquisitionOutcome: @unchecked Sendable {
        case acquired
        case failed(any Error)
    }

    private func raceAcquisition(_ acquirer: Task<Void, Error>, timeoutNs: UInt64) async throws {
        let outcome: AcquisitionOutcome? = await withCheckedContinuation { (cont: CheckedContinuation<AcquisitionOutcome?, Never>) in
            let once = ResumeOnce(cont)
            Task {
                do {
                    try await acquirer.value
                    once.resume(returning: .acquired)
                } catch {
                    once.resume(returning: .failed(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                once.resume(returning: nil)
            }
        }
        switch outcome {
        case .acquired:
            return
        case .failed(let error):
            throw error
        case nil:
            throw QueueTimeout(limit: limit)
        }
    }

    private func acquire() async throws {
        // A task cancelled before ever reaching acquire() (e.g. the holder released and a
        // slot became free before this task's body was even scheduled) must not silently
        // acquire via the fast path below, which has no cancellation check of its own.
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // onCancel fires immediately for an already-cancelled task and only spawns a
                // Task to reach this actor, racing against this closure's own append — if that
                // Task wins, cancelWaiter finds nothing and the append below would otherwise
                // orphan a waiter that release() later resumes normally instead of throwing.
                // Checking cancellation here, synchronously before appending, closes that gap.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
            // A second race remains even after the check above: release() and cancelWaiter's
            // spawned Task both independently compete to touch this waiter, and release() can
            // win, resuming us normally before cancelWaiter ever runs (it then no-ops, finding
            // nothing left to remove). Re-checking here catches that case — hand the slot we
            // were just granted back to the pool instead of silently keeping it.
            if Task.isCancelled {
                release()
                throw CancellationError()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    // A cancelled caller that already left `waiters` (raced with `release()`) is a no-op here —
    // whichever of the two touches it first wins, since both run serialized on this actor.
    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
        } else {
            available += 1
        }
    }
}
