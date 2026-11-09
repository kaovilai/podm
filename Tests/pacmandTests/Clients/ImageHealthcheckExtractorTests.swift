import Foundation
import Logging
import Testing

@testable import pacmand

/// Tests for `ImageHealthcheckExtractor` — reading a Dockerfile `HEALTHCHECK`
/// out of an image's raw OCI config blob.
///
/// Apple's `ContainerizationOCI.ImageConfig` does not model the image config's
/// `config.Healthcheck` field, so the extractor reads the raw JSON blob from
/// the daemon's content store instead, addressed by the manifest's config
/// descriptor digest (`<app-support>/content/blobs/sha256/<hex>`).
///
/// Each test writes its blob under a fresh temp directory and uses a UNIQUE
/// digest: lookups are memoized process-wide by digest (image configs are
/// immutable, content-addressed data), so a shared digest would leak a cached
/// result between tests.
@Suite("ImageHealthcheckExtractor")
struct ImageHealthcheckExtractorTests {

    private let logger = Logger(label: "pacman.tests.image-healthcheck-extractor")

    /// Writes `json` as the config blob named by `digest` (the hex suffix is
    /// arbitrary — the extractor does not verify the content hash, it only
    /// reads the file the digest addresses) and returns the app-support URL
    /// the extractor should be given.
    private func makeContentStore(blob json: String, digestHex: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let blobDir = root
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
        try FileManager.default.createDirectory(at: blobDir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: blobDir.appendingPathComponent(digestHex))
        return root
    }

    @Test("a Dockerfile HEALTHCHECK is decoded with all fields")
    func validHealthcheckIsDecoded() async throws {
        let appSupport = try makeContentStore(
            blob: #"{"architecture":"arm64","os":"linux","config":{"Env":["A=1"],"Healthcheck":{"Test":["CMD-SHELL","curl -f http://localhost/ || exit 1"],"Interval":30000000000,"Timeout":5000000000,"StartPeriod":10000000000,"Retries":3}}}"#,
            digestHex: String(repeating: "a1", count: 32)
        )

        let healthcheck = await ImageHealthcheckExtractor.healthcheck(
            configDigest: "sha256:" + String(repeating: "a1", count: 32),
            appSupportURL: appSupport,
            logger: logger
        )

        #expect(healthcheck?.Test == ["CMD-SHELL", "curl -f http://localhost/ || exit 1"])
        #expect(healthcheck?.Interval == 30_000_000_000)
        #expect(healthcheck?.Timeout == 5_000_000_000)
        #expect(healthcheck?.StartPeriod == 10_000_000_000)
        #expect(healthcheck?.Retries == 3)
    }

    @Test("an image config without a healthcheck yields nil")
    func absentHealthcheckYieldsNil() async throws {
        let appSupport = try makeContentStore(
            blob: #"{"architecture":"arm64","os":"linux","config":{"Env":["A=1"],"Cmd":["sleep","1"]}}"#,
            digestHex: String(repeating: "b2", count: 32)
        )

        let healthcheck = await ImageHealthcheckExtractor.healthcheck(
            configDigest: "sha256:" + String(repeating: "b2", count: 32),
            appSupportURL: appSupport,
            logger: logger
        )

        #expect(healthcheck == nil)
    }

    @Test("a config object that is entirely absent yields nil")
    func missingConfigObjectYieldsNil() async throws {
        let appSupport = try makeContentStore(
            blob: #"{"architecture":"arm64","os":"linux"}"#,
            digestHex: String(repeating: "b3", count: 32)
        )

        let healthcheck = await ImageHealthcheckExtractor.healthcheck(
            configDigest: "sha256:" + String(repeating: "b3", count: 32),
            appSupportURL: appSupport,
            logger: logger
        )

        #expect(healthcheck == nil)
    }

    @Test("a NONE disable sentinel is passed through verbatim")
    func noneSentinelIsPassedThrough() async throws {
        // Docker's `HEALTHCHECK NONE` bakes `{"Test":["NONE"]}` into the image
        // config. The extractor must surface it — "image says disabled" is a
        // meaningful result for create-time precedence, not an absence.
        let appSupport = try makeContentStore(
            blob: #"{"config":{"Healthcheck":{"Test":["NONE"]}}}"#,
            digestHex: String(repeating: "c4", count: 32)
        )

        let healthcheck = await ImageHealthcheckExtractor.healthcheck(
            configDigest: "sha256:" + String(repeating: "c4", count: 32),
            appSupportURL: appSupport,
            logger: logger
        )

        #expect(healthcheck?.Test == ["NONE"])
    }

    @Test("undecodable blob JSON yields nil, not an error")
    func malformedJsonYieldsNil() async throws {
        let appSupport = try makeContentStore(
            blob: #"{"architecture":"arm64","config":{"Healthcheck""#,
            digestHex: String(repeating: "d5", count: 32)
        )

        let healthcheck = await ImageHealthcheckExtractor.healthcheck(
            configDigest: "sha256:" + String(repeating: "d5", count: 32),
            appSupportURL: appSupport,
            logger: logger
        )

        #expect(healthcheck == nil)
    }

