// SPDX-License-Identifier: Apache-2.0
import Vapor

struct LibpodContainerListRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/json") { req in
            // Delegate to the Docker-compat list handler, then reshape each summary
            // into podman's entities.ListContainer: podman's remote client decodes
            // `Created` as time.Time (RFC3339 string, not a unix int), its port
            // entries use different field names, and it computes the displayed
            // status from StartedAt/ExitedAt/ExitCode rather than trusting the
            // Docker Status string. Missing podman-only fields are fine (they
            // decode to zero values); wrong-typed ones are hard decode errors.
            let summaries = try await ContainerListRoute.handler(client: client)(req)
            return summaries.map(LibpodListContainer.from)
        }
    }
}

/// podman's port mapping shape (netTypes.PortMapping): field names differ from
/// Docker's ContainerPort, so a docker-shaped entry decodes as all-zero.
struct LibpodPortMapping: Content {
    let host_ip: String
    let container_port: Int
    let host_port: Int
    let range: Int
    let `protocol`: String
}

/// podman's `entities.ListContainer` (pkg/domain/entities/types/container_ps.go):
/// every field is declared flat and populated from the Docker-compat summary in
/// `from(_:)`. Lifecycle fields use the real recorded data carried on the
/// summary (StartedAtUnix/ExitCode/ExitedAtUnix) rather than fabricating them
/// from the creation timestamp — podman's ps formatter derives its displayed
/// status ("Exited (N) X ago") from these.
struct LibpodListContainer: Content {
    /// Docker-compat fields podman also consumes, encoded flat.
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let Command: [String]
    let Created: String
    let CreatedAt: String
    let Ports: [LibpodPortMapping]
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
        let exited = s.State == "exited"
        return LibpodListContainer(
            Id: s.Id,
            Names: s.Names,
            Image: s.Image,
            ImageID: s.ImageID,
            Command: s.Command.split(separator: " ").map(String.init),
            Created: createdRFC3339,
            CreatedAt: createdRFC3339,
            Ports: s.Ports.map(LibpodPortMapping.from),
            Labels: s.Labels,
            State: s.State,
            Status: s.Status,
            Networks: (s.NetworkSettings.Networks ?? [:]).isEmpty
                ? [] : Array((s.NetworkSettings.Networks ?? [:]).keys),
            Exited: exited,
            ExitedAt: exited ? (s.ExitedAtUnix ?? s.Created) : 0,
            ExitCode: exited ? (s.ExitCode ?? 0) : 0,
            StartedAt: s.StartedAtUnix ?? 0,
            Pid: 0,
            IsInfra: false,
            Pod: ""
        )
    }
}

extension LibpodPortMapping {
    /// Map Docker's ContainerPort (IP/PrivatePort/PublicPort/type) onto podman's
    /// PortMapping field names. `range` is 1 for individual mappings.
    static func from(_ p: ContainerPort) -> LibpodPortMapping {
        LibpodPortMapping(
            host_ip: p.IP ?? "",
            container_port: p.PrivatePort,
            host_port: p.PublicPort ?? 0,
            range: 1,
            protocol: p.type
        )
    }
}
