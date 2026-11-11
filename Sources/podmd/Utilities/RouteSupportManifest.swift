import Foundation

/// One deliberately-unsupported route: a product decision, recorded with the
/// reason. Shared by the route-conformance test (which enforces that only
/// these routes answer with stubs) and `podmd --docgen` (which renders the
/// support surface into the README section and the GitHub Pages site).
struct DeliberateStub: Sendable {
    let method: String
    let pattern: String
    let reason: String

    var key: String {
        "\(method) \(pattern)"
    }
}

enum RouteSupportManifest {
    /// Routes that deliberately answer with a not-implemented/not-supported
    /// stub. Every entry carries its reason; implementing a route means
    /// removing its entry here (the conformance test fails otherwise).
    ///
    /// Status codes follow the reference daemons (issue #33): the swarm
    /// family answers moby's documented 503, upstream-blocked capabilities
    /// answer 503, and knowingly-unimplemented operations answer 501.
    static let stubs: [DeliberateStub] = [
        // ── Container-scoped gaps (docker dialect + libpod twins) ────────────
        DeliberateStub(
            method: "POST", pattern: "/containers/{id}/pause",
            reason:
                "Blocked upstream: apple/container exposes no pause XPC route; apple/containerization#366 removed the LinuxContainer/LinuxPod pause/resume API (suspected vended-vsock EBADF asserts), while the underlying VZ pause/resume VM primitives remain (apple/containerization#998)."
        ),
        DeliberateStub(
            method: "POST", pattern: "/containers/{id}/unpause",
            reason:
                "Blocked upstream: apple/container exposes no pause XPC route; apple/containerization#366 removed the LinuxContainer/LinuxPod pause/resume API (suspected vended-vsock EBADF asserts), while the underlying VZ pause/resume VM primitives remain (apple/containerization#998)."
        ),
        DeliberateStub(
            method: "POST", pattern: "/libpod/containers/{id}/pause",
            reason:
                "Blocked upstream: apple/container exposes no pause XPC route; apple/containerization#366 removed the LinuxContainer/LinuxPod pause/resume API (suspected vended-vsock EBADF asserts), while the underlying VZ pause/resume VM primitives remain (apple/containerization#998)."
        ),
        DeliberateStub(
            method: "POST", pattern: "/libpod/containers/{id}/unpause",
            reason:
                "Blocked upstream: apple/container exposes no pause XPC route; apple/containerization#366 removed the LinuxContainer/LinuxPod pause/resume API (suspected vended-vsock EBADF asserts), while the underlying VZ pause/resume VM primitives remain (apple/containerization#998)."
        ),
        // ── buildx session channel ───────────────────────────────────────────
        DeliberateStub(
            method: "GET", pattern: "/session",
            reason: "dockerd's buildx session channel is not supported; the route answers not-supported for CLI compatibility."),
        // ── Swarm compatibility surface (single-node: not supported) ─────────
        // (The GET/POST/DELETE /configs routes are live over the local
        // ConfigStore — see ConfigsRoute.)
        DeliberateStub(
            method: "GET", pattern: "/nodes",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/nodes/{id}",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/nodes/{id}/update",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/services",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/services/{id}",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/services/{id}/logs",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/services/{id}/update",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/services/create",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/swarm",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/swarm/init",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/swarm/join",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/swarm/leave",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/swarm/unlock",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/swarm/unlockkey",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/swarm/update",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/tasks",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/tasks/{id}",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/tasks/{id}/logs",
            reason: "Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility."),
        // ── Plugin system compatibility surface ──────────────────────────────
        // (The local-metadata half of /plugins — list, inspect, privileges,
        // create — is live over the local PluginStore; see PluginsRoute.)
        DeliberateStub(
            method: "POST", pattern: "/plugins/{name}/disable",
            reason:
                "The docker plugin runtime (privileged plugin container + /run/docker/plugins socket) has no mapping onto Apple's microVM isolation; the route answers not-implemented for CLI compatibility."
        ),
        DeliberateStub(
            method: "POST", pattern: "/plugins/{name}/enable",
            reason:
                "The docker plugin runtime (privileged plugin container + /run/docker/plugins socket) has no mapping onto Apple's microVM isolation; the route answers not-implemented for CLI compatibility."
        ),
        DeliberateStub(
            method: "POST", pattern: "/plugins/{name}/push",
            reason:
                "The docker plugin runtime (privileged plugin container + /run/docker/plugins socket) has no mapping onto Apple's microVM isolation; the route answers not-implemented for CLI compatibility."
        ),
        DeliberateStub(
            method: "POST", pattern: "/plugins/{name}/set",
            reason:
                "The docker plugin runtime (privileged plugin container + /run/docker/plugins socket) has no mapping onto Apple's microVM isolation; the route answers not-implemented for CLI compatibility."
        ),
        DeliberateStub(
            method: "POST", pattern: "/plugins/{name}/upgrade",
            reason:
                "The docker plugin runtime (privileged plugin container + /run/docker/plugins socket) has no mapping onto Apple's microVM isolation; the route answers not-implemented for CLI compatibility."
        ),
        DeliberateStub(
            method: "POST", pattern: "/plugins/pull",
            reason:
                "The docker plugin runtime (privileged plugin container + /run/docker/plugins socket) has no mapping onto Apple's microVM isolation; the route answers not-implemented for CLI compatibility."
        ),
    ]

    static let stubKeys: Set<String> = Set(stubs.map(\.key))

    static func reason(for key: String) -> String? {
        stubs.first { $0.key == key }?.reason
    }
}
