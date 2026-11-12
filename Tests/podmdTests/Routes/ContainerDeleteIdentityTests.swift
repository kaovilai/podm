import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Review round 6 (PR #51): the delete route captured its finalization
/// identity EAGERLY (best-effort snapshot, then cache). When that lookup
/// failed transiently and no cache entry existed, the identity degenerated
/// to the bare request reference — a REUSABLE native name — even when the
/// authoritative lookup inside the request succeeded. The once-only
/// finalizer was then keyed by the name (suppressing a later same-name
/// instance's cleanup that hit the same fallback), the native-keyed
/// teardown (log journal, restart counter) was skipped, and the destroy
/// event carried the wrong Actor.ID. The finalization identity must be
/// rebuilt from the successful authoritative lookup.
@Suite("ContainerDeleteRoute — finalization identity")
struct ContainerDeleteIdentityTests {
    /// Routes the SHARED journal (the one these routes use) at a test-owned
    /// directory before any route test runs — this suite drives lifecycle
    /// routes that tear down journal state. See `SharedJournalTestIsolation`.
    init() async {
        await SharedJournalTestIsolation.shared.install()
    }

    @Test(
        "a transient eager-lookup failure must not degenerate the finalization identity",
        .timeLimit(.minutes(1)))
    func transientEagerLookupFailureKeepsInstanceIdentity() async throws {
        let nativeId = "identity-ctr-4d2"
        let snapshot = Self.snapshot(id: nativeId, createdAt: 4100)
        let hexId = DockerContainerID.hexId(for: snapshot)
        #expect(hexId != nativeId, "the request reference and the hex id must differ for this test")

        // Restart-policy attempts keyed by the native id — reset only when
        // the finalization carries the real native id.
        _ = await ContainerRestartState.shared.nextAttempt(id: nativeId)
        _ = await ContainerRestartState.shared.nextAttempt(id: nativeId)
        #expect(await ContainerRestartState.shared.count(id: nativeId) == 2)

        let lookups = IdentityLookupCounter()
        let mock = TransientThenFoundMock(
            snapshot: snapshot, lookups: lookups, deletes: IdentityLookupCounter())
        let broadcaster = EventBroadcaster()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerDeleteRoute(client: mock))
            // DELETE by the native id — the request reference the degenerate
            // identity used to fall back to.
            try await app.testing().test(.DELETE, "/v1.51/containers/\(nativeId)") { res async in
                #expect(res.status == .noContent)
            }
        }

        #expect(
            lookups.countSync() == 2,
            "exactly the eager best-effort lookup and the authoritative lookup")
        let destroys = await broadcaster.snapshot(since: 1, until: nil) {
            $0.status == "destroy" && $0.id == hexId
        }
        #expect(
            destroys.count == 1,
            "the destroy event must carry the canonical hex id, not the request reference")
        let destroysUnderRequestRef = await broadcaster.snapshot(since: 1, until: nil) {
            $0.status == "destroy" && $0.id == nativeId
        }
        #expect(destroysUnderRequestRef.isEmpty, "no destroy event under the reusable request reference")
        #expect(
            await ContainerRestartState.shared.count(id: nativeId) == 0,
            "the native-keyed restart-state teardown must run — it needs the real native id")
    }

    @Test(
        "the refreshed identity keys the once-only gate — a later 404 fallback adds no second destroy",
        .timeLimit(.minutes(1)))
    func refreshedIdentityDedupsLaterFallback() async throws {
        let nativeId = "identity-dedup-ctr-8e1"
        let snapshot = Self.snapshot(id: nativeId, createdAt: 4200)
        let hexId = DockerContainerID.hexId(for: snapshot)

        let lookups = IdentityLookupCounter()
        let deletes = IdentityLookupCounter()
        let mock = TransientThenFoundMock(snapshot: snapshot, lookups: lookups, deletes: deletes)
        let broadcaster = EventBroadcaster()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerDeleteRoute(client: mock))
            try await app.testing().test(.DELETE, "/v1.51/containers/\(nativeId)") { res async in
                #expect(res.status == .noContent)
            }
            // A client retry: the lookups still find the (now-deleted)
            // snapshot, so the 404 fallback runs with the eager identity —
            // the same hex key the first request's refreshed finalizer used.
            try await app.testing().test(.DELETE, "/v1.51/containers/\(nativeId)") { res async in
                #expect(res.status == .notFound)
            }
        }

        let destroys = await broadcaster.snapshot(since: 1, until: nil) {
            $0.status == "destroy" && $0.id == hexId
        }
        #expect(destroys.count == 1, "finalization stays exactly-once across the 404 fallback")
    }

    // MARK: - Helpers

    private static func snapshot(id: String, createdAt: TimeInterval) -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:abc", size: 0
            )
        )
        var config = ContainerConfiguration(id: id, image: img, process: proc)
        // A stable creation timestamp gives the instance a stable hex id
        // (see DockerContainerID.hexId).
        config.labels[AppleContainerTimestampResolver.legacyCreationTimestampLabel] = String(createdAt)
        return ContainerSnapshot(configuration: config, status: .stopped, networks: [])
    }
}

// MARK: - Mocks

private struct TransientLookupError: Error {}

/// Counts `getContainer` calls from any task.
private final class IdentityLookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func nextSync() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func countSync() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// The eager best-effort lookup fails transiently; every later lookup —
/// including the authoritative one inside the delete's `do` block — finds
/// the container. The first delete succeeds; later deletes report the
/// container gone (a client retry hitting the 404 fallback).
private struct TransientThenFoundMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
    let lookups: IdentityLookupCounter
    let deletes: IdentityLookupCounter

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        [snapshot]
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        if lookups.nextSync() == 1 {
            throw TransientLookupError()
        }
        return snapshot
    }

    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws -> Bool { true }
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { true }
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {
        if deletes.nextSync() > 1 {
            throw ClientContainerError.notFound(id: id)
        }
    }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws
        -> (deletedContainers: [String], spaceReclaimed: Int64)
    {
        ([], 0)
    }
}
