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

    /// Second chance after the recovery bootout. Once the stuck job is gone,
    /// the queued apiserver operations complete near-instantly; anything
    /// still pending after this window is wedged by something else.
    static let secondWindowNs: UInt64 = 10_000_000_000

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
    /// `launchctl bootout` blocks until launchd answers — so callers keep it
    /// off the cooperative pool (`withHangRecovery` runs it on a detached
    /// task). A non-zero status is not fatal: the follow-up window decides
    /// whether the operation recovered.
    static func liveBootout(_ domainQualifiedLabel: String) -> Int32 {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", domainQualifiedLabel]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs a container delete or force-stop with hang detection and
    /// recovery for a wedged runtime job (issue #45).
    ///
    /// The operation is raced against `firstWindowNs`. On timeout the
    /// container's runtime job is booted out of launchd — unwedging the
    /// apiserver so the STILL-RUNNING operation can complete — and the same
    /// operation is awaited for `secondWindowNs` more. The operation task is
    /// deliberately unstructured and never cancelled: its XPC continuation
    /// only resumes on the apiserver's reply (Task cancellation cannot reach
    /// it), and it is exactly the reply we are waiting for once the wedge
    /// clears.
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
        // launchctl bootout blocks; keep the wait off the cooperative pool.
        _ = await Task.detached(priority: .utility) { bootout(label) }.value

        switch await race(task, timeoutNs: secondWindowNs) {
        case .succeeded:
            return
        case .failed(let error):
            throw error
        case nil:
            throw ClientContainerError.runtimeJobWedged(nativeId: nativeId, label: label)
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
