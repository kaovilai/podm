import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `POST /commit` (docker compat) and `POST /libpod/commit` — routing,
/// ordering, error mapping, and the commit event. The config merge itself is
/// covered by `ContainerCommitConfigTests`; the image synthesis pipeline by
/// the import tests.
@Suite("ContainerCommitRoute", .serialized)
struct ContainerCommitRouteTests {

    private static let rootfsBytes = Data("fake-rootfs-tar-content".utf8)
    private static let committedDigest = "sha256:cafebabe"

    // MARK: - Mocks

    private actor FakeCommitImageClient: ClientImageCommitProtocol {
        let parentConfig: ContainerizationOCI.ImageConfig?
        let result: Result<(reference: String?, digest: String), Error>
        private(set) var commitCalls: [CommitImageCall] = []

        struct CommitImageCall {
            let repo: String?
            let tag: String?
            let comment: String?
            let author: String?
            let config: SynthesizedImageConfig
            let tarBytes: Data?
        }

        init(
            parentConfig: ContainerizationOCI.ImageConfig? = nil,
            result: Result<(reference: String?, digest: String), Error> = .success(
                ("example/app:v2", committedDigest))
        ) {
            self.parentConfig = parentConfig
            self.result = result
        }

        func commitParentConfig(reference: String, platform: Platform) async -> ContainerizationOCI.ImageConfig? {
            parentConfig
        }

        func commitImage(
            tarPath: URL,
            repo: String?,
            tag: String?,
            comment: String?,
            author: String?,
            config: SynthesizedImageConfig,
            platform: Platform,
            appleContainerAppSupportUrl: URL,
            logger: Logger
        ) async throws -> (reference: String?, digest: String) {
            let tarBytes = try? Data(contentsOf: tarPath)
            commitCalls.append(
                CommitImageCall(
                    repo: repo, tag: tag, comment: comment, author: author, config: config, tarBytes: tarBytes))
            switch result {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
    }

    private actor FakeCommitArchiveClient: ClientArchiveProtocol {
        let exportResult: Result<Data, ClientArchiveError>
        private(set) var exportedContainerIds: [String] = []
        private(set) var exportedFile: URL?

        init(exportResult: Result<Data, ClientArchiveError> = .success(rootfsBytes)) {
            self.exportResult = exportResult
        }

        nonisolated func getRootfsPath(containerId: String) -> URL {
            URL(fileURLWithPath: "/nonexistent/rootfs.ext4")
        }

        func getArchive(containerId: String, path: String) async throws -> (tarData: Data, stat: PathStat) {
            throw ClientArchiveError.operationFailed(message: "not under test")
        }

        func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {
            throw ClientArchiveError.operationFailed(message: "not under test")
        }

        func exportRootfs(containerId: String) async throws -> URL {
            exportedContainerIds.append(containerId)
            switch exportResult {
            case .failure(let error):
                throw error
            case .success(let data):
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("commit-test-\(UUID().uuidString).tar")
                try data.write(to: url)
                exportedFile = url
                return url
            }
        }
    }

    private struct FixedSnapshotClientMock: ClientContainerProtocol {
        let snapshot: ContainerSnapshot

        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
        func getContainer(id: String) async throws -> ContainerSnapshot? {
            id == snapshot.id ? snapshot : nil
        }
        func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws {}
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws {}
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
            RESTContainerWait(statusCode: 0)
        }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
            ([], 0)
        }
    }

