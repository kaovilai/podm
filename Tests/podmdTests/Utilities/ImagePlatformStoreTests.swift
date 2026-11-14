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

    @Test("records and returns the platform for a digest")
    func recordAndLookup() async throws {
        let store = await makeStore(directory: try tempDir())
        let amd64 = try Platform(from: "linux/amd64")
        await store.record(digest: "sha256:abc123", platform: amd64)

        let found = await store.platform(forDigest: "sha256:abc123")
        #expect(found?.os == "linux")
        #expect(found?.architecture == "amd64")
        #expect(await store.platform(forDigest: "sha256:def456") == nil)
    }

    @Test("a digest with or without its algorithm prefix is the same key")
    func digestNormalization() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(digest: "sha256:abc123", platform: try Platform(from: "linux/s390x"))
        #expect(await store.platform(forDigest: "abc123")?.architecture == "s390x")
    }

    @Test("a variant is preserved (linux/arm/v7)")
    func variantPreserved() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(digest: "sha256:v7", platform: try Platform(from: "linux/arm/v7"))
        let found = await store.platform(forDigest: "v7")
        #expect(found?.architecture == "arm")
        #expect(found?.variant == "v7")
    }

    @Test("the last pull of a digest wins")
    func lastPullWins() async throws {
        let store = await makeStore(directory: try tempDir())
        await store.record(digest: "sha256:shared", platform: try Platform(from: "linux/amd64"))
        await store.record(digest: "sha256:shared", platform: try Platform(from: "linux/arm64"))
        #expect(await store.platform(forDigest: "shared")?.architecture == "arm64")
    }

    @Test("records survive a daemon restart (persisted to disk)")
    func persistence() async throws {
        let directory = try tempDir()
        let first = await makeStore(directory: directory)
        await first.record(digest: "sha256:persisted", platform: try Platform(from: "linux/amd64"))

        let reloaded = await makeStore(directory: directory)
        #expect(await reloaded.platform(forDigest: "persisted")?.architecture == "amd64")
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
