import Vapor

struct PluginsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/plugins", use: PluginsRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        DeliberateStubResponse.notImplemented("/plugins", req.method.rawValue)
    }
}
