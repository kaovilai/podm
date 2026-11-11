import Vapor

struct SessionRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // POST since the endpoint first appeared (Docker API v1.31, experimental;
        // still POST in v1.51) — buildx's session dialer (DialHijack in
        // buildkit) issues POST /session, and podm's router filters by
        // method, so a GET-only registration left buildx with a 404 instead
        // of the defined not-supported answer (issue #34).
        try routes.registerVersionedRoute(.POST, pattern: "/session", use: SessionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        DeliberateStubResponse.notImplemented("/session", req.method.rawValue)
    }
}
