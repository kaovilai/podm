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
            // The DNS forwarder sidecars are hidden from user listings but
            // still own their native names — a rename to one would make the
            // container unreachable by name (getContainer finds the sidecar
            // and returns nil). The podm-dns- prefix is podm-internal.
            guard !newName.hasPrefix(NetworkDNSManager.containerPrefix) else {
                throw Abort(.badRequest, reason: "invalid container name: \(newName) — reserved prefix")
            }
            // A name is taken when any OTHER container resolves to it: its
            // effective (possibly overridden) name, its native id (which
            // stays resolvable even when an override shadows it — unlike
            // moby, renaming cannot free a native id), or its Docker hex id
            // (which getContainer's hex-prefix resolution would otherwise
            // match ahead of the name). The claim itself is one atomic store
            // operation, so two concurrent renames to the same name cannot
            // both pass — the loser gets false and answers 409.
            let others = try await client.list(showAll: true, filters: [:])
            var reserved = Set<String>()
            for other in others where other.id != container.id {
                reserved.insert(other.id)
                reserved.insert(DockerContainerID.hexId(for: other))
            }
            guard await ContainerNameOverrideStore.shared.claim(hexId: hexId, name: newName, reserved: reserved) else {
                throw Abort(.conflict, reason: "name is already in use: \(newName)")
            }
            // Swap the container's DNS hostname alias while it runs so peers
            // resolve the new name immediately. Label-derived aliases
            // (`podm.dns.names`, Compose service/project) are unaffected by a
            // rename — moby keeps them too.
            if container.status == .running,
                let dnsServer = req.application.storage[PodmDNSServerKey.self],
                let ip = ContainerStartRoute.dnsAttachmentIP(in: container)
            {
                // The native id stays registered: restart and daemon-resume
                // register both it and the override, and the API keeps native
                // ids resolvable — DNS should not diverge from that. Only a
                // PREVIOUS override name is swapped out, and only when no
                // label still requires it (podm.dns.names / Compose service
                // aliases survive a rename, like moby keeps them).
                let labels = LabelNormalization.restore(container.configuration.labels)
                func labelRequires(_ name: String) -> Bool {
                    if let namesLabel = labels["podm.dns.names"],
                        namesLabel.split(separator: ",").map(String.init).contains(name)
                    {
                        return true
                    }
                    if let service = labels["com.docker.compose.service"] {
                        if service == name { return true }
                        if let project = labels["com.docker.compose.project"],
                            "\(service).\(project)" == name
                        {
                            return true
                        }
                    }
                    return false
                }
                if currentName != container.id && !labelRequires(currentName) {
                    dnsServer.unregisterIfOwned(hostname: currentName, expectedIP: ip)
                }
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
