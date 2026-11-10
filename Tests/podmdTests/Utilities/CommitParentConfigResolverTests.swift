import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging
import Testing

@testable import podmd

/// `CommitParentConfigResolver` — the digest-based parent-image lookup behind
/// `docker commit`. Exercises the full content-store walk (index →
/// platform-matching manifest → config blob) against a fixture store laid
/// out exactly like the daemon's, plus the raw-config recovery of
/// ExposedPorts/Volumes the typed `ImageConfig` cannot see.
@Suite("CommitParentConfigResolver — digest-based parent lookup")
struct CommitParentConfigResolverTests {

    private let logger = Logger(label: "test")

    /// One manifest (plus its config blob) in the fixture index.
    private struct FixturePlatform {
        let arch: String
        let variant: String?
        let attestation: Bool
        let configJSON: [String: Any]

        init(
            arch: String, variant: String? = nil, attestation: Bool = false,
            configJSON: [String: Any] = [:]
        ) {
            self.arch = arch
            self.variant = variant
            self.attestation = attestation
            self.configJSON = configJSON
        }
    }

    /// A fixture content store: an index with one manifest per platform, each
    /// pointing at its own config blob. Blobs are addressed by their real
    /// sha256, exactly like the daemon's store.
    private struct Fixture {
        let storeDir: URL
        let indexDigest: String

        init(platforms: [FixturePlatform]) throws {
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("commit-parent-\(UUID().uuidString)")
            storeDir = workDir
            let blobsDir = workDir.appendingPathComponent("content/blobs/sha256")
            try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

            var manifestDescriptors: [[String: Any]] = []
            for platform in platforms {
                let configDigest = Self.writeBlob(
                    blobsDir,
                    [
                        "architecture": platform.arch, "os": "linux",
                        "config": platform.configJSON,
                        "rootfs": ["type": "layers", "diff_ids": []],
                    ])

                let configDescriptor: [String: Any] = [
                    "mediaType": "application/vnd.oci.image.config.v1+json",
                    "digest": "sha256:" + configDigest,
                    "size": 1,
                ]
                let manifestDigest = Self.writeBlob(
                    blobsDir, ["schemaVersion": 2, "config": configDescriptor])

                var platformObject: [String: Any] = [
                    "architecture": platform.arch, "os": "linux",
                ]
                if let variant = platform.variant {
                    platformObject["variant"] = variant
                }
                var descriptor: [String: Any] = [
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "digest": "sha256:" + manifestDigest,
                    "size": 1,
                    "platform": platformObject,
                ]
                if platform.attestation {
                    descriptor["annotations"] = ["vnd.docker.reference.type": "attestation-manifest"]
                }
                manifestDescriptors.append(descriptor)
            }

            indexDigest =
                "sha256:\(Self.writeBlob(blobsDir, ["schemaVersion": 2, "manifests": manifestDescriptors]))"
        }

        /// Writes `object` as a blob and returns its hex sha256 (the file name
        /// the content store addresses it by).
        private static func writeBlob(_ blobsDir: URL, _ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let digest = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            try! data.write(to: blobsDir.appendingPathComponent(digest))
            return digest
        }
    }

    private func amd64Config() -> [String: Any] {
        [
            "User": "0",
            "Env": ["A=1"],
            "Entrypoint": ["/bin/sh", "-c"],
            "Cmd": ["true"],
            "WorkingDir": "/srv",
            "Labels": ["a": "b"],
            "StopSignal": "SIGQUIT",
            "ExposedPorts": ["80/tcp": [:], "53/udp": [:]],
            "Volumes": ["/data": [:]],
        ]
    }

    @Test("resolves the parent by digest through the index, extracting the typed config and ExposedPorts/Volumes")
    func resolvesThroughIndex() async throws {
        let fixture = try Fixture(
            platforms: [
                FixturePlatform(arch: "arm64", configJSON: ["User": "arm-user"]),
                FixturePlatform(arch: "amd64", configJSON: amd64Config()),
            ])

        let parent = CommitParentConfigResolver.read(
            digest: fixture.indexDigest,
            platform: Platform(arch: "amd64", os: "linux"),
            appSupportURL: fixture.storeDir,
            logger: logger
        )

        let unwrapped = try #require(parent)
        #expect(unwrapped.config.user == "0")
        #expect(unwrapped.config.env == ["A=1"])
        #expect(unwrapped.config.entrypoint == ["/bin/sh", "-c"])
        #expect(unwrapped.config.cmd == ["true"])
        #expect(unwrapped.config.workingDir == "/srv")
        #expect(unwrapped.config.labels == ["a": "b"])
        #expect(unwrapped.config.stopSignal == "SIGQUIT")
        #expect(unwrapped.exposedPorts == ["80/tcp", "53/udp"])
        #expect(unwrapped.volumes == ["/data"])
    }

    @Test("the platform-matching manifest is selected, not just the first one")
    func selectsPlatformManifest() async throws {
        let fixture = try Fixture(
            platforms: [
                FixturePlatform(arch: "arm64", configJSON: ["User": "arm-user"]),
                FixturePlatform(arch: "amd64", configJSON: ["User": "amd-user"]),
            ])

        let parent = CommitParentConfigResolver.read(
            digest: fixture.indexDigest,
            platform: Platform(arch: "arm64", os: "linux"),
            appSupportURL: fixture.storeDir,
            logger: logger
        )

        #expect(try #require(parent).config.user == "arm-user")
    }

    @Test("attestation manifests are skipped even when they share the platform")
    func skipsAttestationManifests() async throws {
        let fixture = try Fixture(
            platforms: [
                FixturePlatform(arch: "amd64", attestation: true, configJSON: ["User": "attestation"]),
                FixturePlatform(arch: "amd64", configJSON: ["User": "real"]),
            ])

        let parent = CommitParentConfigResolver.read(
            digest: fixture.indexDigest,
            platform: Platform(arch: "amd64", os: "linux"),
            appSupportURL: fixture.storeDir,
            logger: logger
        )

        #expect(try #require(parent).config.user == "real")
    }

    @Test("a digest with no manifest for the platform returns nil (best-effort fallback)")
    func noManifestForPlatformReturnsNil() async throws {
        let fixture = try Fixture(platforms: [FixturePlatform(arch: "arm64", configJSON: ["User": "u"])])

        let parent = CommitParentConfigResolver.read(
            digest: fixture.indexDigest,
            platform: Platform(arch: "amd64", os: "linux"),
            appSupportURL: fixture.storeDir,
            logger: logger
        )

        #expect(parent == nil)
    }

    @Test("a missing blob (pruned image) returns nil")
    func missingBlobReturnsNil() async throws {
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("commit-parent-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: storeDir.appendingPathComponent("content/blobs/sha256"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let parent = CommitParentConfigResolver.read(
            digest: "sha256:\(String(repeating: "0", count: 64))",
            platform: Platform(arch: "amd64", os: "linux"),
            appSupportURL: storeDir,
            logger: logger
        )

        #expect(parent == nil)
    }

    @Test("ClientImageService.commitParentConfig delegates to the resolver")
    func serviceDelegates() async throws {
        let fixture = try Fixture(platforms: [FixturePlatform(arch: "amd64", configJSON: amd64Config())])
        let service = ClientImageService(containerSystemConfig: ContainerSystemConfig())

        let parent = await service.commitParentConfig(
            digest: fixture.indexDigest,
            platform: Platform(arch: "amd64", os: "linux"),
            appleContainerAppSupportUrl: fixture.storeDir,
            logger: logger
        )

        #expect(try #require(parent).exposedPorts == ["80/tcp", "53/udp"])
    }
}