    @Test("a healthcheck with wrongly-typed fields yields nil, not an error")
    func wronglyTypedHealthcheckYieldsNil() async throws {
        let appSupport = try makeContentStore(
            blob: #"{"config":{"Healthcheck":{"Test":["CMD","true"],"Interval":"30s"}}}"#,
            digestHex: String(repeating: "d6", count: 32)
        )

        let healthcheck = await ImageHealthcheckExtractor.healthcheck(
            configDigest: "sha256:" + String(repeating: "d6", count: 32),
            appSupportURL: appSupport,
            logger: logger
        )

        #expect(healthcheck == nil)
    }

    @Test("a missing blob yields nil (pruned or never-pulled content)")
    func missingBlobYieldsNil() async throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let healthcheck = await ImageHealthcheckExtractor.healthcheck(
            configDigest: "sha256:" + String(repeating: "e7", count: 32),
            appSupportURL: appSupport,
            logger: logger
        )

        #expect(healthcheck == nil)
    }

    @Test("a malformed digest is refused, not spliced into a path")
    func malformedDigestYieldsNil() async throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let healthcheck = await ImageHealthcheckExtractor.healthcheck(
            configDigest: "../../etc/passwd",
            appSupportURL: appSupport,
            logger: logger
        )

        #expect(healthcheck == nil)
    }

    @Test("results are memoized per digest — the blob is read at most once")
    func lookupsAreMemoizedPerDigest() async throws {
        let hex = String(repeating: "f8", count: 32)
        let appSupport = try makeContentStore(
            blob: #"{"config":{"Healthcheck":{"Test":["CMD","true"],"Retries":2}}}"#,
            digestHex: hex
        )
        let digest = "sha256:" + hex

        let first = await ImageHealthcheckExtractor.healthcheck(
            configDigest: digest, appSupportURL: appSupport, logger: logger)
        #expect(first?.Retries == 2)

        // Remove the blob: a re-read would now find nothing, so an identical
        // second result proves the first was served from the digest cache.
        try FileManager.default.removeItem(
            at: appSupport
                .appendingPathComponent("content")
                .appendingPathComponent("blobs")
                .appendingPathComponent("sha256")
                .appendingPathComponent(hex)
        )
        let second = await ImageHealthcheckExtractor.healthcheck(
            configDigest: digest, appSupportURL: appSupport, logger: logger)
        #expect(second?.Retries == 2)

        // A known-ABSENT healthcheck is cached just as deliberately: planting a
        // healthcheck-carrying blob under an already-resolved nil digest must
        // not resurrect a value (image configs are immutable).
        let nilDigest = "sha256:" + String(repeating: "0f", count: 32)
        _ = await ImageHealthcheckExtractor.healthcheck(
            configDigest: nilDigest, appSupportURL: appSupport, logger: logger)
        let plantedSupport = try makeContentStore(
            blob: #"{"config":{"Healthcheck":{"Test":["CMD","true"],"Retries":9}}}"#,
            digestHex: String(repeating: "0f", count: 32)
        )
        let afterAbsence = await ImageHealthcheckExtractor.healthcheck(
            configDigest: nilDigest, appSupportURL: plantedSupport, logger: logger)
        #expect(afterAbsence == nil)
    }
}

/// Tests for the `HealthConfig` mapping used by image inspect — the
/// container-side `HealthcheckConfig` (create-route label /
/// `HealthCheckManager` currency) widened onto the inspect response model.
@Suite("HealthConfig(HealthcheckConfig) mapping")
struct HealthConfigMappingTests {

    @Test("nil maps to nil (Docker omits the field entirely)")
    func nilMapsToNil() {
        #expect(HealthConfig(nil) == nil)
    }

    @Test("all fields map, widening Int time fields to Int64")
    func fieldsMapWithWidening() {
        let config = HealthcheckConfig(
            Test: ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
            Interval: 30_000_000_000,
            Timeout: 5_000_000_000,
            Retries: 3,
            StartPeriod: 10_000_000_000
        )

        let health = HealthConfig(config)

        #expect(health?.Test == ["CMD-SHELL", "curl -f http://localhost/ || exit 1"])
        #expect(health?.Interval == 30_000_000_000)
        #expect(health?.Timeout == 5_000_000_000)
        #expect(health?.Retries == 3)
        #expect(health?.StartPeriod == 10_000_000_000)
        #expect(health?.StartInterval == nil)
    }

    @Test("a NONE sentinel maps through unchanged")
    func noneMapsThrough() {
        let health = HealthConfig(HealthcheckConfig(
            Test: ["NONE"],
            Interval: nil,
            Timeout: nil,
            Retries: nil,
            StartPeriod: nil
        ))
        #expect(health?.Test == ["NONE"])
    }
}
