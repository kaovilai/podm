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
