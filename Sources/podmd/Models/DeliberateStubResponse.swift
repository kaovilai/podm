import Vapor

/// Compat-correct answers for deliberately-unsupported routes (issue #33).
///
/// A stub must answer with the status the reference daemons give for the
/// unimplemented capability — never a bare 500, which tells CLIs the server
/// *errored* instead of cleanly reporting a missing capability:
/// - **503 Service Unavailable** for a capability the platform does not
///   provide. moby v28.5.2 documents 503 "node is not part of a swarm" for
///   the swarm family (`api/swagger.yaml`; the message is `errNoSwarm` in
///   `daemon/cluster/errors.go`), and podman's swarm stubs answer 503 "so
///   the client can decide if they still can talk to us"
///   (`pkg/api/server/register_swarm.go`, `noSwarm`).
/// - **501 Not Implemented** for an operation podm knowingly does not
///   implement (the docker plugin system, dockerd's buildx session channel).
///
/// Every body matches moby's error shape (`{"message": ...}`).
enum DeliberateStubResponse {
    private static func json(_ status: HTTPResponseStatus, _ message: String) -> Response {
        let body = "{\"message\": \"\(message)\"}"
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        return Response(status: status, headers: headers, body: .init(string: body))
    }

    /// Swarm family (configs/nodes/secrets/services/swarm/tasks): moby's
    /// exact `errNoSwarm` message with the documented 503.
    static func notInSwarm() -> Response {
        json(.serviceUnavailable, "This node is not part of a swarm")
    }

    /// pause/unpause (docker + libpod twins share this answer): 503 with one
    /// shared message carrying the canonical upstream attribution (issue
    /// #37) — blocked on apple/container XPC support, tracked upstream in
    /// apple/containerization#998.
    static func pauseUnavailable() -> Response {
        json(
            .serviceUnavailable,
            "Pausing and unpausing a container is not supported by podm: blocked upstream — "
                + "apple/container exposes no pause XPC route, and containerization's VZ "
                + "pause/resume was removed pending a fix for the vended-vsock lifetime "
                + "problem (tracked in apple/containerization#998)"
        )
    }

    /// Known-unsupported operations: 501. podman's compat layer answers its
    /// single registered plugin route with 404 `UnsupportedHandler`
    /// (`pkg/api/server/register_plugins.go`); podm keeps the wider docker
    /// surface registered and tells the client exactly that with a 501.
    static func notImplemented(_ endpoint: String, _ method: String) -> Response {
        json(
            .notImplemented,
            "Method \(method) to \(endpoint) is not implemented by podm at the moment"
        )
    }
}
