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
            // The pruned instance's Docker id, captured BEFORE prune: it
            // derives from the bundle's on-disk creation date, which is
            // gone (or belongs to a same-name replacement) once the
            // container is deleted — recomputing it after prune can
            // produce a fallback id or the REPLACEMENT's id, defeating the
            // destroy dedup and marking the wrong instance finalized.
            let hexIdByNativeId: [String: String] = preSnapshots.reduce(into: [:]) {
                $0[$1.id] = DockerContainerID.hexId(for: $1)
            }
            // Captured EAGERLY: the late-delete cleanup below runs after
            // this request's response has been sent.
            let broadcaster = req.application.storage[EventBroadcasterKey.self]

            /// Instance-scoped, exactly-once cleanup for a container whose
            /// prune delete succeeded LATE — after prune had already given
            /// up on it (wedged apiserver, issue #45). The prune response
            /// went out without this container, so its cleanup and
            /// `destroy` event would otherwise be lost entirely. The shared
            /// `ContainerDestroyCleanup` body (also used by DELETE) runs
            /// the full store teardown — a same-name replacement may exist
            /// by then (native ids are reusable names), and a FAILED
            /// replacement lookup must not read as "no replacement
            /// exists": the replacement's journal and restart state are
            /// preserved unless a successful lookup confirms absence.
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
                    checkForReplacement: true
                )
            }

            let result = try await client.prune(filters: parsedFilters, onLateDelete: finalizeLateDelete)
            // The prune path deletes containers directly through the native
            // client, bypassing the delete/auto-remove cleanup callers — run
            // the SAME full instance-scoped cleanup DELETE runs (cache
            // entries, journal, restart state, rename/policy overrides,
            // destroy event), or a later DELETE 404 fallback for a lingering
            // cached id would find the hex key already marked complete and
            // skip its half of the teardown. The per-container deletes
            // answered inside this request, but this loop trails them by the
            // rest of the prune — a same-name replacement may have been
            // created since the earliest delete — so the replacement check
            // runs here too.
            for containerID in result.deletedContainers {
                let hexId = hexIdByNativeId[containerID] ?? containerID
                let snapshot = snapshotByID[hexId]
                await ContainerDestroyCleanup.finalize(
                    client: client,
                    broadcaster: broadcaster,
                    hexId: hexId,
                    nativeId: containerID,
                    image: snapshot?.configuration.image.reference ?? "",
                    name: snapshot?.id ?? containerID,
                    labels: LabelNormalization.restore(snapshot?.configuration.labels ?? [:]),
                    checkForReplacement: true
                )
            }
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
