import Foundation

/// Performs the full `--rm` cleanup once `ContainerInfoCache.consumeAutoRemove` grants it:
/// DNS alias unregistration, the `destroy` event, and clearing the cache entry. Shared by the
/// three paths that observe a `--rm` container's exit directly — start, attach, attach-WS —
/// since Apple Container reaps `--rm` containers itself and no DELETE ever reaches
/// `ContainerDeleteRoute`.
enum ContainerAutoRemoveCleanup {
    static func perform(
        hexId: String,
        nativeId: String,
        fallbackImage: String,
        fallbackLabels: [String: String],
        dnsServer: PodmDNSServer?,
        broadcaster: EventBroadcaster?
    ) async {
        let cached = await ContainerInfoCache.shared.get(id: hexId)
        let labels = cached?.labels ?? fallbackLabels

        // Answer the CLI's late /start and /wait first: Apple Container reaps a
        // --rm container the moment it exits, so those calls can land after the
        // container is gone (see AutoRemovedContainers). The exit code was
        // recorded at exit, before this cleanup runs.
        let recordedCode: Int32?
        if let hexCode = await ContainerExitCodeStore.shared.get(id: hexId) {
            recordedCode = hexCode
        } else {
            recordedCode = await ContainerExitCodeStore.shared.get(id: nativeId)
        }
        // An unobserved exit (its wait never resolved) still leaves the
        // container gone; the sentinel keeps a late /wait from claiming the run
        // vanished, while the CLI reports the same failure code podm records.
        await AutoRemovedContainers.shared.record(
            hexId: hexId,
            nativeId: nativeId,
            code: recordedCode ?? ContainerExitCodeStore.waitFailureSentinel
        )

        if let dnsServer {
            ContainerAliasCleanup.unregisterAllAliases(
                nativeId: nativeId,
                labels: labels,
                cachedIP: cached?.ip,
                dnsServer: dnsServer,
                effectiveName: await ContainerNameOverrideStore.shared.get(hexId: hexId)
            )
        }
        // A rename's override dies with the container, like the delete route
        // does — otherwise every removed instance grows the persisted map.
        // Read it first so the destroy event can carry the name clients knew.
        let effectiveName = await ContainerNameOverrideStore.shared.get(hexId: hexId)
        await ContainerNameOverrideStore.shared.remove(hexId: hexId)
        // The log journal and its follower die with the container too (the
        // delete route does the same teardown) — otherwise every removed
        // instance leaves a capped-but-orphaned journal behind.
        await ContainerLogFollower.teardown(nativeId: nativeId)
        if let broadcaster {
            await broadcaster.broadcast(
                ContainerAttachRoute.makeAutoRemoveEvent(
                    id: hexId,
                    image: cached?.image ?? fallbackImage,
                    name: effectiveName ?? cached?.nativeId ?? nativeId,
                    labels: labels
                ))
        }
        await ContainerInfoCache.shared.remove(id: hexId)
        await RestartPolicyOverrideStore.shared.remove(id: hexId)
    }
}
