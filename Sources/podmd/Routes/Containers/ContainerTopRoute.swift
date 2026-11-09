import Vapor

/// `GET /containers/{id}/top` — `docker top` (Docker Engine API).
///
/// Runs `ps` inside the container (processes are not visible from the macOS
/// host — each container is its own microVM) and returns moby's
/// `ContainerTopOKBody` shape. Defaults to `ps -ef`, matching moby's
/// `daemon/top_unix.go`.
struct ContainerTopRoute: RouteCollection {
    let client: ClientContainerProtocol
    let runPs: ContainerTopUtility.PsRunner

    /// configure.swift registers this collection without arguments; the
    /// defaults construct the same services the injected routes use.
    init(
        client: ClientContainerProtocol = ClientContainerService(),
        runPs: @escaping ContainerTopUtility.PsRunner = ContainerTopUtility.execPs
    ) {
        self.client = client
        self.runPs = runPs
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/top", use: ContainerTopRoute.handler(client: client, runPs: runPs))
    }

    static func handler(
        client: ClientContainerProtocol,
        runPs: @escaping ContainerTopUtility.PsRunner = ContainerTopUtility.execPs
    ) -> @Sendable (Request) async throws -> TopReport {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let psArgs = req.query["ps_args"] as String?
            return try await ContainerTopUtility.top(
                client: client,
                containerId: containerId,
                psArgs: ContainerTopUtility.dockerArgv(psArgs: psArgs),
                rejoinCommandExtras: false,
                runPs: runPs
            )
        }
    }
}
