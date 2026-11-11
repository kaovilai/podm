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
            // Captured EAGERLY: the late-delete cleanup below runs after
            // this request's response has been sent.
            let broadcaster = req.application.storage[EventBroadcasterKey.self]

            /// Instance-scoped, exactly-once cleanup for a container whose
            /// prune delete succeeded LATE — after prune had already given
            /// up on it (wedged apiserver, issue #45). The prune response
            /// went out without this container, so its journal teardown and
            /// `destroy` event would otherwise be lost entirely. A same-name
            /// replacement may exist by then (native ids are reusable
            /// names): the replacement's journal must survive, so the
            /// native-keyed teardown is skipped when one is found.
            let finalizeLateDelete: @Sendable (_ nativeId: String, _ hexId: String) async -> Void = { nativeId, hexId in
                await ContainerDestroyFinalizer.shared.finalizeOnce(key: hexId) {
                    let replacement: ContainerSnapshot? = (try? await client.getContainer(id: nativeId)) ?? nil
                    if replacement == nil {
                        await ContainerLogFollower.teardown(nativeId: nativeId)
                    }
                    let snapshot = snapshotByID[nativeId]
                    await broadcaster?.broadcast(
                        DockerEvent.simpleEvent(
                            id: nativeId, type: "container", status: "destroy",
                            image: snapshot?.configuration.image.reference ?? "",
                            name: snapshot?.id ?? nativeId,
                            labels: LabelNormalization.restore(snapshot?.configuration.labels ?? [:])))
                }
            }

            let result = try await client.prune(filters: parsedFilters, onLateDelete: finalizeLateDelete)
            // The prune path deletes containers directly through the native
            // client, bypassing the delete/auto-remove cleanup callers — tear
            // down each pruned container's log journal along with it, or its
            // journal file lingers with no sweep to remove it.
            for containerID in result.deletedContainers {
                await ContainerLogFollower.teardown(nativeId: containerID)
            }
            if let broadcaster = broadcaster {
                // moby fires a `destroy` per removed container before the aggregate prune.
                // Gated on the container's hex id: a container deleted late by an
                // earlier wedged prune (or DELETE) must not get a second destroy event.
                for containerID in result.deletedContainers {
                    let snapshot = snapshotByID[containerID]
                    let hexId = snapshot.map { DockerContainerID.hexId(for: $0) } ?? containerID
                    await ContainerDestroyFinalizer.shared.finalizeOnce(key: hexId) {
                        await broadcaster.broadcast(
                            DockerEvent.simpleEvent(
                                id: containerID,
                                type: "container",
                                status: "destroy",
                                image: snapshot?.configuration.image.reference ?? "",
                                name: snapshot?.id ?? containerID,
                                labels: LabelNormalization.restore(snapshot?.configuration.labels ?? [:])))
                    }
                }
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
