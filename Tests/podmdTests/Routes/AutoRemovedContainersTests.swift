import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `docker run --rm` is a client race: the CLI creates, attaches, then sends
/// `/start` and `/wait` — while the attached container can already have exited
/// and been reaped by Apple Container's own auto-remove. Both calls used to
/// answer "No such container", so the CLI exited **125 for a run that actually
/// succeeded**. The `--rm` tombstone lets the late calls answer with the exit
/// code podm recorded before the reap.
@Suite("AutoRemovedContainers — late /start and /wait after a --rm reap")
struct AutoRemovedContainersTests {

    private static let hex = "a8aba6c3586df88fc1d344b741ddb464b13634efdb3c2114474066d469638160"

    @Test("records the exit code under the instance-unique hex id")
    func recordsHexId() async {
        let tombs = AutoRemovedContainers()
        await tombs.record(hexId: Self.hex, code: 42)
        #expect(await tombs.exitCode(for: Self.hex) == 42)
        #expect(await tombs.exitCode(for: "unknown") == nil)
    }

    @Test("a native NAME never resolves a tombstone — names are reused by later containers")
    func nameDoesNotMatch() async {
        let tombs = AutoRemovedContainers()
        await tombs.record(hexId: Self.hex, code: 42)
        // Apple's native ids double as container names; a tombstone keyed by
        // one would answer for a newly created container reusing the name.
        #expect(await tombs.exitCode(for: "web-1") == nil)
    }

    @Test("a hex-id prefix resolves, like container id resolution everywhere else")
    func prefixResolves() async {
        let tombs = AutoRemovedContainers()
        await tombs.record(hexId: Self.hex, code: 9)
        #expect(await tombs.exitCode(for: String(Self.hex.prefix(12))) == 9)
        // Too short to be an id prefix.
        #expect(await tombs.exitCode(for: String(Self.hex.prefix(3))) == nil)
    }

    @Test("an ambiguous prefix resolves nothing")
    func ambiguousPrefix() async {
        let tombs = AutoRemovedContainers()
        await tombs.record(hexId: Self.hex, code: 9)
        // A second instance sharing the same 6-char prefix.
        await tombs.record(hexId: "a8aba6" + String(repeating: "f", count: 58), code: 11)
        #expect(await tombs.exitCode(for: String(Self.hex.prefix(6))) == nil)
    }

    @Test("a cancelled wait stops polling instead of spinning to the deadline")
    func cancelledWaitStops() async {
        let tombs = AutoRemovedContainers(ttl: .seconds(5), defaultWait: .seconds(30))
        let started = ContinuousClock.Instant.now
        let task = Task { await tombs.waitForExitCode(for: "never") }
        try? await Task.sleep(for: .milliseconds(120))
        task.cancel()
        let code = await task.value
        #expect(code == nil)
        #expect(ContinuousClock.Instant.now - started < .seconds(5))
    }

    @Test("a tombstone stops answering once its TTL lapses")
    func ttlExpiry() async {
        let tombs = AutoRemovedContainers(ttl: .milliseconds(80))
        await tombs.record(hexId: "gone", code: 0)
        #expect(await tombs.exitCode(for: "gone") == 0)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await tombs.exitCode(for: "gone") == nil)
    }

    @Test("waitForExitCode covers a tombstone written just after the call")
    func waitCoversLateWrite() async {
        let tombs = AutoRemovedContainers(ttl: .seconds(5), defaultWait: .seconds(2))
        // The exit observer records the code ~200ms after the process exits;
        // the CLI's /wait can land in that window.
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            await tombs.record(hexId: "late", code: 7)
        }
        let code = await tombs.waitForExitCode(for: "late")
        #expect(code == 7)
    }

    @Test("waitForExitCode gives up on a container that was never auto-removed")
    func waitGivesUp() async {
        let tombs = AutoRemovedContainers(ttl: .seconds(5), defaultWait: .milliseconds(120))
        let code = await tombs.waitForExitCode(for: "never-existed")
        #expect(code == nil)
    }

    @Test("the /wait route answers the recorded exit code instead of 404")
    func waitRouteAnswersTombstone() async throws {
        let tombs = AutoRemovedContainers(ttl: .seconds(5), defaultWait: .milliseconds(200))
        await tombs.record(hexId: "gone", code: 42)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerWaitRoute(client: NoSuchContainerClient(), autoRemoved: tombs))

            try await app.testing().test(.POST, "/v1.51/containers/gone/wait") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any]
                #expect(json?["StatusCode"] as? Int == 42)
            }
            // A container that was never auto-removed still 404s.
            try await app.testing().test(.POST, "/v1.51/containers/never/wait") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("the /start route treats a tombstoned --rm run as already completed")
    func startRouteAnswersTombstone() async throws {
        let tombs = AutoRemovedContainers(ttl: .seconds(5), defaultWait: .milliseconds(200))
        await tombs.record(hexId: "gone", code: 0)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: NoSuchContainerClient(), autoRemoved: tombs))

            try await app.testing().test(.POST, "/v1.51/containers/gone/start") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/containers/never/start") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("the libpod /wait route answers the recorded exit code as a bare integer")
    func libpodWaitRouteAnswersTombstone() async throws {
        let tombs = AutoRemovedContainers(ttl: .seconds(5), defaultWait: .milliseconds(200))
        await tombs.record(hexId: "gone", code: 3)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerWaitRoute(client: NoSuchContainerClient(), autoRemoved: tombs))

            try await app.testing().test(.POST, "/v1.51/libpod/containers/gone/wait") { res async in
                #expect(res.status == .ok)
                // podman's remote client decodes the body into int32.
                #expect(res.body.string == "3")
            }
        }
    }
}

/// Every container lookup misses — the state a `--rm` container is in after
/// Apple Container reaps it.
private struct NoSuchContainerClient: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws -> Bool {
        throw ClientContainerError.notFound(id: id)
    }
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { false }
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        throw ClientContainerError.notFound(id: id)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
