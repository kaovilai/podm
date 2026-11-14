import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Regression: a `--rm` container can be reaped between the start route's
/// pre-start snapshot and `client.start` — the attach path boots the guest and
/// it can exit and be reaped while this `/start` is still in flight. The catch
/// used to convert the resulting `ClientContainerError.notFound` into a 500,
/// so a `docker run --rm` that had actually succeeded exited 125.
@Suite("ContainerStartRoute — container reaped during start")
struct ContainerStartRouteReapedRaceTests {

    /// Routes the SHARED journal at a test-owned directory before any route
    /// test runs — see `SharedJournalTestIsolation`.
    init() async {
        await SharedJournalTestIsolation.shared.install()
    }

    @Test("start on a container reaped mid-flight answers 204 when a tombstone exists")
    func reapedContainerWithTombstoneReturns204() async throws {
        let nativeId = "reaped-rm-with-tombstone"
        let snapshot = try makeContainerSnapshot(
            nativeId: nativeId, networks: [], labels: [:], status: .stopped)
        let hexId = DockerContainerID.hexId(for: snapshot)

        // Generous bounds: correctness must not depend on scheduler timing.
        let autoRemoved = AutoRemovedContainers(ttl: .seconds(600), defaultWait: .seconds(60))
        await autoRemoved.record(hexId: hexId, code: 7)

        try await withStartRouteApp(
            client: ReapedDuringStartClientMock(snapshot: snapshot),
            autoRemoved: autoRemoved
        ) { app in
            // The CLI hands back the id it received at create, and that is the
            // tombstone's key.
            try await app.testing().test(.POST, "/v1.51/containers/\(hexId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("the tombstoned 204 emits no post-start events")
    func tombstonedSuccessBypassesPostStartSetup() async throws {
        let nativeId = "reaped-rm-no-events"
        let snapshot = try makeContainerSnapshot(
            nativeId: nativeId, networks: [], labels: [:], status: .stopped)
        let hexId = DockerContainerID.hexId(for: snapshot)

        let autoRemoved = AutoRemovedContainers(ttl: .seconds(600), defaultWait: .seconds(60))
        await autoRemoved.record(hexId: hexId, code: 0)
        let broadcaster = EventBroadcaster()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(
                collection: ContainerStartRoute(
                    client: ReapedDuringStartClientMock(snapshot: snapshot), autoRemoved: autoRemoved))

            try await app.testing().test(.POST, "/v1.51/containers/\(hexId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        // The 204 means "this run already completed": the route must return
        // before post-start setup, so nothing — not even a start event — is
        // emitted for the reaped instance.
        let (replay, _) = await broadcaster.subscribe(since: 0, until: nil, matching: nil)
        #expect(!replay.contains { $0.Action == "start" }, "events: \(replay.map(\.Action))")
    }

    @Test("a /start by NAME finds the tombstone through its resolved snapshot")
    func nameRequestResolvesTombstoneKey() async throws {
        let nativeId = "reaped-rm-by-name"
        let snapshot = try makeContainerSnapshot(
            nativeId: nativeId, networks: [], labels: [:], status: .stopped)
        let hexId = DockerContainerID.hexId(for: snapshot)

        let autoRemoved = AutoRemovedContainers(ttl: .seconds(600), defaultWait: .seconds(60))
        await autoRemoved.record(hexId: hexId, code: 3)

        try await withStartRouteApp(
            client: ReapedDuringStartClientMock(snapshot: snapshot),
            autoRemoved: autoRemoved
        ) { app in
            // Tombstones hold only instance-unique hex ids; a name-keyed request
            // must still answer from the instance it resolved.
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("start on a container reaped mid-flight answers 404, never 500, without a tombstone")
    func reapedContainerWithoutTombstoneReturns404() async throws {
        let nativeId = "reaped-rm-without-tombstone"
        let snapshot = try makeContainerSnapshot(
            nativeId: nativeId, networks: [], labels: [:], status: .stopped)
        let hexId = DockerContainerID.hexId(for: snapshot)

        // Short wait: nothing is coming, and the answer must be the real 404.
        let autoRemoved = AutoRemovedContainers(ttl: .seconds(600), defaultWait: .milliseconds(100))

        try await withStartRouteApp(
            client: ReapedDuringStartClientMock(snapshot: snapshot),
            autoRemoved: autoRemoved
        ) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(hexId)/start") { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}

// MARK: - Helpers

private func withStartRouteApp(
    client: some ClientContainerProtocol,
    autoRemoved: AutoRemovedContainers,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        try app.register(
            collection: ContainerStartRoute(client: client, autoRemoved: autoRemoved))
        try await test(app)
    }
}

/// Preflight sees a stopped container, but `start` finds it already gone —
/// exactly the reap window.
private actor ReapedDuringStartClientMock: ClientContainerProtocol {
    private let snapshot: ContainerSnapshot

    init(snapshot: ContainerSnapshot) {
        self.snapshot = snapshot
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        [snapshot]
    }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws -> Bool {
        throw ClientContainerError.notFound(id: id)
    }
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { true }
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (
        deletedContainers: [String], spaceReclaimed: Int64
    ) { ([], 0) }
}
