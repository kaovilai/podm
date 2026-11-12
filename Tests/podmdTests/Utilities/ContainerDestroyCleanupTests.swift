import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import podmd

/// Review round 1 (PR #57): every removal path — the DELETE route
/// (synchronous success, 404 fallback, late wedge-recovery success) and
/// the prune route (post-prune loop, late delete) — runs the SAME full
/// instance-scoped destroy cleanup through `ContainerDestroyFinalizer`.
/// A FAILED replacement lookup must not read as "no replacement exists":
/// only a successful lookup returning nil proves the reusable native id
/// unowned, so a transient apiserver error preserves a live same-name
/// replacement's journal and restart state.
@Suite("ContainerDestroyCleanup")
struct ContainerDestroyCleanupTests {

    /// Routes the SHARED journal (the one the follower teardown uses) at a
    /// test-owned directory before any test runs. See
    /// `SharedJournalTestIsolation`.
    init() async {
        await SharedJournalTestIsolation.shared.install()
    }

    @Test(
        "a failed replacement lookup preserves the native-keyed state, not the hex-keyed cleanup",
        .timeLimit(.minutes(1))
    )
    func failedLookupPreservesNativeState() async throws {
        let nativeId = "cleanup-fail-ctr-3af"
        let snapshot = Self.snapshot(id: nativeId, createdAt: 7100)
        let hexId = DockerContainerID.hexId(for: snapshot)
        // Native-keyed state a live same-name replacement may own by now.
        await ContainerLogJournal.shared.beginBoot(nativeId: nativeId, epoch: 1)
        await ContainerLogJournal.shared.append(
            nativeId: nativeId, epoch: 1,
            [ContainerLogJournal.Entry(unixNano: 1, streamType: 1, bytes: Data("live\n".utf8))])
        _ = await ContainerRestartState.shared.nextAttempt(id: nativeId)
        // Hex-keyed state owned by the deleted instance itself.
        await ContainerInfoCache.shared.set(
            hexId: hexId, nativeId: nativeId, image: "alpine:latest", labels: [:])
        await ContainerNameOverrideStore.shared.set(hexId: hexId, name: "cleanup-renamed")

        let broadcaster = EventBroadcaster()
        await ContainerDestroyCleanup.finalize(
            client: LookupFailingMock(),
            broadcaster: broadcaster,
            hexId: hexId,
            nativeId: nativeId,
            image: "alpine:latest",
            name: nativeId,
            labels: [:],
            checkForReplacement: true
        )

        // The lookup FAILED — that is not "no replacement exists": the
        // journal and restart counter (native-keyed) must survive.
        #expect(
            await ContainerLogJournal.shared.entries(nativeId: nativeId).isEmpty == false,
            "a failed lookup must not tear down native-keyed state a replacement may own")
        #expect(
            await ContainerRestartState.shared.count(id: nativeId) > 0,
            "a failed lookup must not reset the native-keyed restart counter")
        // The instance-scoped (hex-keyed) cleanup ran regardless.
        #expect(await ContainerInfoCache.shared.get(id: hexId) == nil, "the hex cache entry dies with the instance")
        #expect(await ContainerNameOverrideStore.shared.get(hexId: hexId) == nil, "the rename override dies with the instance")
        let destroys = await broadcaster.snapshot(since: 1, until: nil) { $0.status == "destroy" }
        #expect(destroys.count == 1, "exactly one destroy event")
        #expect(destroys.first?.id == hexId, "the destroy event carries the hex id, not the reusable native name")
    }

    @Test(
        "a successful lookup confirming absence tears down the native-keyed state",
        .timeLimit(.minutes(1))
    )
    func confirmedAbsenceTearsDownNativeState() async throws {
        let nativeId = "cleanup-gone-ctr-5c1"
        let snapshot = Self.snapshot(id: nativeId, createdAt: 7200)
        let hexId = DockerContainerID.hexId(for: snapshot)
        await ContainerLogJournal.shared.beginBoot(nativeId: nativeId, epoch: 1)
        await ContainerLogJournal.shared.append(
            nativeId: nativeId, epoch: 1,
            [ContainerLogJournal.Entry(unixNano: 1, streamType: 1, bytes: Data("gone\n".utf8))])
        _ = await ContainerRestartState.shared.nextAttempt(id: nativeId)
        await ContainerInfoCache.shared.set(
            hexId: hexId, nativeId: nativeId, image: "alpine:latest", labels: [:])
        await RestartPolicyOverrideStore.shared.set(
            id: hexId, policy: RestartPolicy(Name: "no", MaximumRetryCount: nil))

        let broadcaster = EventBroadcaster()
        await ContainerDestroyCleanup.finalize(
            client: AbsentContainerMock(),
            broadcaster: broadcaster,
            hexId: hexId,
            nativeId: nativeId,
            image: "alpine:latest",
            name: nativeId,
            labels: [:],
            checkForReplacement: true
        )

        #expect(await ContainerLogJournal.shared.entries(nativeId: nativeId).isEmpty, "confirmed absence tears down the journal")
        #expect(await ContainerRestartState.shared.count(id: nativeId) == 0, "confirmed absence resets the restart counter")
        #expect(await ContainerInfoCache.shared.get(id: hexId) == nil)
        #expect(await RestartPolicyOverrideStore.shared.get(id: hexId) == nil, "the restart-policy override dies with the instance")
        #expect(
            await broadcaster.snapshot(since: 1, until: nil) { $0.status == "destroy" }.count == 1)
    }

    @Test(
        "a live same-name replacement keeps its native-keyed state; the original's hex cleanup still runs",
        .timeLimit(.minutes(1))
    )
    func liveReplacementKeepsNativeState() async throws {
        let nativeId = "cleanup-repl-ctr-9d2"
        let original = Self.snapshot(id: nativeId, createdAt: 7300)
        let replacement = Self.snapshot(id: nativeId, createdAt: 7400)
        let originalHex = DockerContainerID.hexId(for: original)
        let replacementHex = DockerContainerID.hexId(for: replacement)
        #expect(originalHex != replacementHex)
        await ContainerLogJournal.shared.beginBoot(nativeId: nativeId, epoch: 1)
        await ContainerLogJournal.shared.append(
            nativeId: nativeId, epoch: 1,
            [ContainerLogJournal.Entry(unixNano: 1, streamType: 1, bytes: Data("replacement\n".utf8))])
        _ = await ContainerRestartState.shared.nextAttempt(id: nativeId)
        // The original's entries linger; the replacement now owns the native key.
        await ContainerInfoCache.shared.set(
            hexId: originalHex, nativeId: nativeId, image: "alpine:latest", labels: [:])
        await ContainerInfoCache.shared.set(
            hexId: replacementHex, nativeId: nativeId, image: "nginx:latest", labels: [:])

        let broadcaster = EventBroadcaster()
        await ContainerDestroyCleanup.finalize(
            client: SnapshotClientMock(snapshot: replacement),
            broadcaster: broadcaster,
            hexId: originalHex,
            nativeId: nativeId,
            image: "alpine:latest",
            name: nativeId,
            labels: [:],
            checkForReplacement: true
        )

        #expect(
            await ContainerLogJournal.shared.entries(nativeId: nativeId).isEmpty == false,
            "the replacement's journal survives the original's cleanup")
        #expect(
            await ContainerRestartState.shared.count(id: nativeId) > 0,
            "the replacement's restart counter survives the original's cleanup")
        #expect(
            await ContainerInfoCache.shared.get(id: nativeId)?.hexId == replacementHex,
            "the replacement keeps the native cache key")
        #expect(await ContainerInfoCache.shared.get(id: originalHex) == nil, "the original's hex key is dropped")
        let destroys = await broadcaster.snapshot(since: 1, until: nil) { $0.status == "destroy" }
        #expect(destroys.count == 1)
        #expect(destroys.first?.id == originalHex, "the destroy event identifies the ORIGINAL instance")
    }

    @Test(
        "prune and DELETE share one completion: a hex key finalized by one path is not re-run by the other",
        .timeLimit(.minutes(1))
    )
    func pruneAndDeleteShareCompletion() async throws {
        let nativeId = "cleanup-shared-ctr-1b7"
        let snapshot = Self.snapshot(id: nativeId, createdAt: 7500)
        let hexId = DockerContainerID.hexId(for: snapshot)
        await ContainerInfoCache.shared.set(
            hexId: hexId, nativeId: nativeId, image: "alpine:latest", labels: [:])

        let broadcaster = EventBroadcaster()
        // The prune loop's cleanup (checkForReplacement: true — its deletes
        // answered earlier in the same request)…
        await ContainerDestroyCleanup.finalize(
            client: AbsentContainerMock(),
            broadcaster: broadcaster,
            hexId: hexId,
            nativeId: nativeId,
            image: "alpine:latest",
            name: nativeId,
            labels: [:],
            checkForReplacement: true
        )
        // …then a client's DELETE retry hitting the 404 fallback for the
        // same lingering id — the full cleanup must not run twice.
        await ContainerDestroyCleanup.finalize(
            client: AbsentContainerMock(),
            broadcaster: broadcaster,
            hexId: hexId,
            nativeId: nativeId,
            image: "alpine:latest",
            name: nativeId,
            labels: [:],
            checkForReplacement: true
        )

        let destroys = await broadcaster.snapshot(since: 1, until: nil) { $0.status == "destroy" }
        #expect(destroys.count == 1, "exactly one destroy event across the prune and DELETE paths")
    }

    // MARK: mocks

    /// A transient apiserver failure (NOT a confirmed absence — the real
    /// `getContainer` turns a genuine not-found into nil, and only lets
    /// transient failures throw).
    private struct TransientLookupFailure: Error {}

    /// `getContainer` fails the way a transient apiserver error does —
    /// which must NOT be read as "no replacement exists".
    private struct LookupFailingMock: ClientContainerProtocol {
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
        func getContainer(id: String) async throws -> ContainerSnapshot? {
            throw TransientLookupFailure()
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
    }

    /// `getContainer` confirms the native id is unowned.
    private struct AbsentContainerMock: ClientContainerProtocol {
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
        func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
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
    }

    /// `getContainer` always resolves the native id to `snapshot` — a live
    /// same-name replacement.
    private struct SnapshotClientMock: ClientContainerProtocol {
        let snapshot: ContainerSnapshot
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
        func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
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
    }

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
        config.labels[AppleContainerTimestampResolver.legacyCreationTimestampLabel] = String(createdAt)
        return ContainerSnapshot(configuration: config, status: .stopped, networks: [])
    }
}
