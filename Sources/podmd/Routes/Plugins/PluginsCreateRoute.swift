import Vapor

struct PluginsCreateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/create", use: PluginsCreateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        DeliberateStubResponse.notImplemented("/plugins/create", req.method.rawValue)
    }
}
