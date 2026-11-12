import Foundation
import Testing

@testable import podmd

/// A synchronous flag readable/writable from any task — the duplicate
/// task records its observation before anyone awaits it.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { self.stored = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        stored = value
    }
}

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

    @Test("a call that arrives while the body is running waits for it, without re-running it")
    func inFlightCallWaitsWithoutRerunning() async throws {
        let finalizer = ContainerDestroyFinalizer()
        let firstStarted = WedgeGate()
        let releaseFirst = WedgeGate()
        let bodyFinished = WedgeGate()

        let first = Task<Void, Never> {
            await finalizer.finalizeOnce(key: "hex-inflight") {
                firstStarted.open()
                await releaseFirst.wait()
                bodyFinished.open()
            }
        }
        await firstStarted.wait()

        // A second finalize for the same key while the first body is still
        // running must not run the body again — and must WAIT for the
        // in-flight one, so its caller cannot answer (e.g. a DELETE 404
        // fallback) before the cleanup has actually finished.
        let duplicateReturnedBeforeCompletion = LockedBox(false)
        let second = Task<Void, Never> {
            await finalizer.finalizeOnce(key: "hex-inflight") { Issue.record("must not run") }
            // Checked INSIDE the duplicate task, immediately after
            // finalizeOnce returns: this is the caller-visible guarantee.
            // (Asserting after `second.value` only proves the body finished
            // EVENTUALLY — it passes even if the duplicate returned early.)
            duplicateReturnedBeforeCompletion.set(!bodyFinished.isOpen)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        releaseFirst.open()
        await first.value
        await second.value
        #expect(
            !duplicateReturnedBeforeCompletion.value,
            "the duplicate returns only after the body finished")
    }

    @Test("a duplicate's return implies the cleanup completed — no 409 window on the rename override")
    func duplicateReturnImpliesCompletion() async throws {
        let finalizer = ContainerDestroyFinalizer()
        let firstStarted = WedgeGate()
        let releaseFirst = WedgeGate()
        let overrideRemoved = WedgeGate()

        let first = Task<Void, Never> {
            await finalizer.finalizeOnce(key: "hex-dup") {
                firstStarted.open()
                await releaseFirst.wait()
                overrideRemoved.open()
            }
        }
        await firstStarted.wait()

        // The DELETE 404 fallback's duplicate finalization: when it returns,
        // the rename override removal (the body's last step here) must have
        // happened — a create of the same name in between would 409.
        let duplicateReturnedBeforeRemoval = LockedBox(false)
        let second = Task<Void, Never> {
            await finalizer.finalizeOnce(key: "hex-dup") {}
            // Checked INSIDE the duplicate task, immediately after return —
            // the caller-visible guarantee (see the sibling test's note).
            duplicateReturnedBeforeRemoval.set(!overrideRemoved.isOpen)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        releaseFirst.open()
        await second.value
        await first.value
        #expect(
            !duplicateReturnedBeforeRemoval.value,
            "the duplicate observes the completed cleanup")
    }
}

/// Minimal one-shot latch, mirroring the private helper in
/// ContainerRuntimeJobRecoveryTests.
private final class WedgeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

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
