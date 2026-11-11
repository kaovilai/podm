import Foundation
import Testing

@testable import podmd

/// Review round 2 (PR #51): three paths can reach destroy-time cleanup for
/// the same container — the DELETE route's synchronous success, its
/// 404-after-vanish fallback, and the wedge recovery's late-success
/// callback. Exactly one destroy event must fire and the store teardowns
/// must run once.
@Suite("ContainerDestroyFinalizer")
struct ContainerDestroyFinalizerTests {

    @Test("runs the body exactly once per key")
    func runsBodyOnce() async throws {
        let finalizer = ContainerDestroyFinalizer()
        let runs = Counter()
        await finalizer.finalizeOnce(key: "hex-once") { runs.nextSync() }
        await finalizer.finalizeOnce(key: "hex-once") { runs.nextSync() }
        await finalizer.finalizeOnce(key: "hex-once") { runs.nextSync() }
        #expect(runs.countSync() == 1)
    }

    @Test("different keys run independently")
    func differentKeysRunIndependently() async throws {
        let finalizer = ContainerDestroyFinalizer()
        let runs = Counter()
        await finalizer.finalizeOnce(key: "hex-a") { runs.nextSync() }
        await finalizer.finalizeOnce(key: "hex-b") { runs.nextSync() }
        #expect(runs.countSync() == 2)
    }

    @Test("a call that arrives while the body is running is a no-op, not a wait")
    func inFlightCallIsNoOp() async throws {
        let finalizer = ContainerDestroyFinalizer()
        let firstStarted = WedgeGate()
        let releaseFirst = WedgeGate()

        let first = Task<Void, Never> {
            await finalizer.finalizeOnce(key: "hex-inflight") {
                firstStarted.open()
                await releaseFirst.wait()
            }
        }
        await firstStarted.wait()

        // A second finalize for the same key while the first body is still
        // running must not run the body again (and must not block on the
        // in-flight one).
        let second = Task<Void, Never> {
            await finalizer.finalizeOnce(key: "hex-inflight") { Issue.record("must not run") }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        releaseFirst.open()
        await first.value
        await second.value
    }
}

/// Minimal one-shot latch, mirroring the private helper in
/// ContainerRuntimeJobRecoveryTests.
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
