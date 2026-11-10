import ContainerResource
import Vapor

struct ContainerRenameRoute: RouteCollection {
    let client: ClientContainerProtocol

    /// Defaults to the real service so `RouteRegistry`'s no-argument
    /// registration (from the stub era) keeps compiling; the registry passes
    /// its shared `containerClient` like every other container route.
    init(client: ClientContainerProtocol = ClientContainerService()) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/rename", use: ContainerRenameRoute.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            let container: ContainerSnapshot
            do {
                guard let found = try await client.getContainer(id: containerId) else {
                    throw Abort(.notFound, reason: "No such container: \(containerId)")
                }
                container = found
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
            }
            // moby's postContainersRename: "Neither old nor new names may be
            // empty" — the {id} segment is present by construction, so only
            // the query name can be missing.
            guard let requestedName = req.query[String.self, at: "name"], !requestedName.isEmpty else {
                throw Abort(.badRequest, reason: "Neither old nor new names may be empty")
            }
            // Docker clients may send the leading slash the daemon's name
            // registry uses; the CLI sends a bare name.
            var trimmed = requestedName
            while trimmed.hasPrefix("/") { trimmed.removeFirst() }
            let newName = ContainerNameUtility.sanitize(trimmed)
            guard ManagedContainer.nameValid(newName) else {
                throw Abort(.badRequest, reason: "invalid container name: \(requestedName)")
            }
            let hexId = DockerContainerID.hexId(for: container)
            let currentName = await ContainerNameOverrideStore.shared.get(hexId: hexId) ?? container.id
            guard newName != currentName else {
                throw Abort(.badRequest, reason: "Renaming a container with the same name as its current name")
            }
            // A name is taken when any OTHER container resolves to it: its
            // effective (possibly overridden) name, its native id (which
            // stays resolvable even when an override shadows it — unlike
            // moby, renaming cannot free a native id), or its Docker hex id
            // (which getContainer's hex-prefix resolution would otherwise
            // match ahead of the name).
            let others = try await client.list(showAll: true, filters: [:])
            for other in others where other.id != container.id {
                let otherEffective =
                    await ContainerNameOverrideStore.shared.get(hexId: DockerContainerID.hexId(for: other)) ?? other.id
                if newName == otherEffective || newName == other.id || newName == DockerContainerID.hexId(for: other) {
                    throw Abort(.conflict, reason: "name is already in use: \(newName)")
                }
            }
            await ContainerNameOverrideStore.shared.set(hexId: hexId, name: newName)
            // Swap the container's DNS hostname alias while it runs so peers
            // resolve the new name immediately. Label-derived aliases
            // (`podm.dns.names`, Compose service/project) are unaffected by a
            // rename — moby keeps them too.
            if container.status == .running,
                let dnsServer = req.application.storage[PodmDNSServerKey.self],
                let ip = ContainerStartRoute.dnsAttachmentIP(in: container)
            {
                dnsServer.unregisterIfOwned(hostname: currentName, expectedIP: ip)
                dnsServer.register(hostname: newName, ip: ip)
            }
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(
                    DockerEvent.simpleEvent(
                        id: hexId,
                        type: "container",
                        status: "rename",
                        image: container.configuration.image.reference,
                        name: newName,
                        labels: LabelNormalization.restore(container.configuration.labels),
                        extraAttributes: ["old_name": currentName]
                    ))
            }
            // moby answers 204 No Content on a successful rename.
            return Response(status: .noContent)
        }
    }
}
