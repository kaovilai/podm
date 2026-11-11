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
/// any VM or store mutation. Streaming routes (events-style) that never
/// terminate with dummy input hit the probe deadline — that is only accepted
/// for the pinned `streamingRoutes` list; a deadline on any other route is a
/// hang and fails the suite.
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
    /// - swarm family (nodes/services/swarm/tasks, plus the configs and
    ///   secrets update routes): single-node Apple container has no swarm;
    ///   the routes exist for CLI compat. (The other /secrets routes are
    ///   live over the local SecretStore — see SecretsRoute; the other
    ///   /configs routes are live over the local ConfigStore — see
    ///   ConfigsRoute.)
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

    /// Routes whose probes are EXPECTED to hit the probe deadline: they answer
    /// with a stream that never terminates under dummy input (an events feed
    /// with no filters follows forever). A deadline hit on any OTHER route is a
    /// hang masquerading as engagement — a stuck non-streaming handler must
    /// fail conformance, not ride the skip budget. Kept in sync with reality in
    /// both directions: an unexpected timeout fails, and a stale entry whose
    /// route disappeared fails.
    private static let streamingRoutes: Set<String> = [
        "GET /events",
        "GET /libpod/events",
        // libpod stats streams by default (docker's stats needs a real
        // container id to stream; the probe's dummy id 404s first, so only
        // the libpod form — which stats every container, i.e. none — hangs).
        "GET /libpod/containers/stats",
    ]

    /// Routes that must NEVER be dispatched by this test: they either take no
    /// path parameters and mutate the WHOLE store (the prune family — a probe
    /// on a developer's Mac with images/containers present would prune real
    /// data through the real service clients; `make test` must never be
    /// destructive), or allocate host-side state outside the app-support
    /// sandbox (POST /build — an empty probe can create or start a builder in
    /// the host container store, which the temp app-support dir does not
    /// isolate). They are still covered by the routing-match phase, which
    /// asserts their registration and non-shadowed dispatch target without
    /// executing anything.
    private static let storeWideMutationRoutes: Set<String> = [
        "POST /build",
        "POST /build/prune",
        "POST /libpod/build",
        "POST /containers/prune",
        "POST /libpod/containers/prune",
        "POST /images/prune",
        "POST /libpod/images/prune",
        "POST /networks/prune",
        "POST /libpod/networks/prune",
        "POST /volumes/prune",
        "POST /libpod/volumes/prune",
    ]

    /// Routes whose probes perform OUTBOUND NETWORK I/O against a real
    /// registry even with dummy parameters (distribution inspect resolves the
    /// reference over HTTPS, including registry token round trips). Their
    /// latency is machine- and network-dependent: a probe that answers in
    /// well under a second on CI's fast egress can exceed any fixed deadline
    /// on a home network while the route is perfectly healthy. Dispatching
    /// them makes the suite flaky rather than more sure — routing-phase
    /// coverage and the reverse-registration assertion still guard them.
    private static let networkBoundRoutes: Set<String> = [
        "GET /distribution/{name:.*}/json"
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
            var timedOutRoutes = Set<String>()

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
            // Network-bound routes are excluded too: their latency depends on
            // the machine's egress, not the route's health.
            for route in routes {
                let key = "\(route.method) \(route.pattern)"
                if Self.storeWideMutationRoutes.contains(key) { continue }
                if Self.networkBoundRoutes.contains(key) { continue }
                let path = dispatchPath(from: route.pattern)
                let probe = StubProbe()
                // The probe task races a deadline: a streaming route that
                // never terminates with dummy input is "engaged" (it answered
                // with a stream) — but ONLY routes in `streamingRoutes` may
                // take that branch; any other deadline hit is treated as a
                // hang (see the assertion after the loop).
                let probeTask = Task<ProbeOutcome?, Never> {
                    _ = try? await app.testing().test(route.method, path) { res in
                        await probe.record(status: res.status, body: res.body.string ?? "")
                    }
                    return await probe.outcome
                }
                let outcome = await AsyncRace.firstOrTimeout(probeTask, timeoutNs: 5_000_000_000)

                switch outcome {
                case nil:
                    // Deadline hit — acceptable only for a route known to
                    // answer with a never-terminating stream; the leaked task
                    // dies with the test process.
                    timedOutRoutes.insert(key)
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

            // A probe deadline is only acceptable for a route that answers
            // with a never-terminating stream (events-style). Any OTHER route
            // hitting the deadline is a hung handler masquerading as a
            // healthy streaming route — it must fail, not ride a skip budget.
            let unexpectedTimeouts = timedOutRoutes.subtracting(Self.streamingRoutes)
            #expect(
                unexpectedTimeouts.isEmpty,
                "routes whose probes timed out but are not expected streaming routes (hung handlers, or streamingRoutes needs updating?): \(unexpectedTimeouts.sorted().joined(separator: ", "))"
            )

            // Reverse direction for the streaming list too: a stale entry
            // whose route disappeared (or was renamed) must fail loudly so
            // the list can not rot.
            let missingStreamingRoutes = Self.streamingRoutes.subtracting(registeredKeys)
            #expect(
                missingStreamingRoutes.isEmpty,
                "expected-streaming entries no longer registered (rename without updating the list?): \(missingStreamingRoutes.sorted().joined(separator: ", "))")

            // Same reverse guard for the network-bound skip list.
            let missingNetworkBoundRoutes = Self.networkBoundRoutes.subtracting(registeredKeys)
            #expect(
                missingNetworkBoundRoutes.isEmpty,
                "network-bound skip list entries no longer registered (rename without updating the list?): \(missingNetworkBoundRoutes.sorted().joined(separator: ", "))")
        }
    }
}
