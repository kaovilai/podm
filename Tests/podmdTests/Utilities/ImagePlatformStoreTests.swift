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
