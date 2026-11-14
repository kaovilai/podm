import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `podman pull --platform` does NOT send a `platform` query parameter: the
/// remote client sends `os`, `arch` and `variant` separately (an empty
/// `variant` when the platform has none). The route read only `platform`, so
/// every `--platform` ask silently fell back to the host platform —
/// `podman pull --platform linux/amd64` fetched the arm64 image, and
/// `podman run --platform linux/amd64|linux/s390x` then ran arm64.
@Suite("LibpodImagePullRoute — platform query (os/arch/variant)")
struct LibpodImagePullPlatformTests {

    @Test("podman's os/arch/variant parameters select the requested platform")
    func osArchVariant() async throws {
        let client = RecordingPullClient()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodImagePullRoute(client: client))

            try await app.testing().test(
                .POST, "/v1.51/libpod/images/pull?reference=alpine&os=linux&arch=s390x&variant="
            ) { res async in
                #expect(res.status == .ok)
            }
        }
        let platform = try #require(await client.lastPlatform)
        #expect(platform.os == "linux")
        #expect(platform.architecture == "s390x")
    }

    @Test("a variant is carried through (linux/arm/v7)")
    func variantCarried() async throws {
        let client = RecordingPullClient()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodImagePullRoute(client: client))

            try await app.testing().test(
                .POST, "/v1.51/libpod/images/pull?reference=alpine&os=linux&arch=arm&variant=v7"
            ) { res async in
                #expect(res.status == .ok)
            }
        }
        let platform = try #require(await client.lastPlatform)
        #expect(platform.architecture == "arm")
        #expect(platform.variant == "v7")
    }

    @Test("the combined platform parameter still wins (other libpod clients send it)")
    func platformParamWins() async throws {
        let client = RecordingPullClient()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodImagePullRoute(client: client))

            try await app.testing().test(
                .POST, "/v1.51/libpod/images/pull?reference=alpine&platform=linux%2Famd64&os=linux&arch=s390x"
            ) { res async in
                #expect(res.status == .ok)
            }
        }
        let platform = try #require(await client.lastPlatform)
        #expect(platform.architecture == "amd64")
    }

    @Test("no platform at all pulls the host platform")
    func defaultsToHost() async throws {
        let client = RecordingPullClient()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodImagePullRoute(client: client))

            try await app.testing().test(.POST, "/v1.51/libpod/images/pull?reference=alpine") { res async in
                #expect(res.status == .ok)
            }
        }
        let platform = try #require(await client.lastPlatform)
        #expect(platform == currentPlatform())
    }

    @Test("an unparseable os/arch answers 400 rather than pulling the host platform")
    func badPlatformRejected() async throws {
        let client = RecordingPullClient()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodImagePullRoute(client: client))

            try await app.testing().test(
                .POST, "/v1.51/libpod/images/pull?reference=alpine&os=linux&arch=not%2Fan%2Farch"
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
        #expect(await client.lastPlatform == nil, "a rejected platform must never reach the pull")
    }
}

/// Records the platform the route hands to the pull; the stream completes
/// immediately, so the route never blocks on progress.
private actor RecordingPullClient: ClientImageProtocol {
    private(set) var lastPlatform: Platform?

    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<
        PullProgress, Error
    > {
        lastPlatform = platform
        return AsyncThrowingStream { $0.finish() }
    }

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> podmd.ImageDeletionResult {
        ImageDeletionResult(untagged: "", digest: "", deletedDigest: nil)
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func pushManifestList(reference: String, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        ([], 0)
    }
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        URL(fileURLWithPath: "/dev/null")
    }
    func importImage(
        tarPath: URL, repo: String?, tag: String?, message: String?, changes: [String], platform: Platform,
        appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        (nil, "sha256:0000000000000000000000000000000000000000000000000000000000000000")
    }
}
