import ContainerizationOCI
import Foundation
import Testing

@testable import podmd

/// Apple's image store keeps the whole OCI index under a reference and
/// resolves a variant on demand, so "which variant did this image get pulled
/// as" was unrecorded — `podman pull --platform linux/amd64 alpine` followed
/// by `podman run alpine` silently ran the arm64 sibling, and image inspect
/// reported arm64 for the image the user had just pulled as amd64.
@Suite("ImagePlatformStore — the pulled variant of an image")
struct ImagePlatformStoreTests {

    private func makeStore(directory: URL) async -> ImagePlatformStore {
        let store = ImagePlatformStore()
        await store.configure(storageDirectory: directory)
        return store
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-image-platforms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("records and returns the platform for a normalized reference")
    func recordAndLookup() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(reference: "docker.io/library/alpine:latest", platform: try Platform(from: "linux/amd64"))

        let found = await store.platform(forReference: "docker.io/library/alpine:latest")
        #expect(found?.os == "linux")
        #expect(found?.architecture == "amd64")
        #expect(await store.platform(forReference: "docker.io/library/other:latest") == nil)
    }

    @Test("a variant survives the round trip, including three-component platforms")
    func variantPreserved() async throws {
        let store = await makeStore(directory: try tempDir())
        // `Platform(from: "linux/amd64/v3")` rejects this textual form — the
        // store must persist components, not a string it cannot parse back.
        let v3 = Platform(arch: "amd64", os: "linux", variant: "v3")
        await store.record(reference: "docker.io/library/tool:v3", platform: v3)
        let found = await store.platform(forReference: "docker.io/library/tool:v3")
        #expect(found?.architecture == "amd64")
        #expect(found?.variant == "v3")
    }

    @Test("the last pull of a reference wins")
    func lastPullWins() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(reference: "docker.io/library/alpine:latest", platform: try Platform(from: "linux/amd64"))
        await store.record(reference: "docker.io/library/alpine:latest", platform: try Platform(from: "linux/arm64"))
        #expect(await store.platform(forReference: "docker.io/library/alpine:latest")?.architecture == "arm64")
    }

    @Test("tagging copies the variant to the new reference and leaves the source alone")
    func tagCopiesVariant() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(reference: "docker.io/library/alpine:latest", platform: try Platform(from: "linux/amd64"))
        await store.copy(from: "docker.io/library/alpine:latest", to: "docker.io/library/local-amd64:latest")

        #expect(await store.platform(forReference: "docker.io/library/local-amd64:latest")?.architecture == "amd64")
        #expect(await store.platform(forReference: "docker.io/library/alpine:latest")?.architecture == "amd64")

        // Re-pulling the SOURCE for another platform must not move the tag:
        // the tag is its own identity, not the index digest it shares.
        await store.record(reference: "docker.io/library/alpine:latest", platform: try Platform(from: "linux/arm64"))
        #expect(await store.platform(forReference: "docker.io/library/local-amd64:latest")?.architecture == "amd64")
        #expect(await store.platform(forReference: "docker.io/library/alpine:latest")?.architecture == "arm64")
    }

    @Test("removing a reference forgets it")
    func removeForgets() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(reference: "docker.io/library/alpine:latest", platform: try Platform(from: "linux/amd64"))
        await store.remove(reference: "docker.io/library/alpine:latest")
        #expect(await store.platform(forReference: "docker.io/library/alpine:latest") == nil)
    }

    @Test("records survive a daemon restart (persisted to disk)")
    func persistence() async throws {
        let directory = try tempDir()
        let first = await makeStore(directory: directory)
        await first.record(reference: "docker.io/library/persisted:latest", platform: try Platform(from: "linux/amd64"))

        let reloaded = await makeStore(directory: directory)
        #expect(await reloaded.platform(forReference: "docker.io/library/persisted:latest")?.architecture == "amd64")
    }
}

/// The create-route rule the store feeds: an explicit `--platform` wins,
/// otherwise the pulled variant beats the host default.
@Suite("ContainerCreateRoute — effective platform")
struct ContainerCreateEffectivePlatformTests {

