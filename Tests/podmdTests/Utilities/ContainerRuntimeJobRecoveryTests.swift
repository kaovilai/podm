import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import podmd

/// Regression tests for issue #45: `DELETE /containers/{id}` (and the
/// force-stop before it) used to hang forever against an Apple Container
/// apiserver wedged behind a container whose per-container runtime launchd
/// job is stuck (`state = spawn scheduled`, `last exit code = 78: EX_CONFIG`
/// — e.g. its program was deleted with the Homebrew keg the services were
/// started from). The apiserver performs those XPC round trips with no
/// timeout (apple/container#1884), so podmd's await never returns; a podmd
/// restart does not help because the wedge lives in the apiserver.
///
/// The blocking interaction under test, modeled with the `WedgeGate` below:
/// the delete's XPC await never completes while the job is wedged, and
/// completes as soon as the job is booted out of launchd (`launchctl
/// bootout`, here the injected hook). Before the fix there was no timeout
/// and no bootout — the equivalent plain `await gate.wait()` never returns,
/// and these tests fail by hitting their time limit instead of passing.
@Suite("ContainerRuntimeJobRecovery — wedged runtime job (issue #45)")
struct ContainerRuntimeJobRecoveryTests {
    @Test("launchd labels mirror apple/container's per-container job registration")
    func labelFormat() {
        #expect(
            ContainerRuntimeJobRecovery.launchdServiceLabel(
                runtimeHandler: "container-runtime-linux", nativeId: "native-1"
            ) == "com.apple.container.container-runtime-linux.native-1")
        let qualified = ContainerRuntimeJobRecovery.domainQualifiedLabel(
            runtimeHandler: "container-runtime-linux", nativeId: "native-1")
        #expect(qualified.hasPrefix("gui/"))
        #expect(qualified.hasSuffix("/com.apple.container.container-runtime-linux.native-1"))
    }

    @Test(
        "a hung delete completes once the wedged runtime job is booted out",
        .timeLimit(.minutes(1))
    )
    func hungOperationCompletesAfterBootout() async throws {
        let gate = WedgeGate()
        let bootouts = BootoutLog()
        try await ContainerRuntimeJobRecovery.withHangRecovery(
            nativeId: "native-1",
            runtimeHandler: "container-runtime-linux",
            firstWindowNs: 50_000_000,
            secondWindowNs: 5_000_000_000,
            bootout: { label in
                bootouts.record(label)
                // The bootout unwedges the apiserver: its queued delete
                // (still awaiting in the operation task) now completes.
                gate.open()
                return 0
            }
        ) {
            // Stands in for the XPC delete against the wedged apiserver:
            // without the recovery this await never returns (issue #45).
            await gate.wait()
        }
        let labels = bootouts.labels
        #expect(labels.count == 1, "exactly one recovery bootout")
        #expect(labels.first?.hasSuffix("com.apple.container.container-runtime-linux.native-1") == true)
    }

    @Test(
        "a delete that stays hung after the bootout fails with the wedged error, bounded",
        .timeLimit(.minutes(1))
    )
    func stillHungAfterBootoutThrowsWedged() async throws {
        let gate = WedgeGate()
        let bootouts = BootoutLog()
        do {
            try await ContainerRuntimeJobRecovery.withHangRecovery(
                nativeId: "native-2",
                runtimeHandler: "container-runtime-linux",
                firstWindowNs: 50_000_000,
                secondWindowNs: 50_000_000,
                bootout: { label in
                    bootouts.record(label)
                    return 0  // the bootout alone does not unwedge this apiserver
                }
            ) {
                await gate.wait()  // never opened — the delete never answers
            }
            Issue.record("expected runtimeJobWedged")
        } catch ClientContainerError.runtimeJobWedged(let nativeId, _) {
            #expect(nativeId == "native-2")
        }
        // The wedged error is thrown at the second-window deadline, which
        // can land BEFORE the bootout task's registry hop gets scheduled
        // under load — the bootout is not suppressed (the operation never
        // finished), so it arrives shortly after. Wait for it rather than
        // asserting it synchronously.
        await waitForCondition(timeoutNs: 10_000_000_000) { bootouts.labels.count == 1 }
        let labels = bootouts.labels
        #expect(labels.count == 1, "the recovery was attempted exactly once")
        #expect(labels.first?.hasSuffix("com.apple.container.container-runtime-linux.native-2") == true)
    }

    @Test("a wedged error carries the container and job label")
    func wedgedErrorPayload() async throws {
        do {
            try await ContainerRuntimeJobRecovery.withHangRecovery(
                nativeId: "native-3",
                runtimeHandler: "container-runtime-linux",
                firstWindowNs: 50_000_000,
                secondWindowNs: 50_000_000,
                bootout: { _ in 0 }
            ) {
                try await Task.sleep(nanoseconds: 10_000_000_000)  // outlives both windows
            }
            Issue.record("expected runtimeJobWedged")
        } catch let ClientContainerError.runtimeJobWedged(nativeId, label) {
            #expect(nativeId == "native-3")
            #expect(label.hasSuffix("com.apple.container.container-runtime-linux.native-3"))
        }
    }

    @Test("a promptly completing operation passes through without recovery")
    func fastOperationSkipsRecovery() async throws {
        let bootouts = BootoutLog()
        try await ContainerRuntimeJobRecovery.withHangRecovery(
            nativeId: "native-4",
            runtimeHandler: "container-runtime-linux",
            firstWindowNs: 5_000_000_000,
            secondWindowNs: 5_000_000_000,
            bootout: { label in
                bootouts.record(label)
                return 0
            }
        ) {}
        let labels = bootouts.labels
        #expect(labels.isEmpty, "a healthy delete must never touch launchd")
    }

    @Test("an operation error propagates as-is, without recovery")
    func operationErrorPropagates() async throws {
        let bootouts = BootoutLog()
        do {
            try await ContainerRuntimeJobRecovery.withHangRecovery(
                nativeId: "native-5",
                runtimeHandler: "container-runtime-linux",
                firstWindowNs: 5_000_000_000,
                secondWindowNs: 5_000_000_000,
                bootout: { label in
                    bootouts.record(label)
                    return 0
                }
            ) {
                throw ClientContainerError.notFound(id: "native-5")
            }
            Issue.record("expected the operation error to propagate")
        } catch ClientContainerError.notFound(let id) {
            #expect(id == "native-5")
        }
        let labels = bootouts.labels
        #expect(labels.isEmpty, "a failed operation must not trigger a bootout")
    }

    @Test("a slow-but-healthy operation finishing inside the first window is not recovered")
    func slowHealthyOperationNotRecovered() async throws {
        let bootouts = BootoutLog()
        try await ContainerRuntimeJobRecovery.withHangRecovery(
            nativeId: "native-6",
            runtimeHandler: "container-runtime-linux",
            firstWindowNs: 5_000_000_000,
            secondWindowNs: 5_000_000_000,
            bootout: { label in
                bootouts.record(label)
                return 0
            }
        ) {
            try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms — well inside the window
        }
        let labels = bootouts.labels
        #expect(labels.isEmpty)
    }

    // MARK: review round 1 — concurrent second window / bounded bootout

    @Test(
        "the second window runs concurrently with the bootout — a stalled launchctl cannot delay completion",
        .timeLimit(.minutes(1))
    )
    func secondWindowConcurrentWithStalledBootout() async throws {
        let gate = WedgeGate()
        let bootouts = BootoutLog()
        let hookRelease = DispatchSemaphore(value: 0)
        try await ContainerRuntimeJobRecovery.withHangRecovery(
            nativeId: "native-7",
            runtimeHandler: "container-runtime-linux",
            firstWindowNs: 50_000_000,
            secondWindowNs: 5_000_000_000,
            bootout: { label in
                bootouts.record(label)
                gate.open()  // the bootout unwedges the apiserver...
                // ...but launchctl itself stalls and never returns. The old
                // code awaited the bootout before the second window, so a
                // stalled hook hung the DELETE forever even though the
                // operation had completed.
                hookRelease.wait()
                return 0
            }
        ) {
            await gate.wait()
        }
        #expect(bootouts.labels.count == 1, "exactly one recovery bootout was attempted")
        // Reaching here proves the recovery returned while the hook was
        // STILL blocked — the bootout is fire-and-forget, not a deadline gate.
        hookRelease.signal()
    }

    @Test(
        "a stalled bootout does not delay the wedged error — the response stays bounded",
        .timeLimit(.minutes(1))
    )
    func stalledBootoutDoesNotDelayWedgedError() async throws {
        let gate = WedgeGate()
        let hookRelease = DispatchSemaphore(value: 0)
        do {
            try await ContainerRuntimeJobRecovery.withHangRecovery(
                nativeId: "native-8",
                runtimeHandler: "container-runtime-linux",
                firstWindowNs: 50_000_000,
                secondWindowNs: 50_000_000,
                bootout: { _ in
                    hookRelease.wait()  // launchctl never answers
                    return 0
                }
            ) {
                await gate.wait()  // never opened — the delete never answers
            }
            Issue.record("expected runtimeJobWedged")
        } catch ClientContainerError.runtimeJobWedged(let nativeId, _) {
            #expect(nativeId == "native-8")
        }
        // The wedged error must arrive after the second window, not after
        // the (still-blocked) bootout hook.
        hookRelease.signal()
    }

    @Test("a stalled recovery subprocess is terminated after its cap")
    func boundedBootoutTerminatesStalledSubprocess() throws {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let started = Date()
        let status = ContainerRuntimeJobRecovery.runBounded(process, capNs: 100_000_000)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 5, "the cap must bound the wait (took \(elapsed)s)")
        #expect(!process.isRunning, "the stalled subprocess must have been terminated")
        #expect(status != 0, "a terminated sleep reports a signal status, not success")
    }

    // MARK: review round 1 — admission-scoped guard (the delete path's force-stop)

    @Test(
        "a force-stop queued behind healthy VM transitions is never mistaken for a wedge",
        .timeLimit(.minutes(1))
    )
    func queuedForceStopBehindHealthyBacklogIsNotRecovered() async throws {
        let bootouts = BootoutLog()
        let admission = VMLifecycleAdmission(limit: 1)
        // Occupy the only admission slot with a healthy-but-slow transition.
        let holderStarted = WedgeGate()
        let holder = Task<Void, Never> {
            try? await admission.withSlot {
                holderStarted.open()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        await holderStarted.wait()  // the backlog definitively holds the slot
        // The force-stop queues behind the backlog; its wedge window (50 ms)
        // is far shorter than the backlog (300 ms). With the guard OUTSIDE
        // admission (the old route-level wrap), the timer ran while queued
        // and fired a bootout outside the limiter; scoped inside, it starts
        // only once the stop is executing — and completes cleanly.
        try await ClientContainerService.withAdmissionScopedRecovery(
            container: Self.snapshot(id: "native-9", status: .running),
            admission: admission,
            firstWindowNs: 50_000_000,
            secondWindowNs: 5_000_000_000,
            bootout: { label in
                bootouts.record(label)
                return 0
            }
        ) {}
        await holder.value
        #expect(bootouts.labels.isEmpty, "a queued-but-healthy stop must not trigger a bootout")
    }

    @Test(
        "a wedged force-stop releases its admission slot when it reports wedged",
        .timeLimit(.minutes(1))
    )
    func wedgedForceStopReleasesAdmissionSlot() async throws {
        let gate = WedgeGate()
        let admission = VMLifecycleAdmission(limit: 1)
        do {
            try await ClientContainerService.withAdmissionScopedRecovery(
                container: Self.snapshot(id: "native-10", status: .running),
                admission: admission,
                firstWindowNs: 50_000_000,
                secondWindowNs: 50_000_000,
                bootout: { _ in 0 }
            ) {
                await gate.wait()  // never opened — the stop never answers
            }
            Issue.record("expected runtimeJobWedged")
        } catch ClientContainerError.runtimeJobWedged(let nativeId, _) {
            #expect(nativeId == "native-10")
        }
        // The slot must be free again: the wedged error releasing the
        // admission is what keeps one stuck container from queueing every
        // later create/start/stop behind it. If the slot leaked, this wait
        // never returns and the test fails on its time limit.
        let acquired = WedgeGate()
        Task<Void, Never> {
            try? await admission.withSlot { acquired.open() }
        }
        await acquired.wait()
    }

    // MARK: review round 2 — bounded admission wait (all slots wedged)

    @Test(
        "a force-stop queued behind wedged slot-holders fails bounded instead of hanging",
        .timeLimit(.minutes(1))
    )
    func allSlotsWedgedForceStopFailsBounded() async throws {
        let bootouts = BootoutLog()
        let admission = VMLifecycleAdmission(limit: 1)
        // A wedged ordinary stop: holds the only slot forever. Before the
        // fix, the force-delete queued behind it FOREVER — before either
        // recovery window started.
        let holderStarted = WedgeGate()
        let holderNeverEnds = WedgeGate()  // never opened
        let holder = Task<Void, Never> {
            try? await admission.withSlot {
                holderStarted.open()
                await holderNeverEnds.wait()
            }
        }
        await holderStarted.wait()
        _ = holder  // deliberately never awaited — it models the wedge

        let startedAt = Date()
        do {
            try await ClientContainerService.withAdmissionScopedRecovery(
                container: Self.snapshot(id: "native-adm", status: .running),
                admission: admission,
                firstWindowNs: 5_000_000_000,
                secondWindowNs: 5_000_000_000,
                admissionQueueTimeoutNs: 50_000_000,
                bootout: { label in
                    bootouts.record(label)
                    return 0
                }
            ) {}
            Issue.record("expected admissionTimedOut")
        } catch ClientContainerError.admissionTimedOut(let nativeId) {
            #expect(nativeId == "native-adm")
        }
        #expect(Date().timeIntervalSince(startedAt) < 5, "the admission wait must be bounded")
        #expect(bootouts.labels.isEmpty, "the recovery must never start while still queued")
    }

    @Test(
        "a healthy backlog still admits the force-stop within the admission deadline",
        .timeLimit(.minutes(1))
    )
    func healthyBacklogAdmittedWithinDeadline() async throws {
        let bootouts = BootoutLog()
        let admission = VMLifecycleAdmission(limit: 1)
        let holderStarted = WedgeGate()
        let releaseHolder = WedgeGate()
        let holder = Task<Void, Never> {
            try? await admission.withSlot {
                holderStarted.open()
                await releaseHolder.wait()
            }
        }
        await holderStarted.wait()
        // Release the backlog shortly after the force-stop queues — well
        // inside the admission deadline.
        Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 100_000_000)
            releaseHolder.open()
        }
        try await ClientContainerService.withAdmissionScopedRecovery(
            container: Self.snapshot(id: "native-adm2", status: .running),
            admission: admission,
            firstWindowNs: 5_000_000_000,
            secondWindowNs: 5_000_000_000,
            admissionQueueTimeoutNs: 5_000_000_000,
            bootout: { label in
                bootouts.record(label)
                return 0
            }
        ) {}
        await holder.value
        #expect(bootouts.labels.isEmpty, "a healthy queued stop must not trigger a bootout")
    }

    // MARK: review round 2 — bootout/replace coordination (reusable native ids)

    @Test("a bootout that has not STARTED is suppressed when its operation finishes")
    func unstartedBootoutSuppressedWhenOperationFinishes() async throws {
        let registry = ContainerRuntimeJobRecovery.OutstandingBootoutRegistry()
        let label = "gui/501/com.apple.container.container-runtime-linux.reg-1"
        let token = await registry.schedule(label: label)
        #expect(await registry.isClear(label: label) == false, "a scheduled bootout is outstanding")

        // The operation finished before the bootout task ever started —
        // a same-name replacement may already own the runtime job.
        await registry.operationFinished(label: label, token: token)
        #expect(await registry.isClear(label: label), "a suppressed bootout leaves nothing outstanding")
        #expect(await registry.starting(label: label, token: token) == false, "the suppressed bootout must not run")
    }

    @Test("an already-started bootout runs to completion; the finished operation cannot stop it")
    func startedBootoutRunsToCompletion() async throws {
        let registry = ContainerRuntimeJobRecovery.OutstandingBootoutRegistry()
        let label = "gui/501/com.apple.container.container-runtime-linux.reg-2"
        let token = await registry.schedule(label: label)
        #expect(await registry.starting(label: label, token: token) == true, "an unclaimed bootout starts")

        // The operation finishing mid-bootout must not cancel it — it is
        // already in flight against launchd.
        await registry.operationFinished(label: label, token: token)
        #expect(await registry.isClear(label: label) == false, "a running bootout stays outstanding")

        await registry.bootoutFinished(label: label)
        #expect(await registry.isClear(label: label))
    }

    @Test("waitUntilClear blocks while a bootout is outstanding and resumes when it finishes")
    func waitUntilClearBlocksAndResumes() async throws {
        let registry = ContainerRuntimeJobRecovery.OutstandingBootoutRegistry()
        let label = "gui/501/com.apple.container.container-runtime-linux.reg-3"
        let token = await registry.schedule(label: label)
        _ = await registry.starting(label: label, token: token)

        let resumed = AtomicFlag()
        let waiter = Task<Void, Never> {
            await registry.waitUntilClear(label: label)
            resumed.set()
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(resumed.isSet() == false, "create/start must stay blocked while the bootout is outstanding")

        await registry.bootoutFinished(label: label)
        await waiter.value
        #expect(resumed.isSet(), "the waiter resumes once the bootout finishes")
    }

    @Test(
        "a started recovery bootout blocks same-name reuse until it finishes",
        .timeLimit(.minutes(1))
    )
    func startedBootoutBlocksSameNameReuseUntilFinished() async throws {
        // Native ids are reusable names: DELETE succeeded within the second
        // window while the recovery bootout (started at the first window)
        // is still running. A create/start of the SAME native id must wait.
        let gate = WedgeGate()
        let bootouts = BootoutLog()
        let hookRelease = DispatchSemaphore(value: 0)
        try await ContainerRuntimeJobRecovery.withHangRecovery(
            nativeId: "native-reuse",
            runtimeHandler: "container-runtime-linux",
            firstWindowNs: 50_000_000,
            secondWindowNs: 5_000_000_000,
            bootout: { label in
                bootouts.record(label)
                gate.open()  // the bootout unwedges the apiserver...
                // ...but launchctl itself is still answering. A same-name
                // replacement created right after the DELETE response must
                // not have its runtime job booted out by THIS in-flight
                // bootout.
                hookRelease.wait()
                return 0
            }
        ) {
            await gate.wait()
        }
        #expect(bootouts.labels.count == 1, "the bootout started before the operation finished and must run")

        // create/start of the same native id: must block while the bootout
        // is still in flight...
        let resumed = AtomicFlag()
        let reuse = Task<Void, Never> {
            await ContainerRuntimeJobRecovery.awaitNoOutstandingBootout(
                nativeId: "native-reuse", runtimeHandler: "container-runtime-linux")
            resumed.set()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(resumed.isSet() == false, "same-name create/start must wait for the in-flight bootout")

        // ...and proceed once it finishes.
        hookRelease.signal()
        await reuse.value
        #expect(resumed.isSet())
    }

    // MARK: review round 2 — expiry at the final deadline (reconnect retries)

    @Test(
        "the final deadline marks the recovery expired so reconnect retries are refused",
        .timeLimit(.minutes(1))
    )
    func finalDeadlineExpiresRecovery() async throws {
        let gate = WedgeGate()
        let expiry = ContainerRuntimeJobRecovery.RecoveryExpiry()
        #expect(expiry.isExpired == false)
        #expect(expiry.retryPermit(), "the permit must allow retries before the deadline")
        do {
            try await ContainerRuntimeJobRecovery.withHangRecovery(
                nativeId: "native-exp",
                runtimeHandler: "container-runtime-linux",
                firstWindowNs: 50_000_000,
                secondWindowNs: 50_000_000,
                bootout: { _ in 0 },
                expiry: expiry
            ) {
                await gate.wait()  // never opened
            }
            Issue.record("expected runtimeJobWedged")
        } catch ClientContainerError.runtimeJobWedged {}
        #expect(expiry.isExpired == true, "reconnect retries must be refused after the final deadline")
        #expect(expiry.retryPermit() == false)
    }

    @Test("an operation completing within the windows never expires its recovery")
    func healthyRecoveryNeverExpires() async throws {
        let expiry = ContainerRuntimeJobRecovery.RecoveryExpiry()
        try await ContainerRuntimeJobRecovery.withHangRecovery(
            nativeId: "native-exp2",
            runtimeHandler: "container-runtime-linux",
            firstWindowNs: 5_000_000_000,
            secondWindowNs: 5_000_000_000,
            bootout: { _ in 0 },
            expiry: expiry
        ) {}
        #expect(expiry.isExpired == false)
    }

    // MARK: review round 2 — late success after the wedged error

    @Test(
        "a delete that succeeds after the wedged error runs onLateSuccess",
        .timeLimit(.minutes(1))
    )
    func lateSuccessRunsOnLateSuccess() async throws {
        let gate = WedgeGate()
        let lateRan = WedgeGate()
        do {
            try await ContainerRuntimeJobRecovery.withHangRecovery(
                nativeId: "native-late",
                runtimeHandler: "container-runtime-linux",
                firstWindowNs: 50_000_000,
                secondWindowNs: 50_000_000,
                bootout: { _ in 0 },
                onLateSuccess: { lateRan.open() }
            ) {
                await gate.wait()  // the delete hangs past both windows...
            }
            Issue.record("expected runtimeJobWedged")
        } catch ClientContainerError.runtimeJobWedged {}
        // ...then the operator restarts the wedged apiserver and the
        // abandoned delete finally completes — the caller's cleanup must
        // still run (rename reservations, journals, destroy event).
        gate.open()
        await lateRan.wait()  // bounded by the test's time limit, not forever
    }

    @Test(
        "a late failure does not run onLateSuccess",
        .timeLimit(.minutes(1))
    )
    func lateFailureSkipsOnLateSuccess() async throws {
        let gate = WedgeGate()
        let lateRan = AtomicFlag()
        do {
            try await ContainerRuntimeJobRecovery.withHangRecovery(
                nativeId: "native-late2",
                runtimeHandler: "container-runtime-linux",
                firstWindowNs: 50_000_000,
                secondWindowNs: 50_000_000,
                bootout: { _ in 0 },
                onLateSuccess: { lateRan.set() }
            ) {
                await gate.wait()
                // The abandoned delete eventually FAILS (e.g. the container
                // was removed by another path while this one was stuck).
                throw ClientContainerError.notFound(id: "native-late2")
            }
            Issue.record("expected runtimeJobWedged")
        } catch ClientContainerError.runtimeJobWedged {}
        gate.open()
        // Give the late watcher time to observe the failure.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(lateRan.isSet() == false, "only a late SUCCESS runs the cleanup hook")
    }

    @Test("an in-window success never runs onLateSuccess")
    func inWindowSuccessSkipsOnLateSuccess() async throws {
        let lateRan = AtomicFlag()
        try await ContainerRuntimeJobRecovery.withHangRecovery(
            nativeId: "native-late3",
            runtimeHandler: "container-runtime-linux",
            firstWindowNs: 5_000_000_000,
            secondWindowNs: 5_000_000_000,
            bootout: { _ in 0 },
            onLateSuccess: { lateRan.set() }
        ) {}
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(lateRan.isSet() == false, "the normal success path owns its own cleanup")
    }

    // MARK: review round 1 (PR #57) — completion recorded by the operation itself

    @Test("the operation's completion latch is marked the moment the operation finishes")
    func operationCompletionLatchMarksOnFinish() async throws {
        let completion = ContainerRuntimeJobRecovery.OperationCompletion()
        #expect(completion.isFinished == false, "not finished before the operation runs")
        let gate = WedgeGate()
        let task = Task<Void, Error> {
            defer { completion.markFinished() }
            await gate.wait()
        }
        #expect(completion.isFinished == false, "still running while the operation is suspended")
        gate.open()
        try await task.value
        #expect(completion.isFinished, "marked synchronously with the operation's completion")
    }

    @Test(
        "a bootout whose operation already finished is suppressed at claim time",
        .timeLimit(.minutes(1))
    )
    func bootoutSuppressedWhenOperationAlreadyFinished() async throws {
        let registry = ContainerRuntimeJobRecovery.OutstandingBootoutRegistry()
        let label = "gui/501/com.apple.container.container-runtime-linux.reg-fin"
        let token = await registry.schedule(label: label)
        let completion = ContainerRuntimeJobRecovery.OperationCompletion()
        // The operation finished after the first timer won but before the
        // bootout task claimed its token — the claim must see the latch and
        // refuse to run, or the bootout could kill a same-name
        // replacement's freshly-registered runtime job.
        completion.markFinished()
        let bootouts = BootoutLog()
        let status = await ContainerRuntimeJobRecovery.runRegisteredBootout(
            registry: registry,
            label: label,
            token: token,
            completion: completion,
            bootout: { label in
                bootouts.record(label)
                return 0
            }
        )
        #expect(status == 0)
        #expect(bootouts.labels.isEmpty, "the hook must not run for a finished operation")
        #expect(await registry.isClear(label: label), "the suppressed bootout leaves nothing outstanding")
    }

    @Test(
        "a bootout whose operation is still in flight claims and runs",
        .timeLimit(.minutes(1))
    )
    func bootoutRunsWhileOperationInFlight() async throws {
        let registry = ContainerRuntimeJobRecovery.OutstandingBootoutRegistry()
        let label = "gui/501/com.apple.container.container-runtime-linux.reg-run"
        let token = await registry.schedule(label: label)
        let completion = ContainerRuntimeJobRecovery.OperationCompletion()
        #expect(completion.isFinished == false, "the operation is still wedged")
        let bootouts = BootoutLog()
        let status = await ContainerRuntimeJobRecovery.runRegisteredBootout(
            registry: registry,
            label: label,
            token: token,
            completion: completion,
            bootout: { label in
                bootouts.record(label)
                return 0
            }
        )
        #expect(status == 0)
        #expect(bootouts.labels.count == 1, "the bootout runs for a still-wedged operation")
        #expect(await registry.isClear(label: label), "the finished bootout leaves nothing outstanding")
    }

    private static func snapshot(id: String, status: RuntimeStatus) -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index+json",
                digest: "sha256:abc", size: 0
            )
        )
        let config = ContainerConfiguration(id: id, image: img, process: proc)
        return ContainerSnapshot(configuration: config, status: status, networks: [])
    }
}

