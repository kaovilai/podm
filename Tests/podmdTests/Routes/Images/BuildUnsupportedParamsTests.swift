import ContainerBuild
import ContainerPersistence
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Issue #54: `--build-context` (additionalbuildcontexts, sent REPEATED as one
/// JSON map entry per context by podman) and remote URL contexts were silently
/// dropped — a Dockerfile using `COPY --from=<name>` then failed mid-build
/// with a confusing "no such context" error, and a remote context failed as
/// "Dockerfile does not exist" in the daemon's cwd. Both now answer an honest
/// request-level 400 naming the actual gap.
///
/// The 400 fires during query validation, before any client is touched — the
/// mocks only need to satisfy route registration.
@Suite("BuildRoute — unsupported-but-build-changing params answer 400")
struct BuildUnsupportedParamsTests {

    private static func registerRoutes(_ app: Application) throws {
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        let client = StaticSnapshotClientMock(
            snapshot: try makeContainerSnapshot(nativeId: "wc", networks: [], labels: [:]))
        let builder = BuilderClientNoop()
        let systemConfig = ContainerSystemConfig()
        try app.register(
            collection: BuildRoute(
                client: client, builderClient: builder, systemConfig: systemConfig,
                manifestClient: MockManifestClient()))
        try app.register(
            collection: LibpodBuildRoute(
                client: client, builderClient: builder, systemConfig: systemConfig,
                manifestClient: MockManifestClient()))
    }

    @Test("additionalbuildcontexts answers 400, in both dialects, repeated or single")
    func additionalBuildContextsRejected() async throws {
        try await withApp(configure: { _ in }) { app in
            try await Self.registerRoutes(app)

            // Podman's wire form: one JSON map entry per --build-context.
            try await app.testing().test(
                .POST,
                "v1.51/build?additionalbuildcontexts=%7B%22ctx2%22%3A%20%22.%2Fextra%22%7D&t=wc"
            ) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try Self.body(res).contains("additional build contexts"))
            }
            try await app.testing().test(
                .POST,
                "v1.51/libpod/build?additionalbuildcontexts=%7B%22ctx2%22%3A%20%22.%2Fextra%22%7D"
            ) { res async throws in
                #expect(res.status == .badRequest)
            }
            // A single scalar value must trip the same guard (Vapor's decoder
            // would silently keep only the last of a repeated run).
            try await app.testing().test(.POST, "v1.51/build?additionalbuildcontexts=ctx2") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("A remote URL context answers 400 instead of building the daemon's cwd")
    func remoteContextRejected() async throws {
        try await withApp(configure: { _ in }) { app in
            try await Self.registerRoutes(app)

            try await app.testing().test(
                .POST, "v1.51/build?remote=https%3A%2F%2Fexample.com%2Fctx.tar"
            ) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try Self.body(res).contains("remote build contexts"))
            }
            // Present but blank is not an ask — must not produce the
            // unsupported-param 400 (it fails later on the empty body/context
            // instead, like any context-less build).
            try await app.testing().test(.POST, "v1.51/build?remote=") { res async throws in
                let body = try Self.body(res)
                #expect(!(res.status == .badRequest && body.contains("remote build contexts")))
            }
        }
    }

    private static func body(_ res: TestingHTTPResponse) throws -> String {
        String(buffer: res.body)
    }
}

/// No-op builder client: the 400 fires during query validation, before any
/// builder is touched — this only needs to satisfy route registration.
private struct BuilderClientNoop: ClientBuilderProtocol {
    func ensureReachable(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logger) async throws {}
    func connect(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logger) async throws -> Builder {
        throw Abort(.internalServerError, reason: "not reached in these tests")
    }
    func ensureReachable(
        timeout: Duration, retryInterval: Duration, qemu: Bool, requested: BuilderResourceRequest?, logger: Logger
    ) async throws {}
    func connect(
        timeout: Duration, retryInterval: Duration, qemu: Bool, requested: BuilderResourceRequest?, logger: Logger
    ) async throws -> Builder {
        throw Abort(.internalServerError, reason: "not reached in these tests")
    }
    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult {
        BuilderPruneResult(deletedCaches: [], spaceReclaimed: 0)
    }
    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord] { [] }
}
