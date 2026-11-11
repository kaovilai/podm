import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Route-level regression tests for the timestamped log journal's lifecycle:
/// `/start` must reset the journal only when the call actually booted the
/// container (a quick stop/start resets; a redundant start on a running
/// container preserves it), and `docker container prune` must tear down each
/// pruned container's journal — the prune path deletes through the native
/// client and bypasses the delete/auto-remove cleanup callers.
///
/// One SERIALIZED suite because these tests drive the SHARED journal the
/// production routes use; parallel tests reconfiguring it would race.
@Suite("Container log journal lifecycle (routes)", .serialized)
struct ContainerLogJournalLifecycleRouteTests {

    /// Polls `condition` until true or the timeout passes.
    private func waitFor(_ condition: () async -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-journal-route-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Points the SHARED journal (the one the routes use) at a fresh temp
    /// directory and seeds one entry for `nativeId`.
    private func seedSharedJournal(dir: URL, nativeId: String, line: String) async {
        await ContainerLogJournal.shared.configure(storageDirectory: dir)
        await ContainerLogJournal.shared.beginBoot(nativeId: nativeId, epoch: 1)
        await ContainerLogJournal.shared.append(
            nativeId: nativeId, epoch: 1,
            [ContainerLogJournal.Entry(unixNano: 111, streamType: 1, bytes: Data(line.utf8))])
    }

    private func makeSnapshot(nativeId: String, status: RuntimeStatus) throws -> ContainerSnapshot {
        try makeContainerSnapshot(
            nativeId: nativeId, networks: [("myapp_default", "192.168.65.90")], labels: [:], status: status)
    }

    // MARK: - /start fresh-boot semantics

    @Test("a /start that boots a stopped container resets its log journal")
    func startResetsJournalOnRealBoot() async throws {
        let nativeId = "journal-start-stopped-ctr"
        let dir = tempDirectory()
        await seedSharedJournal(dir: dir, nativeId: nativeId, line: "previous boot\n")

        let mock = StaticSnapshotClientMock(snapshot: try makeSnapshot(nativeId: nativeId, status: .stopped))
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        // The follower arms, resets the journal for the new boot, then exits
        // (the mock container has no Apple log stream to open).
        let finished = await waitFor {
            let armed = await ContainerLogFollowerRegistry.shared.isArmed(nativeId: nativeId)
            return !armed
        }
        #expect(finished, "the follower should wind down after failing to open the log stream")

        let after = await ContainerLogJournal.shared.entries(nativeId: nativeId)
        #expect(after.isEmpty, "a stopped→running /start must reset the previous boot's journal")

        // The reset hit disk — a fresh instance over the same dir sees nothing.
        let reloaded = ContainerLogJournal()
        await reloaded.configure(storageDirectory: dir)
        #expect(await reloaded.entries(nativeId: nativeId).isEmpty)

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)
        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("a redundant /start on a running container preserves its log journal")
    func redundantStartPreservesJournal() async throws {
        let nativeId = "journal-start-running-ctr"
        let dir = tempDirectory()
        await seedSharedJournal(dir: dir, nativeId: nativeId, line: "current boot\n")

        let mock = StaticSnapshotClientMock(snapshot: try makeSnapshot(nativeId: nativeId, status: .running))
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        // The armed follower resumes the current boot (no reset) and exits on
        // the unavailable log stream.
        let finished = await waitFor {
            let armed = await ContainerLogFollowerRegistry.shared.isArmed(nativeId: nativeId)
            return !armed
        }
        #expect(finished)

        let after = await ContainerLogJournal.shared.entries(nativeId: nativeId)
        #expect(
            after.map(\.bytes) == [Data("current boot\n".utf8)],
            "a redundant /start must not delete the current boot's persisted timestamps")

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)
        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("a /start that lost a concurrent boot race preserves its log journal")
    func startThatLostBootRacePreservesJournal() async throws {
        let nativeId = "journal-start-raced-ctr"
        let dir = tempDirectory()
        await seedSharedJournal(dir: dir, nativeId: nativeId, line: "current boot\n")

        // The snapshot is stopped when observed, but start() reports that
        // THIS call did not boot it — a concurrent /start (or the attach
        // route's bootstrap) won the race and ours was a suppressed no-op.
        // A successful call alone must not be read as "this request booted
        // the container": that would cancel the real boot's follower and
        // erase/restamp its journal.
        let mock = SuppressedStartMock(snapshot: try makeSnapshot(nativeId: nativeId, status: .stopped))
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        // The follower resumes the winning boot's journal (no reset) and
        // winds down on the unavailable log stream.
        let finished = await waitFor {
            let armed = await ContainerLogFollowerRegistry.shared.isArmed(nativeId: nativeId)
            return !armed
        }
        #expect(finished)

        let after = await ContainerLogJournal.shared.entries(nativeId: nativeId)
        #expect(
            after.map(\.bytes) == [Data("current boot\n".utf8)],
            "a suppressed no-op start must not reset the journal of the boot that actually happened")

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)
        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    // MARK: - /restart fresh-boot semantics

    @Test("a /restart that booted the container resets its log journal")
    func restartResetsJournalOnRealBoot() async throws {
        let nativeId = "journal-restart-boot-ctr"
        let dir = tempDirectory()
        await seedSharedJournal(dir: dir, nativeId: nativeId, line: "previous boot\n")

        // StaticSnapshotClientMock.restart reports a real boot (true), like
        // ClientContainerService.restart propagating startInternal's result.
        let mock = StaticSnapshotClientMock(snapshot: try makeSnapshot(nativeId: nativeId, status: .stopped))
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerRestartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/restart") { res async in
                #expect(res.status == .noContent)
            }
        }

        // The follower arms with a fresh boot, resets the journal, then
        // winds down on the unavailable log stream.
        let finished = await waitFor {
            let armed = await ContainerLogFollowerRegistry.shared.isArmed(nativeId: nativeId)
            return !armed
        }
        #expect(finished)

        let after = await ContainerLogJournal.shared.entries(nativeId: nativeId)
        #expect(after.isEmpty, "a restart that performed the boot must reset the previous boot's journal")

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)
        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("a /restart that lost a concurrent boot race preserves its log journal")
    func restartThatLostBootRacePreservesJournal() async throws {
        let nativeId = "journal-restart-raced-ctr"
        let dir = tempDirectory()
        await seedSharedJournal(dir: dir, nativeId: nativeId, line: "current boot\n")

        // The restart succeeds, but its internal start lost the boot race to
        // a concurrent /start (or the attach route's bootstrap): restart
        // reports a suppressed no-op. Reading the call's success alone as
        // "this request booted the container" would cancel the winning
        // boot's follower and erase/restamp its journal.
        let mock = SuppressedRestartMock(snapshot: try makeSnapshot(nativeId: nativeId, status: .stopped))
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerRestartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/restart") { res async in
                #expect(res.status == .noContent)
            }
        }

        // The follower resumes the winning boot's journal (no reset) and
        // winds down on the unavailable log stream.
        let finished = await waitFor {
            let armed = await ContainerLogFollowerRegistry.shared.isArmed(nativeId: nativeId)
            return !armed
        }
        #expect(finished)

        let after = await ContainerLogJournal.shared.entries(nativeId: nativeId)
        #expect(
            after.map(\.bytes) == [Data("current boot\n".utf8)],
            "a suppressed no-op restart must not reset the journal of the boot that actually happened")

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)
        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    /// Mock whose `start` reports a suppressed no-op (this call did not
    /// perform the boot) while the container's observed status was stopped.
    private actor SuppressedStartMock: ClientContainerProtocol {
        private let snapshot: ContainerSnapshot
        init(snapshot: ContainerSnapshot) {
            self.snapshot = snapshot
        }
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
        func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
        nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws -> Bool {
            await ContainerExitCodeStore.shared.remove(id: id)
            return false
        }
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { true }
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
            RESTContainerWait(statusCode: 0)
        }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
            ([], 0)
        }
    }

    /// Mock whose `restart` reports a suppressed no-op (the internal start
    /// lost the boot race to a concurrent caller) while the call itself
    /// succeeds — the route must key fresh-boot state off this result, not
    /// off the call succeeding.
    private actor SuppressedRestartMock: ClientContainerProtocol {
        private let snapshot: ContainerSnapshot
        init(snapshot: ContainerSnapshot) {
            self.snapshot = snapshot
        }
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
        func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
        nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws -> Bool { true }
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { false }
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
            RESTContainerWait(statusCode: 0)
        }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
            ([], 0)
        }
    }

    // MARK: - prune teardown

    /// Mock whose prune reports one deleted container (the native id).
    private actor PruneReportingMock: ClientContainerProtocol {
        private let snapshot: ContainerSnapshot
        init(snapshot: ContainerSnapshot) { self.snapshot = snapshot }
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
        func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
        nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws -> Bool { true }
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { true }
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
            RESTContainerWait(statusCode: 0)
        }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
            ([snapshot.id], 0)
        }
    }

    @Test("docker container prune tears down the pruned container's log journal")
    func pruneTearsDownJournal() async throws {
        let nativeId = "journal-prune-ctr"
        let dir = tempDirectory()
        await seedSharedJournal(dir: dir, nativeId: nativeId, line: "prune me\n")

        let mock = PruneReportingMock(snapshot: try makeSnapshot(nativeId: nativeId, status: .stopped))
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerPruneRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/prune") { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(RESTContainerPruneResponse.self)
                #expect(body.ContainersDeleted == [nativeId])
            }
        }

        let after = await ContainerLogJournal.shared.entries(nativeId: nativeId)
        #expect(after.isEmpty, "prune must tear down the pruned container's journal")

        // ...and the teardown hit disk, not just the in-memory state.
        let reloaded = ContainerLogJournal()
        await reloaded.configure(storageDirectory: dir)
        #expect(await reloaded.entries(nativeId: nativeId).isEmpty)
    }
}
