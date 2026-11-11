import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `/session` must be reachable the way real clients call it (issue #34):
/// the endpoint has been POST since Docker API v1.31, and buildx's session
/// dialer (DialHijack in buildkit) issues `POST /session`. A GET-only
/// registration left buildx with a 404 that never reached the defined
/// not-implemented answer.
@Suite("SessionRoute — POST reachability")
struct SessionRouteTests {

    @Test("POST /session answers the 501 not-implemented stub")
    func postSessionAnswersStub() async throws {
        try await withApp(configure: { app in
            // Throwaway app-support directory — booting the production
            // registry in-process must never aim singletons at the
            // developer's real store (see RouteConformanceTests).
            let scratchAppSupport = FileManager.default.temporaryDirectory
                .appendingPathComponent("podm-session-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratchAppSupport, withIntermediateDirectories: true)
            _ = try await RouteRegistry.bootstrap(app, appSupportDirectory: scratchAppSupport)
        }) { app in
            try await app.testing().test(.POST, "/v1.51/session") { res async in
                #expect(res.status == .notImplemented)
                guard let bodyData = res.body.string.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any],
                    let message = object["message"] as? String
                else {
                    Issue.record("body is not {\"message\": <string>}: \(res.body.string)")
                    return
                }
                #expect(message.contains("is not implemented by podm"))
                #expect(message.contains("/session"))
                #expect(message.contains("POST"), "the message must name the method buildx dialed with")
            }
        }
    }

    @Test("GET /session is no longer registered — no known client GETs it")
    func getSessionIsGone() async throws {
        try await withApp(configure: { app in
            let scratchAppSupport = FileManager.default.temporaryDirectory
                .appendingPathComponent("podm-session-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratchAppSupport, withIntermediateDirectories: true)
            _ = try await RouteRegistry.bootstrap(app, appSupportDirectory: scratchAppSupport)
        }) { app in
            try await app.testing().test(.GET, "/v1.51/session") { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}
