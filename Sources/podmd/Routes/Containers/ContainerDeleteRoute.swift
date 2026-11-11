import ContainerAPIClient
import Vapor

struct ContainerDeleteRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .DELETE, pattern: "/containers/{id}", use: ContainerDeleteRoute.handler(client: client))
    }

}

struct ContainerDeleteQuery: Content {
    var force: Bool?
}

extension ContainerDeleteRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let force = try req.query.decode(ContainerDeleteQuery.self).force ?? false

            let snapshot = try? await client.getContainer(id: id)
            let cached = await ContainerInfoCache.shared.get(id: id)

            let eventImage = snapshot?.configuration.image.reference ?? cached?.image ?? ""
            let eventName = snapshot?.id ?? cached?.nativeId ?? id
            let eventLabels =
                snapshot.map { LabelNormalization.restore($0.configuration.labels) }
                ?? cached?.labels ?? [:]
            // Use the canonical 64-char Docker ID so the destroy event matches the id
            // carried by create/start/die — derived from the snapshot, then the cache,
            // falling back to the request reference only when neither is available.
            let eventId = snapshot.map { DockerContainerID.hexId(for: $0) } ?? cached?.hexId ?? id

            func broadcastRemove() async {
                await ContainerInfoCache.shared.remove(id: id)
                // The timestamped log journal dies with the container — keyed
                // by native id, so a recreated container never inherits it.
                if let nativeId = snapshot?.id ?? cached?.nativeId {
                    await ContainerLogFollower.teardown(nativeId: nativeId)
                }
                // Prevents a container recreated under the same name from inheriting this one's restart-attempt count.
                await ContainerRestartState.shared.reset(id: eventName)
                await RestartPolicyOverrideStore.shared.remove(id: eventId)
                // A rename's override dies with the container — removal is
                // hygiene (a recreated container gets a fresh hex key), but
                // keeps the persisted map from growing forever.
                await ContainerNameOverrideStore.shared.remove(hexId: eventId)
                guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else { return }
                await broadcaster.broadcast(
                    DockerEvent.simpleEvent(
                        id: eventId, type: "container", status: "destroy",
                        image: eventImage, name: eventName, labels: eventLabels
                    ))
            }

            do {
                let container = try await client.getContainer(id: id)

                // Docker Engine API: removing a running container requires force=true.
                // Checked before any side effect (healthcheck stop, DNS cleanup) so a
                // rejected delete leaves the container fully intact. A container still
                // shutting down (.stopping) counts as running, as it does in moby.
                if let container, container.status == .running || container.status == .stopping, !force {
                    throw Abort(
                        .conflict,
                        reason: "cannot remove container \"\(id)\": container is running: stop the container before removing or force remove")
                }

                if let healthManager = req.application.storage[HealthCheckManagerKey.self] {
                    if container == nil {
                        req.logger.warning("healthcheck stop: container not found for id \(id), falling back — loop may be orphaned")
                    }
                    await healthManager.stop(containerId: container?.id ?? id)
                }

                if let container,
                    let dnsServer = req.application.storage[PodmDNSServerKey.self]
                {
                    // Prefer the cached IP — reliable even once the container has genuinely
                    // stopped and Apple Container reports an empty live network list — falling
                    // back to the live snapshot for a container never observed via /start.
                    let containerIP = ContainerStartRoute.dnsAttachmentIP(in: container)
                    ContainerAliasCleanup.unregisterAllAliases(
                        nativeId: container.id,
                        labels: cached?.labels ?? LabelNormalization.restore(container.configuration.labels),
                        cachedIP: cached?.ip ?? containerIP,
                        dnsServer: dnsServer,
                        effectiveName: await ContainerNameOverrideStore.effectiveName(for: container)
                    )
                }

                if let container, container.status == .running {
                    // The force-stop shares the no-timeout XPC path that
                    // wedges the apiserver behind a stuck runtime job
                    // (issue #45) — bound it with the same recovery the
                    // delete uses. Force semantics make booting the job out
                    // (killing the runtime) legitimate here.
                    try await ContainerRuntimeJobRecovery.withHangRecovery(
                        nativeId: container.id,
                        runtimeHandler: container.configuration.runtimeHandler
                    ) {
                        try await client.stop(id: id, signal: nil, timeout: nil)
                    }
                }
                try await client.delete(id: id)
            } catch ClientContainerError.notFound {
                if snapshot != nil || cached != nil {
                    await broadcastRemove()
                }
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
            } catch ClientContainerError.runtimeJobWedged(let nativeId, let label) {
                // The delete never answered even after the recovery booted
                // out the container's runtime job — the apiserver itself is
                // stuck. Tell the operator what to restart, since a podmd
                // restart will not help (issue #45).
                throw Abort(
                    .internalServerError,
                    reason:
                        "container \(nativeId) could not be removed: the Apple Container apiserver did not answer within the recovery window even after clearing its runtime job (\(label)). The apiserver is likely wedged (apple/container#1884), often because its install root was deleted while the services kept running — restart Apple Container services (container system stop && container system start, or brew services restart container) and retry."
                )
            } catch let abort as Abort {
                // A deliberately-thrown Abort (e.g. the running-container-without-force 409)
                // must propagate as-is, not get rewrapped into a 500 by the catch-all below.
                throw abort
            } catch {
                req.logger.error("Failed to delete container \(id): \(error)")
                throw Abort(.internalServerError, reason: "Failed to delete container: \(error)")
            }

            await broadcastRemove()
            // Docker Engine API: DELETE /containers/{id} returns 204 No Content.
            return .noContent
        }
    }
}
