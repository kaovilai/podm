import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Issue #33: every deliberate stub must answer with the status the
/// reference daemons give for the unimplemented capability — 503 for
/// capability gaps (moby documents 503 "node is not part of a swarm" for
/// the swarm family; podman's swarm stubs answer 503 too), 501 for
/// knowingly-unimplemented operations (plugins, /session) — always with
/// moby's `{"message": ...}` error shape. A 500 here would tell CLIs the
/// server *errored* instead of reporting a missing capability.
@Suite("Deliberate stubs answer compat-correct status + message")
struct DeliberateStubRouteTests {
    /// The compat contract each stub family must uphold.
    private enum Expectation {
        /// Swarm family (configs/nodes/secrets/services/swarm/tasks):
        /// moby v28.5.2 documents 503 "node is not part of a swarm"
        /// (api/swagger.yaml; `errNoSwarm` in daemon/cluster/errors.go).
        case notInSwarm
        /// pause/unpause: 503 with the shared upstream-blocked message from
        /// issue #37's attribution (apple/containerization#998).
        case pauseUnavailable
        /// Knowingly-unimplemented operations (plugins family, /session).
        case notImplemented

        var status: HTTPResponseStatus {
            switch self {
            case .notInSwarm, .pauseUnavailable: .serviceUnavailable
            case .notImplemented: .notImplemented
            }
        }
    }

    private static let swarmPrefixes = ["/configs", "/nodes", "/secrets", "/services", "/swarm", "/tasks"]

    private func expectation(for stub: DeliberateStub) -> Expectation {
        if stub.pattern.hasSuffix("/pause") || stub.pattern.hasSuffix("/unpause") {
            return .pauseUnavailable
        }
        if Self.swarmPrefixes.contains(where: { stub.pattern == $0 || stub.pattern.hasPrefix($0 + "/") }) {
            return .notInSwarm
        }
        return .notImplemented
    }

    /// Substitutes `{param}` / `{name:.*}` segments with a benign dummy value.
    private func dispatchPath(from pattern: String) -> String {
        pattern.replacingOccurrences(
            of: #"\{[^}]*\}"#, with: "stub-test", options: .regularExpression)
    }

    @Test("every manifest stub answers its family's compat status, message, and JSON shape")
    func stubsAnswerCompatStatusAndMessage() async throws {
        try await withApp(configure: { app in
            // Throwaway app-support directory — see RouteConformanceTests for
            // why booting the production registry in-process must never aim
            // singletons at the developer's real store.
            let scratchAppSupport = FileManager.default.temporaryDirectory
                .appendingPathComponent("podm-stub-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratchAppSupport, withIntermediateDirectories: true)
            _ = try await RouteRegistry.bootstrap(app, appSupportDirectory: scratchAppSupport)
        }) { app in
            var failures: [String] = []
            var pauseBodies: Set<String> = []

            for stub in RouteSupportManifest.stubs {
                let expectation = self.expectation(for: stub)
                try await app.testing().test(
                    HTTPMethod(rawValue: stub.method), dispatchPath(from: stub.pattern)
                ) { res async in
                    if res.status != expectation.status {
                        failures.append(
                            "\(stub.key): expected \(expectation.status.code), got \(res.status.code)")
                    }
                    guard let contentType = res.headers.first(name: .contentType),
                        contentType.contains("application/json")
                    else {
                        failures.append("\(stub.key): expected application/json, got \(res.headers.first(name: .contentType) ?? "none")")
                        return
                    }
                    let body = res.body.string
                    switch expectation {
                    case .notInSwarm:
                        if !body.contains("This node is not part of a swarm") {
                            failures.append("\(stub.key): body does not carry moby's errNoSwarm message: \(body)")
                        }
                    case .pauseUnavailable:
                        pauseBodies.insert(body)
                        if !body.contains("apple/containerization#998") {
                            failures.append("\(stub.key): body does not cite the upstream blocker: \(body)")
                        }
                        if !body.contains("is not supported by podm") {
                            failures.append("\(stub.key): body is not a podm not-supported message: \(body)")
                        }
                    case .notImplemented:
                        if !body.contains("is not implemented by podm") {
                            failures.append("\(stub.key): body is not a podm not-implemented message: \(body)")
                        }
                    }
                }
            }

            // pause and unpause (docker dialect + libpod twins) must share
            // ONE message — the pre-#33 bug was pause answering
            // "not supported in Apple container" while unpause answered a
            // generic "not implemented" failure.
            #expect(pauseBodies.count == 1, "pause/unpause stubs must share one message, saw \(pauseBodies.sorted())")

            #expect(failures.isEmpty, "\(failures.count) stub compatibility failure(s): \(failures.joined(separator: "; "))")
        }
    }
}
