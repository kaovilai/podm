import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

private struct ChangesMock: ClientContainerProtocol {
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

private func makeSnapshot(id: String, imageDigest: String) -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
    )
    let img = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: imageDigest,
            size: 0
        )
    )
    let config = ContainerConfiguration(id: id, image: img, process: proc)
    return ContainerSnapshot(configuration: config, status: .running, networks: [])
}

/// A throwaway Apple-container app-support tree holding one image snapshot
/// (baseline ext4) and one container rootfs (current ext4).
private struct ChangesFixture {
    static let manifestDigest = "aaaa"

    let appSupport: URL
    let containerId: String

    init(containerId: String) {
        appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("changes-route-\(UUID().uuidString)")
        self.containerId = containerId
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
    }

    /// Install a baseline image snapshot keyed by the manifest digest and a
    /// container rootfs, both built from the given file trees.
    func install(
        baselineFiles: [String: String],
        currentFiles: [String: String]
    ) throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }
        let baselineDevice = try baseline.write(files: baselineFiles)
        let currentDevice = try current.write(files: currentFiles)

        let snapshotDir =
            appSupport
            .appendingPathComponent("snapshots")
            .appendingPathComponent(Self.manifestDigest)
        let containerDir = appSupport.appendingPathComponent("containers").appendingPathComponent(containerId)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: baselineDevice, to: snapshotDir.appendingPathComponent("snapshot"))
        try FileManager.default.copyItem(at: currentDevice, to: containerDir.appendingPathComponent("rootfs.ext4"))
    }

    func removeRootfs() {
        try? FileManager.default.removeItem(
            at: appSupport.appendingPathComponent("containers").appendingPathComponent(containerId)
                .appendingPathComponent("rootfs.ext4"))
    }
}

private struct ChangesResponseEntry: Vapor.Content, Equatable {
    let Path: String
    let Kind: Int
}

private struct ChangesErrorBody: Vapor.Content { let reason: String }

private func withChangesApp(
    _ snapshot: ContainerSnapshot,
    appSupport: URL,
    libpod: Bool = false,
    run: (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        if libpod {
            try app.register(
                collection: LibpodContainerChangesRoute(
                    client: ChangesMock(snapshot: snapshot), appSupportURL: appSupport))
        } else {
            try app.register(
                collection: ContainerChangesRoute(
                    client: ChangesMock(snapshot: snapshot), appSupportURL: appSupport))
        }
        try await run(app)
    }
}

@Suite("ContainerChangesRoute", .serialized)
struct ContainerChangesRouteTests {

