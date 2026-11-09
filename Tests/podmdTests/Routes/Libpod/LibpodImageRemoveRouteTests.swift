import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Route-level coverage for `DELETE /libpod/images/remove` — the endpoint `podman rmi`
/// (remote/bindings client, v6.x) actually calls. Two things must hold:
///
/// 1. **Precedence** — the literal `/libpod/images/remove` must beat the
///    `/libpod/images/{name:.*}` wildcard registered by `LibpodImageDeleteRoute`
///    (the original bug: `podman rmi` tried to delete an image literally named
///    "remove"). Both collections are registered here exactly as configure.swift
///    does, so ordering/specificity is exercised, not assumed.
/// 2. **Contract** — one `LibpodImagesRemoveReport` object (Deleted/Untagged/ExitCode
///    + Errors), HTTP 200 even when individual images are missing, per podman's
///    `libpod.ImagesBatchRemove` + `pkg/bindings/images/rm.go`.
@Suite("LibpodImageRemoveRoute")
struct LibpodImageRemoveRouteTests {

    // MARK: - Precedence (the bug)

    @Test("DELETE /libpod/images/remove reaches the batch handler, not the {name} wildcard")
    func removeBeatsWildcard() async throws {
        let mock = BatchRemoveImageMock()
        mock.results["alpine:latest"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/alpine:latest", digest: "sha256:aaa", deletedDigest: "sha256:aaa"))

        try await withRemoveApp(mock) { app in
            try await app.testing().test(.DELETE, "/v1.51/libpod/images/remove?images=alpine:latest") { res async throws in
                #expect(res.status == .ok, "batch remove always answers 200 (per-image failures ride in Errors)")
                let report = try JSONDecoder().decode(LibpodImageRemoveReport.self, from: Data(buffer: res.body))
                #expect(report.ExitCode == 0)
                #expect(report.Errors.isEmpty)
                // A single report object with ExitCode is the libpod shape; the wildcard's
                // docker dialect would have answered an array of {Deleted, Untagged}.
                #expect(report.Untagged == ["docker.io/library/alpine:latest"])
            }
        }
        #expect(mock.deletedIds == ["alpine:latest"], "must not try to delete an image named 'remove'")
    }

    @Test("the {name} wildcard still serves ordinary single-image deletes")
    func wildcardStillServesNormalNames() async throws {
        let mock = BatchRemoveImageMock()
        mock.results["alpine:latest"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/alpine:latest", digest: "sha256:aaa", deletedDigest: "sha256:aaa"))

        try await withRemoveApp(mock) { app in
            try await app.testing().test(.DELETE, "/v1.51/libpod/images/alpine:latest") { res async throws in
                #expect(res.status == .ok)
                // Docker-dialect array shape — proves the wildcard route still wins for
                // non-literal names now that /remove exists.
                let items = try JSONDecoder().decode([ImageDeleteResponseItem].self, from: Data(buffer: res.body))
                #expect(items.compactMap(\.Untagged) == ["docker.io/library/alpine:latest"])
            }
        }
        #expect(mock.deletedIds == ["alpine:latest"])
    }

    // MARK: - Batch semantics

    @Test("multiple images accumulate into one report")
    func batchAccumulatesReports() async throws {
        let mock = BatchRemoveImageMock()
        mock.results["alpine:latest"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/alpine:latest", digest: "sha256:aaa", deletedDigest: "sha256:aaa"))
        mock.results["busybox:latest"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/busybox:latest", digest: "sha256:bbb", deletedDigest: nil))

        try await withRemoveApp(mock) { app in
            try await app.testing().test(.DELETE, "/v1.51/libpod/images/remove?images=alpine:latest&images=busybox:latest") {
                res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodImageRemoveReport.self, from: Data(buffer: res.body))
                #expect(report.ExitCode == 0)
                #expect(report.Errors.isEmpty)
                #expect(
                    Set(report.Untagged ?? []) == ["docker.io/library/alpine:latest", "docker.io/library/busybox:latest"])
                // busybox kept another tag, so only alpine's layers were freed.
                #expect(report.Deleted == ["sha256:aaa"])
            }
        }
        #expect(Set(mock.deletedIds) == Set(["alpine:latest", "busybox:latest"]))
    }

    @Test("a missing image yields an error entry and exit code 1, not an HTTP error")
    func missingImageIsReportedNotThrown() async throws {
        let mock = BatchRemoveImageMock()
        mock.results["alpine:latest"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/alpine:latest", digest: "sha256:aaa", deletedDigest: "sha256:aaa"))

        try await withRemoveApp(mock) { app in
            try await app.testing().test(.DELETE, "/v1.51/libpod/images/remove?images=alpine:latest&images=no-such-image") {
                res async throws in
                #expect(res.status == .ok, "batch remove reports per-image failures in-band")
                let report = try JSONDecoder().decode(LibpodImageRemoveReport.self, from: Data(buffer: res.body))
                #expect(report.ExitCode == 1)
                #expect(report.Errors.count == 1)
                #expect(report.Errors.first?.contains("no-such-image") == true)
                // The successful image is still reported.
                #expect(report.Untagged == ["docker.io/library/alpine:latest"])
            }
        }
    }

    @Test("ignore skips missing images silently (podman rmi --ignore)")
    func ignoreSkipsMissingImages() async throws {
        let mock = BatchRemoveImageMock()

        try await withRemoveApp(mock) { app in
            try await app.testing().test(.DELETE, "/v1.51/libpod/images/remove?images=no-such-image&ignore=true") {
                res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodImageRemoveReport.self, from: Data(buffer: res.body))
                #expect(report.ExitCode == 0)
                #expect(report.Errors.isEmpty)
                #expect(report.Deleted == nil && report.Untagged == nil)
            }
        }
    }

    @Test("all=true removes every listed reference — including sibling tags sharing a digest")
    func allRemovesEveryImage() async throws {
        let mock = BatchRemoveImageMock()
        mock.listedImages = [
            makeClientImage(reference: "docker.io/library/alpine:latest", digest: "sha256:aaa"),
            makeClientImage(reference: "docker.io/library/alpine:3.21", digest: "sha256:aaa"),
            makeClientImage(reference: "docker.io/library/busybox:latest", digest: "sha256:bbb"),
        ]
        mock.results["docker.io/library/alpine:latest"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/alpine:latest", digest: "sha256:aaa", deletedDigest: nil))
        mock.results["docker.io/library/alpine:3.21"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/alpine:3.21", digest: "sha256:aaa", deletedDigest: nil))
        mock.results["docker.io/library/busybox:latest"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/busybox:latest", digest: "sha256:bbb", deletedDigest: "sha256:bbb"))

        try await withRemoveApp(mock) { app in
            try await app.testing().test(.DELETE, "/v1.51/libpod/images/remove?all=true") { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodImageRemoveReport.self, from: Data(buffer: res.body))
                #expect(report.ExitCode == 0)
                #expect(report.Deleted == ["sha256:bbb"])
            }
        }
        // Every reference is deleted — deduplicating by digest would leave
        // the second alpine tag behind while reporting success.
        #expect(
            Set(mock.deletedIds)
                == Set(["docker.io/library/alpine:latest", "docker.io/library/alpine:3.21", "docker.io/library/busybox:latest"]))
    }

    @Test("JSON body {images, force, all} is accepted as a fallback transport")
    func jsonBodyFallback() async throws {
        let mock = BatchRemoveImageMock()
        mock.results["alpine:latest"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/alpine:latest", digest: "sha256:aaa", deletedDigest: "sha256:aaa"))

        try await withRemoveApp(mock) { app in
            try await app.testing().test(
                .DELETE, "/v1.51/libpod/images/remove",
                beforeRequest: { req in
                    try req.content.encode(RemoveRequestBody(images: ["alpine:latest"], force: true, all: nil))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodImageRemoveReport.self, from: Data(buffer: res.body))
                #expect(report.ExitCode == 0)
                #expect(report.Untagged == ["docker.io/library/alpine:latest"])
            }
        }
        #expect(mock.deletedIds == ["alpine:latest"])
    }

    @Test("JSON body {all: true} removes every listed image")
    func jsonBodyAllFallback() async throws {
        let mock = BatchRemoveImageMock()
        mock.listedImages = [
            makeClientImage(reference: "docker.io/library/alpine:latest", digest: "sha256:aaa"),
            makeClientImage(reference: "docker.io/library/busybox:latest", digest: "sha256:bbb"),
        ]
        mock.results["docker.io/library/alpine:latest"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/alpine:latest", digest: "sha256:aaa", deletedDigest: "sha256:aaa"))
        mock.results["docker.io/library/busybox:latest"] = .success(
            ImageDeletionResult(untagged: "docker.io/library/busybox:latest", digest: "sha256:bbb", deletedDigest: "sha256:bbb"))

        try await withRemoveApp(mock) { app in
            try await app.testing().test(
                .DELETE, "/v1.51/libpod/images/remove",
                beforeRequest: { req in
                    try req.content.encode(RemoveRequestBody(images: nil, force: nil, all: true))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodImageRemoveReport.self, from: Data(buffer: res.body))
                #expect(report.ExitCode == 0)
                #expect(Set(report.Deleted ?? []) == Set(["sha256:aaa", "sha256:bbb"]))
            }
        }
        #expect(
            Set(mock.deletedIds) == Set(["docker.io/library/alpine:latest", "docker.io/library/busybox:latest"]))
    }

    @Test("empty batch returns an empty report with exit code 0")
    func emptyBatchIsEmptySuccess() async throws {
        let mock = BatchRemoveImageMock()

        try await withRemoveApp(mock) { app in
            try await app.testing().test(.DELETE, "/v1.51/libpod/images/remove") { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodImageRemoveReport.self, from: Data(buffer: res.body))
                #expect(report.ExitCode == 0)
                #expect(report.Errors.isEmpty)
                #expect(report.Deleted == nil && report.Untagged == nil)
            }
        }
        #expect(mock.deletedIds.isEmpty)
    }

    @Test("queryFlag matches podman truthiness — bare/empty flags are false")
    func queryFlagSemantics() {
        // Absent key: nil (distinguishes from an explicit false).
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: nil) == nil)
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "force=true") == nil)
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "images=x") == nil)
        // Explicit values, case-insensitive and percent-decoded (ParseBool set).
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "all=true") == true)
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "all=True") == true)
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "all=t") == true)
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "all=1") == true)
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "all=%74rue") == true)
        // Podman parity (httputils.BoolValue + strconv.ParseBool): a bare or
        // empty flag is FALSE — never true on a delete-everything endpoint.
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "all") == false)
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "all=") == false)
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "all=false") == false)
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "all=0") == false)
        // A similar-looking key must not match.
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "allow=true") == nil)
        // Degenerate pairs (empty or "="-only) never match a key.
        #expect(LibpodImageRemoveRoute.queryFlag("all", in: "=true&all=true") == true)
    }

    // NOTE: the over-limit body path (`try await req.body.collect()` throwing)
    // is enforced by the real HTTP server's streaming layer before the route
    // runs, and cannot be reached through VaporTesting — beforeRequest bodies
    // are pre-collected, so collect() is always a no-op success there.

    // MARK: - Helpers

    /// Registers BOTH the pre-existing wildcard delete route and the new remove
    /// route, in the same order configure.swift registers them (delete at ~250,
    /// remove at ~251), so precedence is exercised against the production
    /// registration sequence — RegexRouter.insertSorted orders by specificity,
    /// so this also pins that order-independence isn't load-bearing.
    private func withRemoveApp(_ mock: BatchRemoveImageMock, test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: LibpodImageDeleteRoute(client: mock))
            try app.register(collection: LibpodImageRemoveRoute(client: mock))
            try await test(app)
        }
    }
}

// MARK: - Mocks

/// Body shape for the JSON-body fallback test.
private struct RemoveRequestBody: Vapor.Content {
    let images: [String]?
    let force: Bool?
    let all: Bool?
}

/// Image client whose `delete(id:)` answers from a per-reference result table, recording
/// every id it was asked to delete so tests can assert which route handled the request.
private final class BatchRemoveImageMock: ClientImageProtocol, @unchecked Sendable {
    var results: [String: Result<ImageDeletionResult, Error>] = [:]
    var listedImages: [ClientImage] = []
    private(set) var deletedIds: [String] = []

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { listedImages }

    func delete(id: String) async throws -> ImageDeletionResult {
        deletedIds.append(id)
        switch results[id] ?? .failure(ClientImageError.notFound(id: id)) {
        case .success(let result): return result
        case .failure(let error): throw error
        }
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

private func makeClientImage(reference: String, digest: String) -> ClientImage {
    ClientImage(
        description: ImageDescription(
            reference: reference,
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: digest,
                size: 0
            )
        )
    )
}
