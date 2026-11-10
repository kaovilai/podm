import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor

/// moby's `GET /containers/{id}/changes` entry: `{"Path": "...", "Kind": 0|1|2}`
/// (0 = Modified, 1 = Added, 2 = Deleted). The libpod twin serves the same
/// shape — podman's `DockerChange` uses identical field names and kinds.
struct RESTContainerChange: Content {
    let Path: String
    let Kind: Int
}

/// `GET /containers/{id}/changes` — `docker diff` (Docker Engine API).
///
/// Diffs the container's live ext4 rootfs (`containers/<id>/rootfs.ext4`)
/// against the image's unpacked snapshot ext4 (`snapshots/<digest>/snapshot`),
/// which is the pristine image filesystem and therefore the diff baseline —
/// no create-time capture is needed. See `ContainerChangesWalker`.
struct ContainerChangesRoute: RouteCollection {
    let client: ClientContainerProtocol
    let appSupportURL: URL

    /// configure.swift's route registry constructs this collection without
    /// arguments; the defaults point at the real daemon services.
    init(
        client: ClientContainerProtocol = ClientContainerService(),
        appSupportURL: URL = RouteRegistry.defaultAppSupportURL
    ) {
        self.client = client
        self.appSupportURL = appSupportURL
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/containers/{id}/changes",
            use: ContainerChangesRoute.handler(client: client, appSupportURL: appSupportURL))
    }

    static func handler(
        client: ClientContainerProtocol,
        appSupportURL: URL = RouteRegistry.defaultAppSupportURL
    ) -> @Sendable (Request) async throws -> [RESTContainerChange] {
        { req in
            guard let reference = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let resolved: ContainerSnapshot?
            do {
                resolved = try await client.getContainer(id: reference)
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                throw Abort(
                    .badRequest,
                    reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
            }
            guard let container = resolved else {
                throw Abort(.notFound, reason: "No such container: \(reference)")
            }

            // Volatile read of a possibly-running container's rootfs (the
            // same guarantee as docker export): the guest's most recent
            // writes may still live in its page cache, so a diff of a
            // RUNNING container can briefly lag behind the guest's view
            // until writeback — the CLI integration test runs `sync` for
            // this reason. A stopped container is always consistent.
            let rootfs =
                appSupportURL
                .appendingPathComponent("containers", isDirectory: true)
                .appendingPathComponent(container.id, isDirectory: false)
                .appendingPathComponent("rootfs.ext4", isDirectory: false)
            guard FileManager.default.fileExists(atPath: rootfs.path) else {
                // Match the export route: a container without a rootfs on
                // disk answers 404 rather than an empty diff.
                throw Abort(.notFound, reason: "No rootfs found for container: \(reference)")
            }

            guard
                let baseline = ContainerChangesWalker.baselineSnapshotPath(
                    appSupportURL: appSupportURL,
                    imageDescriptorDigest: container.configuration.image.descriptor.digest,
                    platform: container.configuration.platform)
            else {
                throw Abort(
                    .internalServerError,
                    reason:
                        "No image snapshot baseline for container \(reference) (image \(container.configuration.image.reference)); cannot compute diff"
                )
            }

            let changes: [ContainerFileChange]
            do {
                changes = try await ContainerChangesWalker.changes(
                    baselineBlockDevice: baseline,
                    currentBlockDevice: rootfs
                )
            } catch {
                throw Abort(
                    .internalServerError,
                    reason: "Error diffing container \(reference): \(error.localizedDescription)")
            }

            return changes.map { RESTContainerChange(Path: $0.path, Kind: $0.kind.rawValue) }
        }
    }
}
