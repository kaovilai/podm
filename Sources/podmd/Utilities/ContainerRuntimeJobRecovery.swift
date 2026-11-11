import Darwin
import Foundation

/// Hang detection and recovery for Apple Container operations that touch a
/// container's per-container runtime launchd job — the root cause of issue
/// #45 (`DELETE /containers/{id}` never answering, `podman run --rm` never
/// returning, both surviving a podmd restart).
///
/// apple/container registers one launchd job per container
/// (`com.apple.container.<runtimeHandler>.<nativeId>`, program under the
/// apiserver's install root) and deregisters it when the container is
/// deleted. Two upstream defects combine into a permanent wedge:
///
/// 1. If the job's program cannot be spawned — most commonly because the
///    install root the running services were started from no longer exists
///    on disk (e.g. Homebrew removed the keg out from under the
///    still-running `container-apiserver`) — launchd parks the job in
///    `state = spawn scheduled` with `last exit code = 78: EX_CONFIG`
///    indefinitely and never services its mach endpoint.
/// 2. apple/container performs most per-container XPC round trips with no
///    timeout (apple/container#1884): a bootstrap against the dead endpoint
///    stalls for its 60 s ceiling and then fails, while the delete/teardown
///    paths that touch the job block forever — holding the apiserver's
///    container lock, which queues every later create/start/delete behind
///    them. Read-only routes never take that lock, which is why the daemon
///    otherwise stays responsive (`/_ping` and `GET /containers/json` keep
///    working) and why restarting podmd does not help: the wedge lives in
///    the apiserver, not in podmd.
///
/// `launchctl bootout` of the stuck job is the minimal unwedge: the apiserver
/// operations queued behind it complete immediately (verified against
/// container 1.6.1 — a delete that had hung for hours finishes and removes
/// the container as soon as the job is booted out). Booting out the runtime
/// job of a container that is being deleted (or force-removed) is safe: the
/// apiserver's own cleanup deregisters exactly this job, and for a
/// force-remove the bootout is precisely the "kill the runtime" the caller
/// asked for.
enum ContainerRuntimeJobRecovery {
    /// How long a healthy delete/force-stop is given before its runtime job
    /// is presumed wedged. The apiserver's own force-stop waits up to 5 s
    /// internally before killing, so this leaves healthy-but-slow teardown
    /// ample headroom; a false-positive bootout is harmless on the delete
    /// path (the job dies with the container anyway).
    static let firstWindowNs: UInt64 = 15_000_000_000

    /// Second chance, started CONCURRENTLY with the recovery bootout. Once
    /// the stuck job is gone the queued apiserver operations complete
    /// near-instantly, so this window covers the (capped) bootout plus the
    /// operation's completion; anything still pending after it is wedged by
    /// something else. Starting it only after the bootout returns would let
    /// a stalled `launchctl` extend the deadline — and the DELETE response —
    /// indefinitely.
    static let secondWindowNs: UInt64 = 10_000_000_000

    /// How long `launchctl bootout` is given before it is terminated. The
    /// recovery must stay bounded even when launchd stalls: a wedged job is
    /// unwedged by the bootout having been ATTEMPTED as much as by it
    /// succeeding, and the follow-up window decides the outcome either way.
    static let bootoutCapNs: UInt64 = 5_000_000_000

    /// The launchd label apple/container registers for a container's runtime
    /// job — `ContainersService.fullLaunchdServiceLabel` upstream:
    /// `<machServicePrefix>.<runtimeHandler>.<nativeId>`.
    static func launchdServiceLabel(runtimeHandler: String, nativeId: String) -> String {
        "com.apple.container.\(runtimeHandler).\(nativeId)"
    }

    /// The label qualified with the per-user GUI launchd domain — what
    /// apple's `ServiceManager.getDomainString()` resolves to for the
    /// Aqua-session apiserver that registers runtime jobs, and the form
    /// `launchctl bootout` expects.
    static func domainQualifiedLabel(runtimeHandler: String, nativeId: String) -> String {
        "gui/\(getuid())/\(launchdServiceLabel(runtimeHandler: runtimeHandler, nativeId: nativeId))"
    }

    /// Boots a (possibly wedged) runtime job out of launchd. Synchronous —
    /// `launchctl bootout` blocks until launchd answers — so callers must
    /// keep it off Swift's cooperative pool (`withHangRecovery` dispatches
    /// it to a blocking-capable GCD queue). The wait is bounded by
    /// `bootoutCapNs`: a stalled launchctl is SIGTERMed (then SIGKILLed)
    /// rather than allowed to hang the recovery. A non-zero status is not
    /// fatal: the follow-up window decides whether the operation recovered.
    static func liveBootout(_ domainQualifiedLabel: String) -> Int32 {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", domainQualifiedLabel]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return runBounded(process, capNs: bootoutCapNs)
    }

