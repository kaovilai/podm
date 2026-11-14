import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Regression: `/wait` used to read `ContainerExitCodeStore` under the raw
/// request reference. Exit codes are written under the container's native id
/// (and its canonical hex id), so a `/wait` by a truncated id saw nothing —
/// and, once the attach routes started recording under the canonical hex id,
/// a truncated key written by an earlier run could answer the poll instead of
/// the current run's code.
@Suite("ContainerWaitRoute — resolves the store key from the container")
struct ContainerWaitRouteResolutionTests {

    @Test("waits by a truncated id read the code recorded under the native id")
    func truncatedReferenceResolvesToNativeId() async throws {
        let nativeId = "exit-resolve-\(UUID().uuidString.prefix(8))"
        let snapshot = makeWaitSnapshot(id: nativeId)
        let hexId = DockerContainerID.hexId(for: snapshot)
        let requestRef = String(hexId.prefix(12))

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 42)
        defer { Task { await ContainerExitCodeStore.shared.remove(id: nativeId) } }

        try await withWaitRouteApp(client: PrefixResolvingWaitClient(container: snapshot)) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(requestRef)/wait") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("\"StatusCode\":42"), "body: \(res.body.string)")
            }
        }
    }

    @Test("a stale record under the request's spelling cannot shadow the native-id code")
    func staleRequestKeyedRecordIsIgnored() async throws {
        let nativeId = "exit-stale-\(UUID().uuidString.prefix(8))"
        let snapshot = makeWaitSnapshot(id: nativeId)
        let hexId = DockerContainerID.hexId(for: snapshot)
        let requestRef = String(hexId.prefix(12))

        // A previous run recorded under the raw request spelling (the old
        // behavior); the current run's code lives under the native id.
        await ContainerExitCodeStore.shared.set(id: requestRef, code: 7)
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 42)
        defer {
            Task {
                await ContainerExitCodeStore.shared.remove(id: requestRef)
                await ContainerExitCodeStore.shared.remove(id: nativeId)
            }
        }

        try await withWaitRouteApp(client: PrefixResolvingWaitClient(container: snapshot)) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(requestRef)/wait") { res async in
                #expect(res.body.string.contains("\"StatusCode\":42"), "body: \(res.body.string)")
            }
        }
    }
}

// MARK: - Helpers

private func withWaitRouteApp(
    client: some ClientContainerProtocol,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        try app.register(collection: ContainerWaitRoute(client: client))
        try await test(app)
    }
}

private func makeWaitSnapshot(id: String) -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
    let img = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
    let config = ContainerConfiguration(id: id, image: img, process: proc)
    return ContainerSnapshot(configuration: config, status: .running, networks: [])
}

/// Resolves a full id or a ≥6-char hex prefix, like the real service; its
/// native wait never completes (throws), so the store poller decides — exactly
/// the pipe-bootstrapped `docker run` case.
private struct PrefixResolvingWaitClient: ClientContainerProtocol {
    let container: ContainerSnapshot

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [container] }
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        if id == container.id { return container }
        // The Docker hex id is how `docker wait` addresses the container; the
        // service resolves it (and prefixes of it) back to the snapshot.
        let hexId = DockerContainerID.hexId(for: container)
        if id.count >= 6, hexId.hasPrefix(id.lowercased()) { return container }
        return nil
    }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws -> Bool { true }
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { true }
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        throw ClientContainerError.unsupportedCondition(condition)
    }
    func prune(filters: [String: [String]]) async throws -> (
        deletedContainers: [String], spaceReclaimed: Int64
    ) { ([], 0) }
}
