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
        /// nil = no response was recorded (the request failed before the
        /// response closure ran) — never silently classified as live.
        private(set) var outcome: ProbeOutcome?

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

    /// Routes that must NEVER be dispatched by this test: they take no path
    /// parameters and mutate the WHOLE store, so a probe on a developer's Mac
    /// with images/containers present would prune real data through the real
    /// service clients (`make test` must never be destructive). They are still
    /// covered by the routing-match phase, which asserts their registration
    /// and non-shadowed dispatch target without executing anything.
    private static let storeWideMutationRoutes: Set<String> = [
        "POST /build/prune",
        "POST /containers/prune",
        "POST /libpod/containers/prune",
        "POST /images/prune",
        "POST /libpod/images/prune",
        "POST /networks/prune",
        "POST /libpod/networks/prune",
        "POST /volumes/prune",
        "POST /libpod/volumes/prune",
    ]

    @Test("every registered route answers; stub responses appear only in the manifest")
    func registeredSurfaceConforms() async throws {
        try await withApp(configure: { app in
            // Throwaway app-support directory: `RestartPolicyOverrideStore.shared`
            // is a singleton, so booting the production registry in-process must
            // never aim it (or anything else under app support) at the developer's
            // real store.
            let scratchAppSupport = FileManager.default.temporaryDirectory
                .appendingPathComponent("podm-conformance-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratchAppSupport, withIntermediateDirectories: true)
            _ = try await RouteRegistry.bootstrap(app, appSupportDirectory: scratchAppSupport)
        }) { app in
            let routes = app.regexRouter.registeredRoutes
            // The full production surface must be present — a configure()
            // regression that drops registrations fails here.
            #expect(routes.count >= 150, "expected the full production surface, saw only \(routes.count) routes")

            var failures: [String] = []
            var stubsSeen = Set<String>()
            var streamingSkips = 0

            // Phase 1 — ROUTING, zero side effects: every registered route's
            // dispatch path must resolve back to that SAME route. This is what
            // catches shadowing — the motivating `podman rmi` bug was
            // `DELETE /libpod/images/remove` being swallowed by the
            // `/libpod/images/{name:.*}` wildcard, whose 404 ("No such image:
            // remove") would classify as a live route in the dispatch phase.
            for route in routes {
                let key = "\(route.method) \(route.pattern)"
                let path = dispatchPath(from: route.pattern)
                let matched = app.regexRouter.matchedPattern(method: route.method, path: path)
                if matched != route.pattern {
                    failures.append("\(key) is shadowed: path \(path) dispatches to \(matched ?? "nothing")")
                }
            }

            // Phase 2 — DISPATCH, stub classification. Store-wide mutation
            // routes are excluded: a probe must never prune real data.
            for route in routes {
                let key = "\(route.method) \(route.pattern)"
                if Self.storeWideMutationRoutes.contains(key) { continue }
                let path = dispatchPath(from: route.pattern)
                let probe = StubProbe()
                // The probe task races a deadline: a streaming route that
                // never terminates with dummy input is "engaged" (it answered
                // with a stream), which is all this test asserts.
                let probeTask = Task<ProbeOutcome?, Never> {
                    _ = try? await app.testing().test(route.method, path) { res in
                        await probe.record(status: res.status, body: res.body.string ?? "")
                    }
                    return await probe.outcome
                }
                let outcome = await AsyncRace.firstOrTimeout(probeTask, timeoutNs: 5_000_000_000)

                switch outcome {
                case nil:
                    // Deadline hit — the route engaged and streams. Not a
                    // stub by construction; the leaked task dies with the
                    // test process.
                    streamingSkips += 1
                case .some(nil):
                    // The request failed before any response was recorded —
                    // must not masquerade as a healthy route.
                    failures.append("\(key) produced no response (request failed before the response phase)")
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

            // The store-wide-mutation skip list must track reality too: a
            // prune route that disappears (or is renamed without updating the
            // list) would otherwise silently re-enable destructive probing.
            let registeredKeys = Set(routes.map { "\($0.method) \($0.pattern)" })
            let missingMutationRoutes = Self.storeWideMutationRoutes.subtracting(registeredKeys)
            #expect(
                missingMutationRoutes.isEmpty,
                "destructive-route skip list entries no longer registered (rename without updating the guard?): \(missingMutationRoutes.sorted().joined(separator: ", "))")

            #expect(failures.isEmpty, "\(failures.count) conformance failure(s): \(failures.joined(separator: "; "))")
            // The skip count stays tiny (events/attach-style streaming routes
            // with dummy parameters error out quickly); a jump means probes
            // are timing out for the wrong reason.
            #expect(streamingSkips <= 8, "unexpectedly many streaming probe timeouts: \(streamingSkips)")
        }
    }
}
