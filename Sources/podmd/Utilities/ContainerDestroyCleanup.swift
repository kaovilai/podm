import ContainerAPIClient
import ContainerResource
import Foundation

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
        checkForReplacement: Bool
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
                do {
                    nativeIdIsUnowned = try await client.getContainer(id: nativeId) == nil
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
