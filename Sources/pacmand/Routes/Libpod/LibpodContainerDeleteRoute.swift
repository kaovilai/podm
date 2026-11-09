// SPDX-License-Identifier: Apache-2.0
import Vapor

struct LibpodContainerDeleteRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/containers/{id}") { req in
            // Delegate the actual removal (force checks, cache cleanup, destroy event)
            // to the Docker-compat handler, then reshape the response: podman's remote
            // client unmarshals the DELETE /libpod/containers/{id} response body into
            // []*reports.RmReport, so the Docker-compat 204-with-no-body is a decode
            // error for it ("unexpected end of JSON input"). Real podman answers 200
            // with an array of per-container reports.
            _ = try await ContainerDeleteRoute.handler(client: client)(req)
            let report = LibpodRmReport(Id: req.parameters.get("id") ?? "", Err: nil)
            return Response(
                status: .ok,
                body: .init(data: try JSONEncoder().encode([report]))
            )
        }
    }
}

/// Mirrors podman's reports.RmReport (Id + optional Err); extra fields are ignored
/// by podman's decoder, missing ones default.
struct LibpodRmReport: Content {
    let Id: String
    let Err: String?
}
