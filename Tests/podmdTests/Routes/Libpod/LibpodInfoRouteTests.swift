import ContainerAPIClient
import ContainerPersistence
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `podman info` unmarshals /libpod/info into podman's `define.Info`, whose
/// `Host` and `Store` are POINTERS, then writes `info.Host.ServiceIsRemote` —
/// serving the flat Docker-dialect payload here left `Host` nil and PANICKED
/// the client CLI (cmd/podman/system/info.go:83). The libpod schema must keep
/// `host`/`store` as JSON objects.
@Suite("LibpodInfoRoute — podman-schema payload")
struct LibpodInfoRouteTests {

    @Test("Serves the libpod schema: host and store are objects with real counts")
    func libpodSchema() async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(
                collection: LibpodInfoRoute(
                    containerClient: StaticSnapshotClientMock(
                        snapshot: try makeContainerSnapshot(
                            nativeId: "wc", networks: [], labels: [:])),
                    imageClient: TwoImageClientMock(),
                    volumeClient: EmptyVolumeClientMock()))

            try await app.testing().test(.GET, "v1.51/libpod/info") { res async throws in
                #expect(res.status == .ok)
                let json =
                    try JSONSerialization.jsonObject(
                        with: Data(buffer: res.body)) as? [String: Any]
                let root = try #require(json)

                // The panic trigger: both pointers must unmarshal as objects.
                let host = try #require(root["host"] as? [String: Any], "host must be an object — podman derefs it")
                let store = try #require(root["store"] as? [String: Any], "store must be an object")

                #expect(host["cpus"] as? Int == hostCPUCoreCount())
                #expect((host["memTotal"] as? NSNumber).map { $0.int64Value > 0 } == true)
                let socket = try #require(host["remoteSocket"] as? [String: Any])
                #expect((socket["path"] as? String)?.hasSuffix("container.sock") == true)
                #expect(host["serviceIsRemote"] as? Bool == true)

                let containerStore = try #require(store["containerStore"] as? [String: Any])
                #expect(containerStore["number"] as? Int == 1)
                #expect((store["imageStore"] as? [String: Any])?["number"] as? Int == 0)

                let version = try #require(root["version"] as? [String: Any])
                #expect(version["APIVersion"] as? String == "5.0.0")
                #expect((version["OsArch"] as? String)?.hasPrefix("linux/") == true)

                // registries/plugins exist as render-safe shapes.
                #expect(root["registries"] as? [String: Any] != nil)
                #expect(root["plugins"] as? [String: Any] != nil)
            }
        }
    }
}

private struct TwoImageClientMock: ClientImageProtocol {
    func list(includeSystemImages: Bool) async throws -> [ClientImage] {
        // Empty: count-wiring is proved by containerStore's real fixture;
        // ClientImage has no cheap test initializer.
        []
    }
    func delete(id: String) async throws -> podmd.ImageDeletionResult {
        ImageDeletionResult(untagged: "", digest: "", deletedDigest: nil)
    }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
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

private struct EmptyVolumeClientMock: ClientVolumeProtocol {
    func create(request: RESTVolumeCreate) async throws -> Volume {
        throw Abort(.internalServerError, reason: "not reached in these tests")
    }
    func delete(name: String) async throws {}
    func list(filters: String?, logger: Logger) async throws -> [Volume] { [] }
    func inspect(name: String) async throws -> Volume {
        throw Abort(.notFound, reason: "not reached in these tests")
    }
}
