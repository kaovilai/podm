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
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/rename", use: ContainerRenameRoute.handler(client: client))
    }
}