/// A one-shot latch: `wait()` suspends until `open()`. The test stand-in for
/// an apiserver XPC reply that only arrives once the wedged runtime job has
/// been booted out of launchd.
private final class WedgeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func open() {
        lock.lock()
        opened = true
        let cont = waiter
        waiter = nil
        lock.unlock()
        cont?.resume()
    }

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if opened {
                lock.unlock()
                cont.resume()
                return
            }
            waiter = cont
            lock.unlock()
        }
    }
}

/// Records the labels the recovery booted out. Lock-guarded (not an actor)
/// because the injected bootout hook is synchronous.
private final class BootoutLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedLabels: [String] = []

    var labels: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedLabels
    }

    func record(_ label: String) {
        lock.lock()
        recordedLabels.append(label)
        lock.unlock()
    }
}

/// A lock-guarded boolean flag, observable from synchronous closures.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func isSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Polls `condition` until it holds or `timeoutNs` elapses (the recovery
/// bootout task reaches its hook via a GCD dispatch plus registry hops, so
/// under parallel-suite load it can trail the deadline error by a moment).
private func waitForCondition(
    timeoutNs: UInt64,
    intervalNs: UInt64 = 25_000_000,
    _ condition: @Sendable () -> Bool
) async {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutNs) / 1_000_000_000)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: intervalNs)
    }
}
