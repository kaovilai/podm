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