    private struct AmbiguousClientMock: ClientContainerProtocol {
        let reference: String
        let matches: [String]

        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
        func getContainer(id: String) async throws -> ContainerSnapshot? {
            throw ClientContainerError.ambiguousId(reference: reference, matches: matches)
        }
        func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws {}
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws {}
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
            RESTContainerWait(statusCode: 0)
        }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
            ([], 0)
        }
    }

    private struct EmptyClientMock: ClientContainerProtocol {
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
        func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
        func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws {}
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws {}
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
            RESTContainerWait(statusCode: 0)
        }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
            ([], 0)
        }
    }

    // MARK: - Harness

    private func withCommitApp(
        snapshot: ContainerSnapshot?,
        archive: FakeCommitArchiveClient = FakeCommitArchiveClient(),
        imageClient: FakeCommitImageClient = FakeCommitImageClient(),
        broadcaster: EventBroadcaster? = nil,
        containerClient: ClientContainerProtocol? = nil,
        libpod: Bool = false,
        run: (Application) async throws -> Void
    ) async throws {
        let client: ClientContainerProtocol =
            containerClient ?? snapshot.map { FixedSnapshotClientMock(snapshot: $0) } ?? EmptyClientMock()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[AppleContainerAppSupportUrlKey.self] = FileManager.default.temporaryDirectory
            if let broadcaster {
                app.storage[EventBroadcasterKey.self] = broadcaster
            }
            try app.register(
                collection: libpod
                    ? LibpodCommitRoute(containerClient: client, archiveClient: archive, imageClient: imageClient)
                    : CommitRoute(containerClient: client, archiveClient: archive, imageClient: imageClient))
            try await run(app)
        }
    }

    // MARK: - Success

    @Test("a successful commit answers 201 with moby's Id-only body and forwards the merged pipeline inputs")
    func commitSucceeds() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let imageClient = FakeCommitImageClient()
        let archive = FakeCommitArchiveClient()

        try await withCommitApp(snapshot: snapshot, archive: archive, imageClient: imageClient) { app in
            let body = ByteBuffer(string: #"{"Cmd": ["sleep", "1"], "Labels": {"app": "web"}}"#)
            try await app.testing().test(
                .POST,
                "/v1.51/commit?container=web&repo=example/app&tag=v2&comment=fix%20thing&author=dev",
                headers: ["Content-Type": "application/json"],
                body: body
            ) { res async throws in
                #expect(res.status == .created)
                let response = try res.content.decode(RESTCommitIDResponse.self)
                #expect(response.Id == Self.committedDigest)
            }
        }

        let calls = await imageClient.commitCalls
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.repo == "example/app")
        #expect(call.tag == "v2")
        #expect(call.comment == "fix thing")
        #expect(call.author == "dev")
        // The body's Cmd and Labels reached the merged config; the layer is
        // the container's exported rootfs, byte for byte.
        #expect(call.config.cmd == ["sleep", "1"])
        #expect(call.config.labels["app"] == "web")
        #expect(call.tarBytes == Self.rootfsBytes)
    }

    @Test("an absent repo commits an untagged image (repo/tag nil, not empty strings)")
    func untaggedCommit() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let imageClient = FakeCommitImageClient(
            result: .success((nil, Self.committedDigest)))

        try await withCommitApp(snapshot: snapshot, imageClient: imageClient) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web") { res async throws in
                #expect(res.status == .created)
                #expect(try res.content.decode(RESTCommitIDResponse.self).Id == Self.committedDigest)
            }
        }

        let calls = await imageClient.commitCalls
        #expect(try #require(calls.first).repo == nil)
        #expect(try #require(calls.first).comment == nil)
        #expect(try #require(calls.first).author == nil)
    }

    @Test("an empty body is accepted — the config is seeded from the container alone")
    func emptyBodyAccepted() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let imageClient = FakeCommitImageClient()

        try await withCommitApp(snapshot: snapshot, imageClient: imageClient) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web&repo=example/app") { res async in
                #expect(res.status == .created)
            }
        }

        let calls = await imageClient.commitCalls
        #expect(calls.count == 1)
        #expect(try #require(calls.first).config.cmd == nil)
    }

    @Test("pause and squash are accepted and ignored")
    func pauseAndSquashAccepted() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)

        try await withCommitApp(snapshot: snapshot) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web&pause=true&squash=true") { res async in
                #expect(res.status == .created)
            }
        }
    }

    @Test("the parent image config seeds the merged config")
    func parentConfigSeeds() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let parent = ContainerizationOCI.ImageConfig(
            env: ["PARENT=1"], entrypoint: ["/app"], cmd: ["serve"])
        let imageClient = FakeCommitImageClient(parentConfig: parent)

        try await withCommitApp(snapshot: snapshot, imageClient: imageClient) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web") { res async in
                #expect(res.status == .created)
            }
        }

        let calls = await imageClient.commitCalls
        let config = try #require(calls.first?.config)
        #expect(config.entrypoint == ["/bin/sh"])
        #expect(config.env.contains("PARENT=1"))
    }

    @Test("the exported rootfs tarball is deleted once the commit finishes")
    func tarballCleanedUp() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let archive = FakeCommitArchiveClient()

        try await withCommitApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web") { res async in
                #expect(res.status == .created)
            }
        }

        let exportedFile = await archive.exportedFile
        let cleaned = try await pollUntil(timeoutSeconds: 3) {
            exportedFile.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
        #expect(cleaned, "the exported rootfs tar must be deleted after the commit")
    }

    // MARK: - Ordering and error mapping

    @Test("an unknown container 404s before any archive or image work starts")
    func unknownContainer404First() async throws {
        let archive = FakeCommitArchiveClient()
        let imageClient = FakeCommitImageClient()

        try await withCommitApp(snapshot: nil, archive: archive, imageClient: imageClient) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=conformance-dummy") { res async throws in
                #expect(res.status == .notFound)
                let body = try res.content.decode(ErrorBody.self)
                #expect(body.reason.contains("No such container: conformance-dummy"))
            }
        }

        let exported = await archive.exportedContainerIds
        #expect(exported.isEmpty, "no rootfs export may run for a bogus reference")
        let calls = await imageClient.commitCalls
        #expect(calls.isEmpty, "no image synthesis may run for a bogus reference")
    }

    @Test("a missing container query parameter also 404s, like both daemons' lookups")
    func missingContainerParam() async throws {
        try await withCommitApp(snapshot: nil) { app in
            try await app.testing().test(.POST, "/v1.51/commit") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("an ambiguous container reference answers 400")
    func ambiguousReference() async throws {
        try await withCommitApp(
            snapshot: nil,
            containerClient: AmbiguousClientMock(reference: "web", matches: ["web1", "web2"])
        ) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("ambiguous container reference web"))
            }
        }
    }

    @Test("a malformed JSON body answers 400 without any archive work")
    func malformedBody() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let archive = FakeCommitArchiveClient()

        try await withCommitApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(
                .POST, "/v1.51/commit?container=web",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Cmd": not-json"#)
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }

        let exported = await archive.exportedContainerIds
        #expect(exported.isEmpty)
    }

    @Test("a digest repo reference answers 400, matching import's grammar")
    func digestRepoRejected() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)

        try await withCommitApp(snapshot: snapshot) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/commit?container=web&repo=foo@sha256:\(String(repeating: "a", count: 64))"
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("cannot reference"))
            }
        }
    }

    @Test("an invalid --change instruction answers 400 before any archive work")
    func invalidChangeRejected() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let archive = FakeCommitArchiveClient()

        try await withCommitApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web&changes=ONBUILD%20%2Fbin%2Ftrue") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("not a supported --change instruction"))
            }
        }

        let exported = await archive.exportedContainerIds
        #expect(exported.isEmpty)
    }

    @Test("an unknown libpod format value answers 400")
    func unknownFormatRejected() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)

        try await withCommitApp(snapshot: snapshot) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web&format=sif") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("a missing rootfs answers 404")
    func missingRootfs() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let archive = FakeCommitArchiveClient(exportResult: .failure(.rootfsNotFound(id: "web")))

        try await withCommitApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("an export failure surfaces as 500 with moby's message shape")
    func exportFailure() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let archive = FakeCommitArchiveClient(exportResult: .failure(.operationFailed(message: "corrupted superblock")))

        try await withCommitApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("Error exporting container web"))
            }
        }
    }

    @Test("an image synthesis failure surfaces as 500")
    func commitFailure() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let imageClient = FakeCommitImageClient(
            result: .failure(ClientImageError.notFound(id: "example/app")))

        try await withCommitApp(snapshot: snapshot, imageClient: imageClient) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web&repo=example/app") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("Error committing container web"))
            }
        }
    }

    // MARK: - libpod dialect

    @Test("the libpod dialect dispatches to the same handler but answers 200 like podman")
    func libpodDialect() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)

        try await withCommitApp(snapshot: snapshot, libpod: true) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/commit?container=web&repo=example/app") { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(RESTCommitIDResponse.self).Id == Self.committedDigest)
            }
        }
    }

    // MARK: - Event

    @Test("a commit broadcasts a container 'commit' event with comment, imageID and imageRef")
    func commitEmitsEvent() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "commit" && event.Type == "container" {
                return event
            }
            return nil
        }

        try await withCommitApp(snapshot: snapshot, broadcaster: broadcaster) { app in
            try await app.testing().test(
                .POST, "/v1.51/commit?container=web&repo=example/app&tag=v2&comment=fix%20thing"
            ) { res async in
                #expect(res.status == .created)
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            captureTask.cancel()
        }
        let event = await captureTask.value
        timeoutTask.cancel()

        #expect(event?.Actor.ID == DockerContainerID.hexId(for: snapshot))
        #expect(event?.Actor.Attributes["name"] == "web")
        #expect(event?.Actor.Attributes["comment"] == "fix thing")
        #expect(event?.Actor.Attributes["imageID"] == Self.committedDigest)
        #expect(event?.Actor.Attributes["imageRef"] == "example/app:v2")
    }
}

private struct ErrorBody: Vapor.Content { let reason: String }
