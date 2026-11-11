import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Review round 2 (PR #51): a delete that succeeds AFTER the wedge-recovery
/// deadline returned the wedged error to the client used to bypass
/// route/prune finalization entirely — rename reservations and log journals
/// leaked, the destroy event was missing, and a persisted rename made
/// creating that name 409 even though its container was gone. The late
/// cleanup must be exactly-once and instance-scoped: never touching a
/// same-name replacement (native ids are reusable names).
@Suite("ContainerDeleteRoute — late wedge-recovery cleanup")
struct ContainerDeleteLateCleanupTests {

    /// Routes the SHARED journal (the one these routes use) at a test-owned
    /// directory before any route test runs. See `SharedJournalTestIsolation`.
    init() async {
        await SharedJournalTestIsolation.shared.install()
    }

    @Test(
        "a delete succeeding after the wedged error still finalizes — exactly once",
        .timeLimit(.minutes(1))
    )
    func lateSuccessFinalizesOnce() async throws {
        let snapshot = Self.snapshot(id: "late-ctr-7f3a", createdAt: 1000)
        let hexId = DockerContainerID.hexId(for: snapshot)
        // A persisted rename: its override must die with the container even
        // on a LATE success, or creating that name 409s forever.
        await ContainerNameOverrideStore.shared.set(hexId: hexId, name: "late-ctr-renamed")
        await ContainerInfoCache.shared.set(
            hexId: hexId, nativeId: snapshot.id, image: "alpine:latest", labels: [:])
        // Restart-policy attempts keyed by the native id — reset by cleanup.
        _ = await ContainerRestartState.shared.nextAttempt(id: snapshot.id)
        _ = await ContainerRestartState.shared.nextAttempt(id: snapshot.id)

        let state = LateHookState()
        let mock = WedgedDeleteMock(snapshot: snapshot, replacement: nil, state: state)
        let broadcaster = EventBroadcaster()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerDeleteRoute(client: mock))

            try await app.testing().test(.DELETE, "/v1.51/containers/\(snapshot.id)") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("did not answer within the recovery window"))
            }
        }

        // The 500 went out; nothing may have been cleaned up yet.
        #expect(
            await ContainerNameOverrideStore.shared.get(hexId: hexId) != nil,
            "the rename override must survive until the delete actually succeeds")
        let destroyBefore = await broadcaster.snapshot(since: 1, until: nil) { $0.status == "destroy" }
        #expect(destroyBefore.isEmpty)

        // The wedge clears and the abandoned delete finally succeeds.
        await state.fireLateSuccess()

        #expect(await ContainerNameOverrideStore.shared.get(hexId: hexId) == nil, "the override dies with the container")
        #expect(await ContainerInfoCache.shared.get(id: hexId) == nil, "the info cache entry dies with the container")
        #expect(await ContainerRestartState.shared.count(id: snapshot.id) == 0, "restart attempts are reset")
        let destroys = await broadcaster.snapshot(since: 1, until: nil) { $0.status == "destroy" && $0.id == hexId }
        #expect(destroys.count == 1, "exactly one destroy event for the original instance")

        // A client retry (or a duplicate late completion) reaching the same
        // cleanup must not double the destroy event.
        await state.fireLateSuccess()
        let destroysAfterRefire = await broadcaster.snapshot(since: 1, until: nil) {
            $0.status == "destroy" && $0.id == hexId
        }
        #expect(destroysAfterRefire.count == 1, "finalization is exactly-once")
    }

    @Test(
        "late cleanup never touches a same-name replacement",
        .timeLimit(.minutes(1))
    )
    func lateCleanupProtectsReplacement() async throws {
        // Native ids are reusable names: after the wedged delete was given
        // up on, a replacement was created under the SAME name.
        let nativeId = "late-repl-ctr-91c"
        let original = Self.snapshot(id: nativeId, createdAt: 2000)
        let replacement = Self.snapshot(id: nativeId, createdAt: 3000)
        let originalHex = DockerContainerID.hexId(for: original)
        let replacementHex = DockerContainerID.hexId(for: replacement)
        #expect(originalHex != replacementHex, "the two instances must have distinct hex ids")

        // The replacement's cache entries are live; the original's linger.
        await ContainerInfoCache.shared.set(
            hexId: replacementHex, nativeId: nativeId, image: "nginx:latest", labels: [:])
        // The replacement's restart attempts must survive the original's
        // late cleanup.
        _ = await ContainerRestartState.shared.nextAttempt(id: nativeId)

        let state = LateHookState()
        let mock = WedgedDeleteMock(snapshot: original, replacement: replacement, state: state)
        let broadcaster = EventBroadcaster()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerDeleteRoute(client: mock))

            try await app.testing().test(.DELETE, "/v1.51/containers/\(nativeId)") { res async in
                #expect(res.status == .internalServerError)
            }
        }

        // The replacement now owns the native id.
        await state.activateReplacement()
        await state.fireLateSuccess()

        #expect(
            await ContainerInfoCache.shared.get(id: nativeId)?.hexId == replacementHex,
            "the replacement keeps the native cache key")
        #expect(
            await ContainerInfoCache.shared.get(id: replacementHex)?.hexId == replacementHex,
            "the replacement keeps its hex cache key")
        #expect(await ContainerInfoCache.shared.get(id: originalHex) == nil, "the original's hex key is dropped")
        #expect(
            await ContainerRestartState.shared.count(id: nativeId) > 0,
            "the replacement's restart attempts are not reset by the original's cleanup")
        let destroys = await broadcaster.snapshot(since: 1, until: nil) { $0.status == "destroy" }
        #expect(destroys.count == 1, "the original still gets its (single) destroy event")
    }

    // MARK: prune — same late-completion contract

    @Test(
        "a prune delete succeeding late still tears down the journal and fires destroy, exactly once",
        .timeLimit(.minutes(1))
    )
    func pruneLateDeleteFinalizesOnce() async throws {
        let nativeId = "prune-late-ctr-4b2"
        let snapshot = Self.snapshot(id: nativeId, createdAt: 4000)
        let hexId = DockerContainerID.hexId(for: snapshot)
        // The journal the prune response (sent without this container)
        // never got to tear down.
        await ContainerLogJournal.shared.beginBoot(nativeId: nativeId, epoch: 1)
        await ContainerLogJournal.shared.append(
            nativeId: nativeId, epoch: 1,
            [ContainerLogJournal.Entry(unixNano: 1, streamType: 1, bytes: Data("x\n".utf8))])

        let state = LateHookState()
        let mock = LatePruneMock(snapshots: [snapshot], state: state)
        let broadcaster = EventBroadcaster()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerPruneRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/prune") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("\"ContainersDeleted\":[]"))
            }
        }

        // The prune response went out without the wedged container; its
        // journal is still there.
        #expect(await ContainerLogJournal.shared.entries(nativeId: nativeId).isEmpty == false)

        // The wedge clears: the abandoned prune delete succeeds late.
        await state.firePruneLateDelete(nativeId: nativeId, hexId: hexId)

        #expect(await ContainerLogJournal.shared.entries(nativeId: nativeId).isEmpty, "the journal dies with the container")
        let destroys = await broadcaster.snapshot(since: 1, until: nil) { $0.status == "destroy" && $0.id == nativeId }
        #expect(destroys.count == 1, "exactly one destroy event for the late-deleted container")

        // A duplicate late completion must not double the event.
        await state.firePruneLateDelete(nativeId: nativeId, hexId: hexId)
        let destroysAfterRefire = await broadcaster.snapshot(since: 1, until: nil) {
            $0.status == "destroy" && $0.id == nativeId
        }
        #expect(destroysAfterRefire.count == 1, "finalization is exactly-once")
    }

    @Test(
        "a late prune delete skips the journal teardown when a same-name replacement owns it",
        .timeLimit(.minutes(1))
    )
    func pruneLateDeleteProtectsReplacement() async throws {
        let nativeId = "prune-repl-ctr-8dd"
        let original = Self.snapshot(id: nativeId, createdAt: 5000)
        let replacement = Self.snapshot(id: nativeId, createdAt: 6000)
        let originalHex = DockerContainerID.hexId(for: original)
        // The replacement's journal (it re-registered the same native id).
        await ContainerLogJournal.shared.beginBoot(nativeId: nativeId, epoch: 1)
        await ContainerLogJournal.shared.append(
            nativeId: nativeId, epoch: 1,
            [ContainerLogJournal.Entry(unixNano: 1, streamType: 1, bytes: Data("y\n".utf8))])

        let state = LateHookState()
        let mock = LatePruneMock(snapshots: [original, replacement], state: state)
        let broadcaster = EventBroadcaster()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerPruneRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/prune") { res async in
                #expect(res.status == .ok)
            }
        }

        // The replacement now owns the native id.
        await state.activateReplacement()
        await state.firePruneLateDelete(nativeId: nativeId, hexId: originalHex)

        #expect(
            await ContainerLogJournal.shared.entries(nativeId: nativeId).isEmpty == false,
            "the replacement's journal must survive the original's late cleanup")
    }

    // MARK: helpers

    private static func snapshot(id: String, createdAt: TimeInterval) -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index+json",
                digest: "sha256:abc", size: 0
            )
        )
        var config = ContainerConfiguration(id: id, image: img, process: proc)
        // Distinct creation timestamps give same-name instances distinct
        // Docker hex ids (see DockerContainerID.hexId).
        config.labels[AppleContainerTimestampResolver.legacyCreationTimestampLabel] = String(createdAt)
        return ContainerSnapshot(configuration: config, status: .stopped, networks: [])
    }
}

