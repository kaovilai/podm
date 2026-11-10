import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor

/// `GET /libpod/containers/{id}/changes` — `podman diff` (libpod API).
///
/// Serves the same handler and response shape as the Docker dialect route;
/// podman's `DockerChange` uses identical `Path`/`Kind` field names and kinds.
struct LibpodContainerChangesRoute: RouteCollection {
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
            pattern: "/libpod/containers/{id}/changes",
            use: ContainerChangesRoute.handler(client: client, appSupportURL: appSupportURL))
    }
}
