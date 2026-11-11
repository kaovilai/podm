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
                // moby's reserveName (daemon/names.go): "Invalid container
                // name (%s), only %s are allowed" with the restricted charset.
                throw Abort(
                    .badRequest,
                    reason:
                        "Invalid container name (\(requestedName)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed"
                )
            }
            let hexId = DockerContainerID.hexId(for: container)
            // The RAW override feeds the claim's compare-and-swap: a concurrent
            // rename of the same container that already won must make this
            // request fail instead of publishing a stale old name.
            let currentOverride = await ContainerNameOverrideStore.shared.get(hexId: hexId)
            let currentName = currentOverride ?? container.id
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
            // Reserved name → the owning container's Docker hex id, so the 409
            // can quote the conflict the way moby does (daemon/errors.go
            // nameConflictError: "Conflict. The container name %q is already
            // in use by container %q. You have to remove (or rename) that
            // container to be able to reuse that name.").
            var conflictOwners: [String: String] = [:]
            let recordedOverrides = await ContainerNameOverrideStore.shared.snapshot()
            for other in others where other.id != container.id {
                reserved.insert(other.id)
                let otherHexId = DockerContainerID.hexId(for: other)
                // The SANITIZED hex id too: sanitize() truncates to 63 chars,
                // so a rename requesting another container's full 64-char
                // Docker id would otherwise pass the raw-id check yet match
                // that container's id in lookups (sanitizedReference).
                reserved.insert(otherHexId)
                reserved.insert(ContainerNameUtility.sanitize(otherHexId))
                conflictOwners[other.id] = otherHexId
                conflictOwners[otherHexId] = otherHexId
                conflictOwners[ContainerNameUtility.sanitize(otherHexId)] = otherHexId
                // The other container's effective (possibly renamed) name is
                // reserved by the claim itself (overrides.values) — mapped
                // here so the conflict message can name its owner.
                if let otherOverride = recordedOverrides[otherHexId] {
                    conflictOwners[otherOverride] = otherHexId
                }
            }
            let claimOutcome = await ContainerNameOverrideStore.shared.claim(
                hexId: hexId, name: newName, expectedOverride: currentOverride, reserved: reserved)
            guard case .claimed = claimOutcome else {
                // moby wraps the conflict (daemon/rename.go): "Error when
                // allocating new name: %w". The owner comes ATOMICALLY from
                // the rejected claim when the actor saw a live override —
                // a pre-claim owner snapshot can race a concurrent winner
                // (two renames to a free name both see no owner; the loser
                // must still quote the winner's id).
                let atomicOwner: String?
                if case .conflict(let owner) = claimOutcome { atomicOwner = owner } else { atomicOwner = nil }
                // The fallback mapping is built from the container list —
                // valid for native/hex ids (they never move) and for owners
                // that held the name before this request started.
                if let ownerId = atomicOwner ?? conflictOwners[newName] {
                    throw Abort(
                        .conflict,
                        reason:
                            "Error when allocating new name: Conflict. The container name \"/\(newName)\" is already in use by container \"\(ownerId)\". You have to remove (or rename) that container to be able to reuse that name."
                    )
                }
                throw Abort(
                    .conflict,
                    reason:
                        "Error when allocating new name: name is already in use: \(newName)"
                )
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
                        // moby's rename event carries the old name under the
                        // "oldName" attribute key (daemon/rename.go
                        // LogContainerEventWithAttributes), WITH the name
                        // registry's leading slash: "/web", not "web".
                        extraAttributes: ["oldName": "/" + currentName]
                    ))
            }
            // moby answers 204 No Content on a successful rename.
            return Response(status: .noContent)
        }
    }
}