    @Test("an explicit --platform always wins, even over the pulled variant")
    func explicitWins() throws {
        let explicit = try Platform(from: "linux/s390x")
        let pulled = try Platform(from: "linux/amd64")
        let resolved = ContainerCreateRoute.effectivePlatform(
            explicitQueryValue: "linux/s390x", hostDefault: explicit, pulledForImage: pulled)
        #expect(resolved.architecture == "s390x")
    }

    @Test("without --platform the pulled variant wins over the host default")
    func pulledVariantWins() throws {
        let host = try Platform(from: "linux/arm64")
        let pulled = try Platform(from: "linux/amd64")
        let resolved = ContainerCreateRoute.effectivePlatform(
            explicitQueryValue: nil, hostDefault: host, pulledForImage: pulled)
        #expect(resolved.architecture == "amd64")
    }

    @Test("a blank --platform is not an ask")
    func blankFallsBackToPulled() throws {
        let host = try Platform(from: "linux/arm64")
        let pulled = try Platform(from: "linux/amd64")
        let resolved = ContainerCreateRoute.effectivePlatform(
            explicitQueryValue: "", hostDefault: host, pulledForImage: pulled)
        #expect(resolved.architecture == "amd64")
    }

    @Test("an image podm never pulled runs on the host platform")
    func noRecordKeepsHost() throws {
        let host = try Platform(from: "linux/arm64")
        let resolved = ContainerCreateRoute.effectivePlatform(
            explicitQueryValue: nil, hostDefault: host, pulledForImage: nil)
        #expect(resolved.architecture == "arm64")
    }
}

/// A built image keeps the loader's VERBATIM tag as its stored reference
/// (`demo:latest`) while the build records its variant under the normalized
/// form (`docker.io/library/demo:latest`) — an exact removal with the stored
/// spelling missed and a later image reusing the name inherited the variant.
@Suite("ImagePlatformStore — removing by a stored-spelling reference")
struct ImagePlatformStoreRemoveMatchingTests {

    private func makeStore(
        directory: URL,
        normalize: @escaping @Sendable (String) -> String? = { $0 }
    ) async -> ImagePlatformStore {
        let store = ImagePlatformStore()
        await store.configure(storageDirectory: directory, normalizeReference: normalize)
        return store
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-image-platforms-rm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a verbatim spelling removes the record written under the normalized key")
    func removesThroughNormalization() async throws {
        let store = await makeStore(
            directory: try tempDir(), normalize: { _ in "docker.io/library/demo:latest" })
        await store.record(reference: "docker.io/library/demo:latest", platform: try Platform(from: "linux/amd64"))
        await store.remove(matching: "demo:latest")
        #expect(await store.platform(forReference: "docker.io/library/demo:latest") == nil)
    }

    @Test("an exact key is removed without consulting the normalizer")
    func exactKeyRemoved() async throws {
        // Normalizer that would NOT map the key: the exact match must win.
        let store = await makeStore(directory: try tempDir(), normalize: { _ in "elsewhere:latest" })
        await store.record(reference: "docker.io/library/keep:latest", platform: try Platform(from: "linux/amd64"))
        await store.remove(matching: "docker.io/library/keep:latest")
        #expect(await store.platform(forReference: "docker.io/library/keep:latest") == nil)
    }

    @Test("a dangling reference that cannot be normalized changes nothing")
    func danglingReferenceSkipped() async throws {
        // A dangling reference cannot be normalized at all.
        let store = await makeStore(directory: try tempDir(), normalize: { _ in nil })
        await store.record(reference: "docker.io/library/demo:latest", platform: try Platform(from: "linux/amd64"))
        await store.remove(matching: "<none>")
        #expect(await store.platform(forReference: "docker.io/library/demo:latest")?.architecture == "amd64")
    }
}

/// The reference alone is mutable: `docker load`/`import`/`commit` can put
/// different content under an existing name, a tag can replace a reference
/// whose record it should not inherit, and a deletion suspends long enough for
/// a pull to land. These pin the store's answers to each.
@Suite("ImagePlatformStore — content replacement, absence copy, deletion race")
struct ImagePlatformStoreContentLifecycleTests {

