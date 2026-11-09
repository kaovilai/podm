// SPDX-License-Identifier: Apache-2.0
import Foundation
import Vapor

/// libpod-only `GET /libpod/containers/{name}/healthcheck` — `podman healthcheck run`.
///
/// Real podman (pkg/api/handlers/libpod/healthcheck.go) executes the container's
/// configured healthcheck test once, right now, and reports the fresh outcome —
/// not the cached background-loop status. The error contract mirrors podman:
/// 404 for an unknown container, 409 when the container has no healthcheck
/// configured or is not running, 500 when the manager isn't wired up.
///
/// The 200 body is libpod's `HealthCheckResults`
/// (libpod/define/container_inspect.go): `Status` ("healthy"/"unhealthy"),
/// `FailingStreak`, and `Log` entries with `Start`/`End`/`ExitCode`/`Output` —
/// field-for-field the same shape as Docker's `State.Health`, so the existing
/// `ContainerHealth` model is reused verbatim.
struct LibpodContainerHealthcheckRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        // Real podman registers GET only (pkg/api/server/register_healthcheck.go).
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{name}/healthcheck", use: Self.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> ContainerHealth {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let container = try await client.getContainer(id: name) else {
                throw Abort(.notFound, reason: "No such container: \(name)")
            }

            guard container.status == .running else {
                throw Abort(.conflict, reason: "container \(name) is not running")
            }

            // Apple Container has no native healthcheck field; the create route
            // round-trips the Docker `Healthcheck` block via a JSON label.
            guard
                let labelValue = container.configuration.labels[HealthCheckManager.healthcheckLabel],
                let config = try? JSONDecoder().decode(HealthcheckConfig.self, from: Data(labelValue.utf8))
            else {
                throw Abort(.conflict, reason: "container \(name) has no defined healthcheck")
            }

            // The same manager instance the background loop uses, keyed by the
            // native Apple Container name (snapshot.id) — the key
            // ContainerInspectRoute and ContainerListRoute read health through.
            guard let healthManager = req.application.storage[HealthCheckManagerKey.self] else {
                req.logger.error("HealthCheckManager missing from application storage")
                throw Abort(.internalServerError, reason: "healthcheck manager not configured")
            }

            // nil = NONE / empty / bare CMD — podman's "no defined healthcheck".
            guard let result = await healthManager.runProbeOnce(containerId: container.id, config: config) else {
                throw Abort(.conflict, reason: "container \(name) has no defined healthcheck")
            }
            return result
        }
    }
}
