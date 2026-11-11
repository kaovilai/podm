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
    static let stubs: [DeliberateStub] = [
        // ── Container-scoped gaps (docker dialect + libpod twins) ────────────
        DeliberateStub(
            method: "POST", pattern: "/containers/{id}/pause",
            reason: "Apple container has no pause primitive for a microVM."),
        DeliberateStub(
            method: "POST", pattern: "/containers/{id}/unpause",
            reason: "Apple container has no pause primitive for a microVM."),
        DeliberateStub(
            method: "POST", pattern: "/libpod/containers/{id}/pause",
            reason: "Apple container has no pause primitive for a microVM."),
        DeliberateStub(
            method: "POST", pattern: "/libpod/containers/{id}/unpause",
            reason: "Apple container has no pause primitive for a microVM."),
        // ── buildx session channel ───────────────────────────────────────────
        DeliberateStub(
            method: "GET", pattern: "/session",
            reason: "dockerd's buildx session channel is not supported; the route answers not-supported for CLI compatibility."),
        // ── Swarm compatibility surface (single-node: not supported) ─────────
        // (The GET/POST/DELETE /configs routes are live over the local
        // ConfigStore — see ConfigsRoute.)
        DeliberateStub(
            method: "POST", pattern: "/configs/{id}/update",
            reason: "A local file-backed config store cannot update in place; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/nodes",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/nodes/{id}",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/nodes/{id}/update",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/secrets/{id}/update",
            reason: "A local file-backed secret store cannot update in place (podman's compat route answers 501 too); the route exists for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/services",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/services/{id}",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/services/{id}/logs",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/services/{id}/update",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/services/create",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/swarm",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/swarm/init",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/swarm/join",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/swarm/leave",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/swarm/unlock",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/swarm/unlockkey",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/swarm/update",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/tasks",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/tasks/{id}",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/tasks/{id}/logs",
            reason: "Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility."),
        // ── Plugin system compatibility surface ──────────────────────────────
        DeliberateStub(
            method: "GET", pattern: "/plugins",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/plugins/{name}",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/plugins/{name}/disable",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/plugins/{name}/enable",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/plugins/{name}/json",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/plugins/{name}/push",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/plugins/{name}/set",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/plugins/{name}/upgrade",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/plugins/create",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
        DeliberateStub(
            method: "GET", pattern: "/plugins/privileges",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
        DeliberateStub(
            method: "POST", pattern: "/plugins/pull",
            reason: "The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility."),
    ]

    static let stubKeys: Set<String> = Set(stubs.map(\.key))

    static func reason(for key: String) -> String? {
        stubs.first { $0.key == key }?.reason
    }
}
