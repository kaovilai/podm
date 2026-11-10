import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Mechanical route conformance: enumerate EVERY route the production daemon
/// registers (via `RouteRegistry.bootstrap`, the exact code path `configure()`
/// uses) and dispatch a synthetic request to each. A route may only answer
/// with a not-implemented/not-supported stub when it appears in the manifest
/// below — the deliberate-support-surface decision record. This is the guard
/// that would have caught `podman rmi` being swallowed by the
/// `/libpod/images/{name:.*}` wildcard: a route that silently regresses to a
/// stub (or disappears behind a shadowing route and 404s as an image named
/// "remove") fails here loudly.
///
/// Requests carry dummy path parameters, so handlers only ever reach their
/// lookup/validation paths — a bogus container/image reference is a 404 (or a
/// runtime connection error on machines without Apple container) long before
/// any VM or store mutation. Streaming routes (events, attach) that never
/// terminate with dummy input are treated as engaged: the probe races a
/// deadline, and a timeout means the route answered with a stream — not a
/// stub.
@Suite("Route conformance — the registered surface answers, stubs only per manifest")
struct RouteConformanceTests {
    // The deliberate-stub manifest (routes + reasons) lives in
    // Sources/podmd/Utilities/RouteSupportManifest.swift so `podmd --docgen`
    // renders the same decision record into the README section and the
    // GitHub Pages site that this test enforces.
    /// Routes that deliberately answer with a not-implemented/not-supported
    /// stub. Every entry is a product decision:
    /// - pause/unpause: Apple container has no pause primitive.
    /// - commit/changes/rename: tracked gaps (socktainer#14 parity work).
    /// - session: dockerd-only buildx channel; podm answers not-supported.
    /// - swarm family (configs/nodes/secrets/services/swarm/tasks): single-node
    ///   Apple container has no swarm; the routes exist for CLI compat.
    /// - plugins family: podman/docker plugin system is out of scope.
    ///
    /// Adding an entry requires a reason here; implementing a route requires
    /// REMOVING its entry (the reverse assertion fails otherwise).
    private static var deliberateStubRoutes: Set<String> {
        RouteSupportManifest.stubKeys
    }

    /// What a probe learned about one route.
    private enum ProbeOutcome: Sendable {
        case stub
        case live
    }

    /// Records the stub-signature of one response. Stub = HTTP 501, or a 500
    /// carrying podm's not-implemented / not-supported marker strings (see
    /// `NotImplemented.respond` and `AppleContainerNotSupported.respond`).
    private actor StubProbe {
        private(set) var outcome = ProbeOutcome.live

        func record(status: HTTPResponseStatus, body: String) {
            let isStub =
                status == .notImplemented
                || body.localizedCaseInsensitiveContains("is not implemented by podm")
                || body.localizedCaseInsensitiveContains("is not supported in apple container")
            outcome = isStub ? .stub : .live
        }
    }

    /// Substitutes `{param}` / `{name:.*}` segments with a benign dummy value.
    private func dispatchPath(from pattern: String) -> String {
        pattern.replacingOccurrences(
            of: #"\{[^}]*\}"#, with: "conformance-dummy", options: .regularExpression)
    }

    @Test("every registered route answers; stub responses appear only in the manifest")
    func registeredSurfaceConforms() async throws {
        try await withApp(configure: { app in
            _ = try await RouteRegistry.bootstrap(app)
        }) { app in
            let routes = app.regexRouter.registeredRoutes
            // The full production surface must be present — a configure()
            // regression that drops registrations fails here.
            #expect(routes.count >= 150, "expected the full production surface, saw only \(routes.count) routes")

            var failures: [String] = []
            var stubsSeen = Set<String>()
            var streamingSkips = 0

            for route in routes {
                let key = "\(route.method) \(route.pattern)"
                let path = dispatchPath(from: route.pattern)
                let probe = StubProbe()
                // The probe task races a deadline: a streaming route that
                // never terminates with dummy input is "engaged" (it answered
                // with a stream), which is all this test asserts.
                let probeTask = Task<ProbeOutcome?, Never> {
                    try? await app.testing().test(route.method, path) { res in
                        await probe.record(status: res.status, body: res.body.string ?? "")
                    }
                    return await probe.outcome
                }
                let outcome = await ContainerTopUtility.raceFirstOrTimeout(
                    probeTask, timeoutNs: 5_000_000_000)

                switch outcome {
                case nil:
                    // Deadline hit — the route engaged and streams. Not a
                    // stub by construction; the leaked task dies with the
                    // test process.
                    streamingSkips += 1
                case .some(.stub):
                    stubsSeen.insert(key)
                    if !Self.deliberateStubRoutes.contains(key) {
                        failures.append("\(key) answered with a not-implemented stub but is not in the deliberate manifest")
                    }
                case .some(.live):
                    if Self.deliberateStubRoutes.contains(key) {
                        failures.append("\(key) is in the deliberate-stub manifest but answered as a live route — remove it from the manifest")
                    }
                }
            }

            // Reverse direction: every manifest entry must be a registered,
            // stub-shaped route — deleting a stub route (or implementing it)
            // without updating the manifest fails loudly too.
            let missing = Self.deliberateStubRoutes.subtracting(stubsSeen)
            #expect(missing.isEmpty, "manifest entries that did not answer as registered stubs (removed or implemented?): \(missing.sorted().joined(separator: ", "))")

            #expect(failures.isEmpty, "\(failures.count) conformance failure(s): \(failures.joined(separator: "; "))")
            // The skip count stays tiny (events/attach-style streaming routes
            // with dummy parameters error out quickly); a jump means probes
            // are timing out for the wrong reason.
            #expect(streamingSkips <= 8, "unexpectedly many streaming probe timeouts: \(streamingSkips)")
        }
    }
}