    /// Runs a not-yet-launched `Process` to completion, bounded: on
    /// `capNs` it is SIGTERMed, after a further grace SIGKILLed, and a
    /// synthetic -1 is returned if even that never reaped it. Returns the
    /// process's termination status, or -1 if it could not be launched or
    /// never exited. Blocking — keep off the cooperative pool, like
    /// `liveBootout`.
    static func runBounded(_ process: Foundation.Process, capNs: UInt64) -> Int32 {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return -1
        }
        // Each successful wait implies the handler ran, i.e. the process
        // exited — reading terminationStatus then is safe.
        if exited.wait(timeout: DispatchTime.now() + .nanoseconds(Int(clamping: capNs))) == .success {
            return process.terminationStatus
        }
        process.terminate()  // SIGTERM
        if exited.wait(timeout: DispatchTime.now() + .seconds(2)) == .success {
            return process.terminationStatus
        }
        kill(process.processIdentifier, SIGKILL)
        if exited.wait(timeout: DispatchTime.now() + .seconds(2)) == .success {
            return process.terminationStatus
        }
        return -1
    }

    /// Runs a container delete or force-stop with hang detection and
    /// recovery for a wedged runtime job (issue #45).
    ///
    /// The operation is raced against `firstWindowNs`. On timeout the
    /// container's runtime job is booted out of launchd — unwedging the
    /// apiserver so the STILL-RUNNING operation can complete — while the
    /// SAME operation is raced against `secondWindowNs` CONCURRENTLY with
    /// the bootout: a stalled launchctl must not delay the deadline (or the
    /// response) at all. The operation task is deliberately unstructured
    /// and never cancelled: its XPC continuation only resumes on the
    /// apiserver's reply (Task cancellation cannot reach it), and it is
    /// exactly the reply we are waiting for once the wedge clears.
    ///
    /// The bootout task is likewise never awaited: production's
    /// `liveBootout` is internally bounded (its subprocess is terminated
    /// after `bootoutCapNs`), and its result is advisory anyway — the
    /// follow-up window decides whether the operation recovered. A bootout
    /// that lands after the operation completed on its own targets a job
    /// the apiserver has since deregistered, which is a harmless no-op.
    ///
    /// `bootout` is injectable so tests can model the blocking interaction
    /// without a real launchd; production uses `liveBootout`.
    static func withHangRecovery(
        nativeId: String,
        runtimeHandler: String,
        firstWindowNs: UInt64 = ContainerRuntimeJobRecovery.firstWindowNs,
        secondWindowNs: UInt64 = ContainerRuntimeJobRecovery.secondWindowNs,
        bootout: @escaping @Sendable (_ domainQualifiedLabel: String) -> Int32 = liveBootout,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let task = Task<Void, Error> { try await operation() }

        switch await race(task, timeoutNs: firstWindowNs) {
        case .succeeded:
            return
        case .failed(let error):
            throw error
        case nil:
            break  // first window elapsed — presume the runtime job is wedged
        }

        let label = domainQualifiedLabel(runtimeHandler: runtimeHandler, nativeId: nativeId)
        // The hook blocks (launchctl waits for launchd to answer) — a
        // detached task would still occupy a cooperative-pool worker, so it
        // runs on a blocking-capable GCD queue instead. Deliberately NOT
        // awaited: see the doc comment above.
        _ = Task<Int32, Never>(priority: .utility) {
            await runBootout(bootout, label: label)
        }

        switch await race(task, timeoutNs: secondWindowNs) {
        case .succeeded:
            return
        case .failed(let error):
            throw error
        case nil:
            throw ClientContainerError.runtimeJobWedged(nativeId: nativeId, label: label)
        }
    }

    /// Runs the (blocking, synchronous) bootout hook off Swift's cooperative
    /// pool: `Task.detached` does NOT move blocking work off the global
    /// concurrent executor, and a blocking `waitUntilExit` on a cooperative
    /// worker starves the daemon's operation and timeout tasks under
    /// concurrent recoveries. A plain GCD global-queue thread blocks freely.
    private static func runBootout(
        _ bootout: @escaping @Sendable (_ domainQualifiedLabel: String) -> Int32,
        label: String
    ) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: bootout(label))
            }
        }
    }

    /// The operation's outcome if it finished before `timeoutNs`, nil on
    /// timeout. Same shape as `AsyncRace.firstOrTimeout` (a task group would
    /// wait for the never-finishing loser at scope exit, defeating the
    /// timeout); the losing racer finds its one-shot continuation already
    /// consumed and is ignored.
    private enum Outcome: @unchecked Sendable {
        case succeeded
        case failed(any Error)
    }

    private static func race(_ task: Task<Void, Error>, timeoutNs: UInt64) async -> Outcome? {
        await withCheckedContinuation { (cont: CheckedContinuation<Outcome?, Never>) in
            let once = ResumeOnce(cont)
            Task {
                do {
                    try await task.value
                    once.resume(returning: .succeeded)
                } catch {
                    once.resume(returning: .failed(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                once.resume(returning: nil)
            }
        }
    }
}