    private func makeStore(
        directory: URL,
        normalize: @escaping @Sendable (String) -> String? = { $0 }
    ) async -> ImagePlatformStore {
        let store = ImagePlatformStore()
        await store.configure(storageDirectory: directory, normalizeReference: normalize)
        return store
    }

    private func tempDir(permissions: Int16? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-image-platforms-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: dir.path)
        }
        return dir
    }

    private let amd64 = Platform(arch: "amd64", os: "linux", variant: nil)
    private let arm64 = Platform(arch: "arm64", os: "linux", variant: nil)

    @Test("a digest mismatch means the reference holds different content now")
    func digestMismatchIsNoRecord() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(reference: "docker.io/library/demo:latest", platform: amd64, digest: "sha256:aaa")

        #expect(await store.platform(matching: "docker.io/library/demo:latest", digest: "sha256:aaa")?.architecture == "amd64")
        #expect(
            await store.platform(matching: "docker.io/library/demo:latest", digest: "sha256:bbb") == nil,
            "an image loaded/imported under the same name must not inherit the old variant")
        #expect(
            await store.platform(matching: "docker.io/library/demo:latest") != nil,
            "a caller without a digest cannot validate and still sees the record")
    }

    @Test("a record persisted before digests were stored is accepted unvalidated")
    func preUpgradeRecordAccepted() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(reference: "docker.io/library/legacy:latest", platform: amd64)
        #expect(await store.platform(matching: "docker.io/library/legacy:latest", digest: "sha256:whatever")?.architecture == "amd64")
    }

    @Test("matching reads resolve a verbatim stored tag through the normalizer")
    func matchingResolvesStoredSpelling() async throws {
        let store = await makeStore(
            directory: try tempDir(), normalize: { _ in "docker.io/library/demo:latest" })
        await store.record(reference: "docker.io/library/demo:latest", platform: amd64)
        #expect(await store.platform(matching: "demo:latest")?.architecture == "amd64")
    }

    @Test("tagging an image with no record clears the destination's stale variant")
    func copyAbsenceClearsDestination() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(reference: "docker.io/library/target:latest", platform: amd64)
        // Tagging an unrecorded (loaded) image over the reference must copy the
        // ABSENCE, or later creates request a variant the tag no longer has.
        await store.copy(matching: "docker.io/library/loaded:latest", to: "docker.io/library/target:latest")
        #expect(await store.platform(forReference: "docker.io/library/target:latest") == nil)
    }

    @Test("copy resolves a verbatim source spelling")
    func copyResolvesSourceSpelling() async throws {
        let store = await makeStore(
            directory: try tempDir(), normalize: { _ in "docker.io/library/demo:latest" })
        await store.record(reference: "docker.io/library/demo:latest", platform: amd64)
        await store.copy(matching: "demo:latest", to: "docker.io/library/copy:latest")
        #expect(await store.platform(forReference: "docker.io/library/copy:latest")?.architecture == "amd64")
    }

    @Test("a record written after the deletion snapshot survives the cleanup")
    func removalKeepsNewerRecord() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(reference: "docker.io/library/alpine:latest", platform: amd64)
        let cutoff = try #require(await store.recordedInstant(matching: "docker.io/library/alpine:latest"))

        // A pull lands while the delete is suspended and records its own choice.
        await store.record(reference: "docker.io/library/alpine:latest", platform: arm64)
        await store.remove(matching: "docker.io/library/alpine:latest", recordedBefore: cutoff)

        #expect(
            await store.platform(forReference: "docker.io/library/alpine:latest")?.architecture == "arm64",
            "the concurrent pull's selection must not be discarded")
    }

    @Test("a failed persist is retried by the next identical record")
    func persistFailureIsRetried() async throws {
        let dir = try tempDir(permissions: 0o500)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let store = await makeStore(directory: dir)
        let file = dir.appendingPathComponent("podm-image-platforms.json")

        await store.record(reference: "docker.io/library/retry:latest", platform: amd64)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the write must have failed")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // The SAME record again: the equality guard must not skip the retry.
        await store.record(reference: "docker.io/library/retry:latest", platform: amd64)
        #expect(FileManager.default.fileExists(atPath: file.path), "an unchanged record must still retry a failed write")
    }
}

