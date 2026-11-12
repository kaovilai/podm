import ContainerAPIClient
import ContainerResource
import Foundation
import Synchronization

/// The full instance-scoped destroy-time cleanup, shared by every removal
/// path — the DELETE route (synchronous success, 404-after-vanish fallback,
/// and the wedge recovery's late-success callback) and the prune route (the
/// post-prune loop and its late-delete callback). All of them funnel through
/// `ContainerDestroyFinalizer` keyed by the container's 64-char hex id, so
/// the cleanup runs exactly once per instance no matter which paths reach
/// it — a prune that marks a hex key complete must not leave a later DELETE
/// 404 fallback unable to perform the store teardowns.
///
/// Everything here is scoped to the DELETED instance: a same-name
/// replacement (native ids are reusable names —
/// `Utility.createContainerID(name:)` passes the container name through)
/// keeps its own cache entries, log journal, restart counter, `--rm` marks
/// and rename override, each keyed by its own hex id or guarded by the
/// replacement check below.
enum ContainerDestroyCleanup {
    /// How long the replacement lookup may take before the cleanup treats
    /// it as unanswered (preserving native-keyed state) instead of hanging
    /// the caller — the prune loop runs this inline between deletes.
    static let replacementLookupTimeoutNs: UInt64 = 10_000_000_000

    /// Races `body` against a deadline; throws `TimeoutError` on expiry.
    /// Unstructured tasks, NOT a task group: a group awaits all children
    /// even after cancelAll, and a body that never completes (a wedged
    /// XPC call ignores cancellation — the same reason withHangRecovery's
    /// operation is unstructured) would hang the group forever. The loser
    /// of the race is simply abandoned.
    static func withTimeout<T: Sendable>(
        _ timeoutNs: UInt64, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // First resume wins; the second is dropped (both race paths run
        // to completion regardless). The continuation lives inside a
        // Sendable once-box — capturing the raw CheckedContinuation (or a
        // claim closure over a mutex) in the @Sendable task bodies trips
        // region-isolation checking on stricter toolchains (Xcode 26.6's
        // release build), while the box's own lock makes resume-once
        // atomic.
        try await withCheckedThrowingContinuation { continuation in
            let resumer = OnceResumer<T>(continuation)
            Task<Void, Never> {
                do {
                    resumer.resumeOnce(.success(try await body()))
                } catch {
                    resumer.resumeOnce(.failure(error))
                }
            }
            Task<Void, Never> {
                try? await Task.sleep(nanoseconds: timeoutNs)
                resumer.resumeOnce(.failure(TimeoutError()))
            }
        }
    }

    /// Resumes a continuation exactly once, from any task. Sendable so it
    /// can be captured by the timeout race's unstructured tasks (the raw
    /// continuation cannot).
    private final class OnceResumer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?

        init(_ continuation: CheckedContinuation<T, any Error>) {
            self.continuation = continuation
        }

        func resumeOnce(_ result: Result<T, any Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    struct TimeoutError: Error {}
    /// - Parameters:
    ///   - hexId: the deleted instance's Docker id — the finalizer key and
    ///     the destroy event's Actor.ID, so destroy matches the id carried
    ///     by create/start/die.
    ///   - nativeId: the deleted instance's native id, when known.
    ///   - checkForReplacement: set on the paths that run AFTER the delete
    ///     answered elsewhere — the 404 fallback, the late wedge-recovery
    ///     success, and the prune loop (whose cleanup trails the per-
    ///     container deletes by the rest of the prune): by then a same-name
    ///     replacement may exist, and the native-keyed teardown below must
    ///     not touch it. The synchronous DELETE path leaves it false: no
    ///     replacement can be created between the delete's reply and this
    ///     cleanup without going through the apiserver's serialization of
    ///     the same name.
    static func finalize(
        client: ClientContainerProtocol,
        broadcaster: EventBroadcaster?,
        hexId: String,
        nativeId: String?,
        image: String,
        name: String,
        labels: [String: String],
        checkForReplacement: Bool,
        replacementLookupTimeoutNs: UInt64 = ContainerDestroyCleanup.replacementLookupTimeoutNs
    ) async {
        await ContainerDestroyFinalizer.shared.finalizeOnce(key: hexId) {
            // A FAILED lookup is not "no replacement exists": a transient
            // apiserver error must not read as confirmed absence, or this
            // cleanup would disarm the follower, drop the journal and reset
            // the restart counter of a LIVE same-name replacement. Only a
            // successful lookup that returns nil proves the native id is
            // unowned; on error the native-keyed state is preserved.
            var nativeIdIsUnowned = true
            if checkForReplacement, let nativeId {
                // BOUNDED: the prune path runs this cleanup inline in its
                // delete loop, and an apiserver that stops answering the
                // lookup would stall the next delete and the whole prune
                // response (only the deletes themselves carry wedge
                // recovery). On expiry — like on error — the native-keyed
                // state is preserved: an unanswered lookup is not
                // "confirmed absence".
                do {
                    nativeIdIsUnowned = try await withTimeout(
                        replacementLookupTimeoutNs
                    ) {
                        try await client.getContainer(id: nativeId) == nil
                    }
                } catch {
                    nativeIdIsUnowned = false
                }
            }
            await ContainerInfoCache.shared.removeInstance(hexId: hexId, nativeId: nativeId)
            if let nativeId, nativeIdIsUnowned {
                // The timestamped log journal dies with the container — keyed
                // by native id, so a recreated container never inherits it.
                await ContainerLogFollower.teardown(nativeId: nativeId)
                // Prevents a container recreated under the same name from
                // inheriting this one's restart-attempt count.
                await ContainerRestartState.shared.reset(id: nativeId)
            }
            await RestartPolicyOverrideStore.shared.remove(id: hexId)
            // A rename's override dies with the container — removal is
            // hygiene (a recreated container gets a fresh hex key), but
            // keeps the persisted map from growing forever. Without it a
            // persisted rename makes creating that name 409 even though
            // its container is gone.
            await ContainerNameOverrideStore.shared.remove(hexId: hexId)
            await broadcaster?.broadcast(
                DockerEvent.simpleEvent(
                    id: hexId, type: "container", status: "destroy",
                    image: image, name: name, labels: labels
                ))
        }
    }
}
