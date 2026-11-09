import Vapor

/// `GET /libpod/containers/{id}/top` — `podman top` (libpod API).
///
/// Same `ps`-inside-the-container implementation as the Docker dialect
/// (podman itself falls back to executing ps(1) in the container when its
/// psgo descriptors are unknown), differing in two ways:
/// - query parameters: podman's remote CLI sends AIX format descriptors as
///   repeated `ps_args` values (or the newer `descriptors` parameter), which
///   map to `ps -o d1,d2,...`;
/// - rows wider than the header are merged back into the last (command)
///   column, keeping every row exactly `Titles.count` wide — podman's
///   handler does this, moby leaves them split.
struct LibpodContainerTopRoute: RouteCollection {
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
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{id}/top", use: LibpodContainerTopRoute.handler(client: client, runPs: runPs))
    }

    static func handler(
        client: ClientContainerProtocol,
        runPs: @escaping ContainerTopUtility.PsRunner = ContainerTopUtility.execPs
    ) -> @Sendable (Request) async throws -> TopReport {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            // Vapor's query decoding keeps only the last value of a repeated
            // key, and podman's bindings send descriptors one per ps_args
            // value — recover every value from the raw query string. The
            // newer `descriptors` parameter carries the same values.
            var raw = allQueryValues(named: "ps_args", from: req.url.query)
            raw += allQueryValues(named: "descriptors", from: req.url.query)

            let args = ContainerTopUtility.libpodArgv(psArgs: raw)
            return try await ContainerTopUtility.top(
                client: client,
                containerId: containerId,
                psArgs: args.argv,
                appendedCommandColumn: args.appendedCommandColumn,
                reorder: args.reorder,
                runPs: runPs
            )
        }
    }
}