    @Test("docker diff returns moby's Path/Kind shape, sorted, with 0=modified 1=added 2=deleted")
    func returnsMobyShape() async throws {
        let id = "changes-ctr-\(UUID().uuidString.prefix(8))"
        let snapshot = makeSnapshot(id: id, imageDigest: "sha256:\(ChangesFixture.manifestDigest)")
        let fixture = ChangesFixture(containerId: id)
        defer { fixture.cleanUp() }
        try fixture.install(
            baselineFiles: ["/etc/hostname": "alpha", "/gone.txt": "old"],
            currentFiles: ["/etc/hostname": "beta", "/new.txt": "added"])

        try await withChangesApp(snapshot, appSupport: fixture.appSupport) { app in
            try await app.testing().test(.GET, "/v1.51/containers/\(id)/changes") { res async throws in
                #expect(res.status == .ok)
                let entries = try res.content.decode([ChangesResponseEntry].self)
                #expect(
                    entries == [
                        ChangesResponseEntry(Path: "/etc/hostname", Kind: 0),
                        ChangesResponseEntry(Path: "/gone.txt", Kind: 2),
                        ChangesResponseEntry(Path: "/new.txt", Kind: 1),
                    ])
            }
        }
    }

    @Test("an unchanged container answers an empty array, not null")
    func unchangedContainer() async throws {
        let id = "changes-clean-\(UUID().uuidString.prefix(8))"
        let snapshot = makeSnapshot(id: id, imageDigest: "sha256:\(ChangesFixture.manifestDigest)")
        let fixture = ChangesFixture(containerId: id)
        defer { fixture.cleanUp() }
        try fixture.install(
            baselineFiles: ["/etc/hostname": "alpha"],
            currentFiles: ["/etc/hostname": "alpha"])

        try await withChangesApp(snapshot, appSupport: fixture.appSupport) { app in
            try await app.testing().test(.GET, "/v1.51/containers/\(id)/changes") { res async throws in
                #expect(res.status == .ok)
                #expect(res.body.string == "[]")
            }
        }
    }

    @Test("the libpod twin serves the same shape")
    func libpodTwin() async throws {
        let id = "changes-libpod-\(UUID().uuidString.prefix(8))"
        let snapshot = makeSnapshot(id: id, imageDigest: "sha256:\(ChangesFixture.manifestDigest)")
        let fixture = ChangesFixture(containerId: id)
        defer { fixture.cleanUp() }
        try fixture.install(
            baselineFiles: ["/keep.txt": "keep"],
            currentFiles: ["/keep.txt": "changed"])

        try await withChangesApp(snapshot, appSupport: fixture.appSupport, libpod: true) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/\(id)/changes") { res async throws in
                #expect(res.status == .ok)
                let entries = try res.content.decode([ChangesResponseEntry].self)
                #expect(entries == [ChangesResponseEntry(Path: "/keep.txt", Kind: 0)])
            }
        }
    }

    @Test("an unknown container answers 404")
    func unknownContainer() async throws {
        let id = "changes-known-\(UUID().uuidString.prefix(8))"
        let snapshot = makeSnapshot(id: id, imageDigest: "sha256:\(ChangesFixture.manifestDigest)")
        let fixture = ChangesFixture(containerId: id)
        defer { fixture.cleanUp() }
        try fixture.install(baselineFiles: ["/a": "a"], currentFiles: ["/a": "a"])

        try await withChangesApp(snapshot, appSupport: fixture.appSupport) { app in
            try await app.testing().test(.GET, "/v1.51/containers/changes-nope/changes") { res async throws in
                #expect(res.status == .notFound)
                let body = try res.content.decode(ChangesErrorBody.self)
                #expect(body.reason.contains("No such container"))
            }
        }
    }

    @Test("a container without a rootfs on disk answers 404")
    func missingRootfs() async throws {
        let id = "changes-norootfs-\(UUID().uuidString.prefix(8))"
        let snapshot = makeSnapshot(id: id, imageDigest: "sha256:\(ChangesFixture.manifestDigest)")
        let fixture = ChangesFixture(containerId: id)
        defer { fixture.cleanUp() }
        try fixture.install(baselineFiles: ["/a": "a"], currentFiles: ["/a": "a"])
        fixture.removeRootfs()

        try await withChangesApp(snapshot, appSupport: fixture.appSupport) { app in
            try await app.testing().test(.GET, "/v1.51/containers/\(id)/changes") { res async throws in
                #expect(res.status == .notFound)
                let body = try res.content.decode(ChangesErrorBody.self)
                #expect(body.reason.contains("No rootfs"))
            }
        }
    }

    @Test("a container whose image snapshot is missing answers 500 with a diagnostic")
    func missingBaseline() async throws {
        let id = "changes-nobaseline-\(UUID().uuidString.prefix(8))"
        let snapshot = makeSnapshot(id: id, imageDigest: "sha256:unreachable")
        let fixture = ChangesFixture(containerId: id)
        defer { fixture.cleanUp() }
        try fixture.install(baselineFiles: ["/a": "a"], currentFiles: ["/a": "a"])

        try await withChangesApp(snapshot, appSupport: fixture.appSupport) { app in
            try await app.testing().test(.GET, "/v1.51/containers/\(id)/changes") { res async throws in
                #expect(res.status == .internalServerError)
                let body = try res.content.decode(ChangesErrorBody.self)
                #expect(body.reason.contains("No image snapshot baseline"))
            }
        }
    }
}
