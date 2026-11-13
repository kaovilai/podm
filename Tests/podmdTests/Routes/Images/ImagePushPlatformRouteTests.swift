import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `podman push --platform` changed wire form in 6.2: the single `platform`
/// query param became separate `os`/`arch`/`variant` fields (empty strings
/// when unset) — caught by the wire-contract harness's first canary run.
/// Both dialects share one handler, so both wire forms must reach
/// `client.push` with the same `Platform` selection.
@Suite("ImagePushRoute — platform query dialects")
struct ImagePushPlatformRouteTests {

    @Test("docker's single platform param selects the platform")
    func dockerSinglePlatformParam() async throws {
        let recorded = try await Self.push(query: "platform=linux/arm64")
        #expect(recorded == Platform(arch: "arm64", os: "linux"))
    }

    @Test("podman 6.2's separate os/arch/variant fields select the platform")
    func podman62SeparateFields() async throws {
        let recorded = try await Self.push(query: "os=linux&arch=arm64&variant=v8")
        #expect(recorded == Platform(arch: "arm64", os: "linux", variant: "v8"))
    }

    @Test("podman 6.2 without a variant still selects the platform")
    func podman62WithoutVariant() async throws {
        let recorded = try await Self.push(query: "os=linux&arch=amd64")
        #expect(recorded == Platform(arch: "amd64", os: "linux"))
    }

    @Test("podman 6.2's empty platform fields mean no selection (whole manifest list)")
    func podman62EmptyFieldsPushEverything() async throws {
        let recorded = try await Self.push(query: "os=&arch=&variant=")
        #expect(recorded == nil)
    }

    @Test("an incomplete platform tuple answers 400, never a shifted variant")
    func incompleteTupleAnswers400() async throws {
        // Dropping the empty arch and joining would reinterpret the variant
        // as the architecture (linux/amd64) — a push the caller never asked
        // for. Positions are meaningful: require os and arch.
        try await withApp(configure: { _ in }) { app in
            try await Self.registerRoutes(app, pushRecorder: Box(nil))
            try await app.testing().test(.POST, "v1.51/images/alpine:latest/push?os=linux&arch=&variant=amd64") { res async throws in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.POST, "v1.51/images/alpine:latest/push?os=linux") { res async throws in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.POST, "v1.51/images/alpine:latest/push?arch=arm64") { res async throws in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.POST, "v1.51/images/alpine:latest/push?variant=v8") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("the single platform param is primary; leftover tuple fields never override or reject it")
    func singleParamIsPrimary() async throws {
        // A conflicting mixed form selects the single param's platform.
        let conflicting = try await Self.push(query: "platform=linux/arm64&os=linux&arch=amd64")
        #expect(conflicting == Platform(arch: "arm64", os: "linux"))

        // A valid platform is not rejected by an incomplete leftover tuple.
        let partial = try await Self.push(query: "platform=linux/arm64&os=linux&arch=")
        #expect(partial == Platform(arch: "arm64", os: "linux"))
    }

    @Test("an invalid platform string still answers 400, not a silent full push")
    func invalidPlatformAnswers400() async throws {
        try await withApp(configure: { _ in }) { app in
            try await Self.registerRoutes(app, pushRecorder: Box(nil))
            try await app.testing().test(.POST, "v1.51/images/alpine:latest/push?platform=bogus") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("the libpod dialect accepts the same separate fields")
    func libpodDialectSeparateFields() async throws {
        let recorder = Box<Platform?>(nil)
        try await withApp(configure: { _ in }) { app in
            try await Self.registerRoutes(app, pushRecorder: recorder)
            try await app.testing().test(.POST, "v1.51/libpod/images/alpine:latest/push?os=linux&arch=arm64") { res async throws in
                #expect(res.status == .ok)
            }
        }
        #expect(try await recorder.get() == Platform(arch: "arm64", os: "linux"))
    }

    // MARK: - Helpers

    private static func push(query: String) async throws -> Platform? {
        let recorder = Box<Platform?>(nil)
        try await withApp(configure: { _ in }) { app in
            try await registerRoutes(app, pushRecorder: recorder)
            try await app.testing().test(.POST, "v1.51/images/alpine:latest/push?\(query)") { res async throws in
                #expect(res.status == .ok)
            }
        }
        return try await recorder.get()
    }

    private static func registerRoutes(_ app: Application, pushRecorder: Box<Platform?>) throws {
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        let imageMock = PlatformRecordingImageMock(pushRecorder: pushRecorder)
        let manifestMock = MockManifestClient()
        try app.register(collection: ImagePushRoute(client: imageMock, manifestClient: manifestMock))
        try app.register(collection: LibpodImagePushRoute(client: imageMock, manifestClient: manifestMock))
    }
}

/// Records the `platform` argument of every `push` call into a box.
private struct PlatformRecordingImageMock: ClientImageProtocol {
    let pushRecorder: Box<Platform?>

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        ImageDeletionResult(untagged: "", digest: "", deletedDigest: nil)
    }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        await pushRecorder.set(platform)
        return AsyncThrowingStream { $0.finish() }
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