/// A deletion guards its cleanup with a fixed instant taken when it starts.
/// Two things must follow: an identical re-pull refreshes the record's
/// timestamp (so the guard keeps it), and a record loaded from disk — which
/// carries no in-memory timestamp — is still cleaned up.
@Suite("ImagePlatformStore — deletion cutoff semantics")
struct ImagePlatformStoreDeletionCutoffTests {

    private func makeStore(directory: URL) async -> ImagePlatformStore {
        let store = ImagePlatformStore()
        await store.configure(storageDirectory: directory)
        return store
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-image-platforms-cutoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("an identical re-pull refreshes the timestamp and survives a deletion's cleanup")
    func identicalPullRefreshesTimestamp() async throws {
        let store = await makeStore(directory: try tempDir())
        let ref = "docker.io/library/alpine:latest"
        let amd64 = Platform(arch: "amd64", os: "linux", variant: nil)
        await store.record(reference: ref, platform: amd64)

        // The delete starts...
        let deletionStartedAt: ContinuousClock.Instant = .now
        // ...and the pull recreates the reference for the SAME variant: the
        // persisted content is unchanged, but the selection is fresh.
        await store.record(reference: ref, platform: amd64)
        await store.remove(matching: ref, recordedBefore: deletionStartedAt)

        #expect(
            await store.platform(forReference: ref)?.architecture == "amd64",
            "a pull that re-recorded the reference must keep its selection")
    }

    @Test("a record loaded from disk (no in-memory timestamp) is still removed by a deletion")
    func loadedRecordStillRemoved() async throws {
        let directory = try tempDir()
        let first = await makeStore(directory: directory)
        let ref = "docker.io/library/alpine:latest"
        await first.record(reference: ref, platform: Platform(arch: "amd64", os: "linux", variant: nil))

        // A daemon restart: the reloaded store has no in-memory timestamps.
        let reloaded = await makeStore(directory: directory)
        let deletionStartedAt: ContinuousClock.Instant = .now
        await reloaded.remove(matching: ref, recordedBefore: deletionStartedAt)

        #expect(await reloaded.platform(forReference: ref) == nil)
    }
}

/// Tagging captures the source selection BEFORE the tag suspends, so a pull
/// that lands in that window cannot change what the destination inherits.
@Suite("ImagePlatformStore — captured selections")
struct ImagePlatformStoreCapturedSelectionTests {

    private func makeStore(directory: URL) async -> ImagePlatformStore {
        let store = ImagePlatformStore()
        await store.configure(storageDirectory: directory)
        return store
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-image-platforms-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a capture taken before a concurrent re-record still applies the original selection")
    func captureIsAPointInTime() async throws {
        let store = await makeStore(directory: try tempDir())
        let source = "docker.io/library/demo:latest"
        let amd64 = Platform(arch: "amd64", os: "linux", variant: nil)
        let arm64 = Platform(arch: "arm64", os: "linux", variant: nil)
        await store.record(reference: source, platform: amd64, digest: "sha256:aaa")

        // The tag route captures now; a pull of the same name lands afterwards.
        let captured = await store.captureSelection(matching: source, digest: "sha256:aaa")
        await store.record(reference: source, platform: arm64, digest: "sha256:bbb")

        await store.copy(selection: captured, to: "docker.io/library/tag:latest")
        #expect(await store.platform(forReference: "docker.io/library/tag:latest")?.architecture == "amd64")
    }

    @Test("a capture of an unrecorded source copies its absence")
    func captureOfNothingClears() async throws {
        let store = await makeStore(directory: try tempDir())
        let dest = "docker.io/library/target:latest"
        await store.record(reference: dest, platform: Platform(arch: "amd64", os: "linux", variant: nil))
        let captured = await store.captureSelection(matching: "docker.io/library/none:latest", digest: nil)
        await store.copy(selection: captured, to: dest)
        #expect(await store.platform(forReference: dest) == nil)
    }
}
