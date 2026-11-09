// SPDX-License-Identifier: Apache-2.0
import Vapor

struct LibpodContainerListRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/json") { req in
            // Delegate to the Docker-compat list handler, then reshape each summary
            // into podman's entities.ListContainer: podman's remote client decodes
            // `Created` as time.Time (RFC3339 string, not a unix int) and also
            // consumes CreatedAt/StartedAt/ExitedAt/Exited, which the Docker shape
            // does not carry. Missing podman-only fields are fine (they decode to
            // zero values); a wrong-typed Created is a hard decode error for podman.
            let summaries = try await ContainerListRoute.handler(client: client)(req)
            return summaries.map(LibpodListContainer.from)
        }
    }
}

/// podman's `entities.ListContainer` (pkg/domain/entities/types/container_ps.go):
/// every field is declared flat and populated from the Docker-compat summary in
/// `from(_:)` — only the fields where the shape differs from Docker's summary
/// are carried (Created as RFC3339 string, CreatedAt/StartedAt/ExitedAt/Exited/
/// Networks); podman-only fields podman tolerates as absent are omitted.
struct LibpodListContainer: Content {
    /// Docker-compat fields podman also consumes, encoded flat.
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let Command: [String]
    let Created: String
    let CreatedAt: String
    let Ports: [ContainerPort]
    let Labels: [String: String]
    let State: String
    let Status: String
    let Networks: [String]
    let Exited: Bool
    let ExitedAt: Int64
    let ExitCode: Int32
    let StartedAt: Int64
    let Pid: Int
    let IsInfra: Bool
    let Pod: String

    static func from(_ s: RESTContainerSummary) -> LibpodListContainer {
        // podman's Created is time.Time: RFC3339. Zero time for unknown.
        let createdRFC3339 = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: TimeInterval(s.Created)))
        let started = s.State == "running"
        return LibpodListContainer(
            Id: s.Id,
            Names: s.Names,
            Image: s.Image,
            ImageID: s.ImageID,
            Command: s.Command.split(separator: " ").map(String.init),
            Created: createdRFC3339,
            CreatedAt: createdRFC3339,
            Ports: s.Ports,
            Labels: s.Labels,
            State: s.State,
            Status: s.Status,
            Networks: (s.NetworkSettings.Networks ?? [:]).isEmpty ? [] : Array((s.NetworkSettings.Networks ?? [:]).keys),
            Exited: s.State == "exited",
            ExitedAt: s.State == "exited" ? s.Created : 0,
            ExitCode: 0,
            StartedAt: started ? s.Created : 0,
            Pid: 0,
            IsInfra: false,
            Pod: ""
        )
    }
}