// MARK: - Mocks

/// Captures the late-completion hooks the routes hand to the service, and
/// whether a same-name replacement currently owns the native id.
private actor LateHookState {
    private var lateSuccessHook: (@Sendable () async -> Void)?
    private var pruneLateDeleteHook: (@Sendable (String, String) async -> Void)?
    private var replacementActive = false
    private var deleted = false

    func storeLateSuccess(_ hook: (@Sendable () async -> Void)?) {
        lateSuccessHook = hook
    }

    func fireLateSuccess() async {
        // The delete succeeding means the original container is gone.
        deleted = true
        if let hook = lateSuccessHook { await hook() }
    }

    func storePruneLateDelete(_ hook: @escaping @Sendable (String, String) async -> Void) {
        pruneLateDeleteHook = hook
    }

    func firePruneLateDelete(nativeId: String, hexId: String) async {
        deleted = true
        if let hook = pruneLateDeleteHook { await hook(nativeId, hexId) }
    }

    func activateReplacement() {
        replacementActive = true
    }

    func isReplacementActive() -> Bool {
        replacementActive
    }

    func isDeleted() -> Bool {
        deleted
    }
}

/// A delete that throws the wedged error while capturing the late-success
/// hook, standing in for `ClientContainerService.delete` against an
/// apiserver wedged past its recovery windows (issue #45).
private struct WedgedDeleteMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
    let replacement: ContainerSnapshot?
    let state: LateHookState

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        [snapshot]
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        if await state.isReplacementActive() {
            return replacement ?? snapshot
        }
        if await state.isDeleted() {
            return nil  // the late delete removed the original
        }
        return snapshot
    }

    func enforceContainerRunning(container: ContainerSnapshot) throws {}

    @discardableResult
    func start(id: String, detachKeys: String?) async throws -> Bool { true }

    func stop(id: String, signal: String?, timeout: Int?) async throws {}

    @discardableResult
    func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { true }

    func kill(id: String, signal: String?) async throws {}

    func delete(id: String) async throws {}

    func delete(id: String, onLateSuccess: (@Sendable () async -> Void)?) async throws {
        await state.storeLateSuccess(onLateSuccess)
        throw ClientContainerError.runtimeJobWedged(
            nativeId: snapshot.id,
            label: "gui/\(getuid())/com.apple.container.container-runtime-linux.\(snapshot.id)")
    }

    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }

    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

/// A prune that reports nothing deleted while capturing the late-delete
/// hook, standing in for `ClientContainerService.prune` with one container
/// wedged past its recovery windows.
private struct LatePruneMock: ClientContainerProtocol {
    let snapshots: [ContainerSnapshot]
    let state: LateHookState

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        snapshots
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        if await state.isReplacementActive() {
            return snapshots.last
        }
        if await state.isDeleted() {
            return nil  // the late prune delete removed the original
        }
        return snapshots.first
    }

    func enforceContainerRunning(container: ContainerSnapshot) throws {}

    @discardableResult
    func start(id: String, detachKeys: String?) async throws -> Bool { true }

    func stop(id: String, signal: String?, timeout: Int?) async throws {}

    @discardableResult
    func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { true }

    func kill(id: String, signal: String?) async throws {}

    func delete(id: String) async throws {}

    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }

    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }

    func prune(
        filters: [String: [String]],
        onLateDelete: (@Sendable (_ nativeId: String, _ hexId: String) async -> Void)?
    ) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        if let onLateDelete {
            await state.storePruneLateDelete(onLateDelete)
        }
        return ([], 0)
    }
}
