import ContainerAPIClient
import ContainerResource
import Vapor

struct RESTContainerPruneQuery: Content {
    let filters: String?
}

struct RESTContainerPruneResponse: Content {
    let ContainersDeleted: [String]
    let SpaceReclaimed: Int64
}

struct ContainerPruneRoute: RouteCollection {
    let client: ClientContainerProtocol
    /// Per-finalize replacement-lookup budget for this route's cleanup;
    /// injectable so tests can shrink it. Production uses the shared
    /// default.
    var replacementLookupTimeoutNs: UInt64 = ContainerDestroyCleanup.replacementLookupTimeoutNs

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/prune", use: handler)
    }
}

extension ContainerPruneRoute {
    func handler(req: Request) async throws -> RESTContainerPruneResponse {
        let query = try req.query.decode(RESTContainerPruneQuery.self)
        let logger = req.logger

        let parsedFilters = try DockerContainerFilterUtility.parseContainerPruneFilters(filtersParam: query.filters, logger: logger)

        do {
            // Capture snapshots before pruning so the per-container `destroy` events can
            // carry image/name/labels (moby emits a `destroy` per removed container, then
            // the aggregate `prune`). The container is gone by the time prune() returns.
            let preSnapshots = (try? await client.list(showAll: true, filters: [:])) ?? []
            // An immutable let (built via reduce) so the late-delete
            // closure below can capture it from concurrently-executing code.
            let snapshotByID: [String: ContainerSnapshot] = preSnapshots.reduce(into: [:]) {
                $0[DockerContainerID.hexId(for: $1)] = $1
                $0[$1.id] = $1
            }
            // NOTE: per-instance identity for the cleanup below comes from
            // the SERVICE's captured pre-delete hex IDs (onDelete /
            // onLateDelete hooks) — NOT from a route-local map: the route's
            // list predates the prune, so a container created in between
            // would be missing from any map built here, and a fallback to
            // the native id would key the finalizer wrong.
            // Captured EAGERLY: the late-delete cleanup below runs after
            // this request's response has been sent.
            let broadcaster = req.application.storage[EventBroadcasterKey.self]

            /// Instance-scoped, exactly-once cleanup for a pruned container —
            /// used BOTH for in-window deletes (the service's onDelete hook,
            /// carrying its captured pre-delete hex ID) and for deletes that
            /// succeeded LATE, after prune had already given up on the
            /// container (wedged apiserver, issue #45 — the prune response
            /// went out without it, so its cleanup and `destroy` event would
            /// otherwise be lost entirely). The shared
            /// `ContainerDestroyCleanup` body (also used by DELETE) runs
            /// the full store teardown — a same-name replacement may exist
            /// by then (native ids are reusable names), and a FAILED
            /// replacement lookup must not read as "no replacement
            /// exists": the replacement's journal and restart state are
            /// preserved unless a successful lookup confirms absence.
            // One shared lookup-health flag covers the WHOLE request: once
            // one finalize's replacement lookup times out (the apiserver
            // stopped answering), later finalizes skip the lookup and treat
            // the native id as unanswered — without this, a prune of N
            // containers could stall N × the lookup timeout in lookups
            // alone; with it, the worst case is ≈ one timeout per request.
            let lookupHealth = ContainerDestroyCleanup.ReplacementLookupHealth()
            let finalizeLateDelete: @Sendable (_ nativeId: String, _ hexId: String) async -> Void = { nativeId, hexId in
                let snapshot = snapshotByID[hexId] ?? snapshotByID[nativeId]
                await ContainerDestroyCleanup.finalize(
                    client: client,
                    broadcaster: broadcaster,
                    hexId: hexId,
                    nativeId: nativeId,
                    image: snapshot?.configuration.image.reference ?? "",
                    name: snapshot?.id ?? nativeId,
                    labels: LabelNormalization.restore(snapshot?.configuration.labels ?? [:]),
                    checkForReplacement: true,
                    replacementLookupTimeoutNs: replacementLookupTimeoutNs,
                    lookupHealth: lookupHealth
                )
            }

            // The per-container in-window cleanup runs through the service's
            // onDelete hook (identity captured pre-delete on the service
            // side); the late path through onLateDelete. Both run the SAME
            // full instance-scoped cleanup DELETE runs — cache entries,
            // journal, restart state, rename/policy overrides, destroy event
            // — behind the same hex-keyed finalizer gate, with the
            // replacement check (this cleanup trails the earliest per-
            // container deletes by the rest of the prune).
            let result = try await client.prune(
                filters: parsedFilters,
                onLateDelete: finalizeLateDelete,
                onDelete: finalizeLateDelete)
            if let broadcaster = broadcaster {
                // The aggregate prune event carries an empty Actor.ID and the bytes reclaimed.
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "container", action: "prune", actorID: "",
                        attributes: ["reclaimed": String(result.spaceReclaimed)]))
            }
            return RESTContainerPruneResponse(
                ContainersDeleted: result.deletedContainers,
                SpaceReclaimed: result.spaceReclaimed
            )
        } catch {
            req.logger.error("Failed to prune containers: \(error)")
            throw Abort(.internalServerError, reason: "Failed to prune containers: \(error.localizedDescription)")
        }
    }
}
