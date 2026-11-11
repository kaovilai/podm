import Vapor

struct LibpodContainerRenameRoute: RouteCollection {
    let client: ClientContainerProtocol

    /// Defaults to the real service so `RouteRegistry`'s no-argument
    /// registration (from the stub era) keeps compiling; the registry passes
    /// its shared `containerClient` like every other container route.
    init(client: ClientContainerProtocol = ClientContainerService()) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        // Dispatches to the shared handler, which follows moby's semantics.
        // Podman's own handler (pkg/api/handlers/compat/containers.go
        // RenameContainer + libpod/runtime_ctr.go) differs on the edges: it
        // allows renaming to the container's current name (no check → 204,
        // where moby answers 400) and maps an invalid new name to 500 rather
        // than 400. Per house policy the docker dialect wins here too.
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/rename", use: ContainerRenameRoute.handler(client: client))
    }
}
