// SPDX-License-Identifier: Apache-2.0
import Foundation
import Logging

/// Extracts a Dockerfile `HEALTHCHECK` from an image's raw OCI config blob.
///
/// Apple's `ContainerizationOCI.ImageConfig` — the typed view returned by
/// `ClientImage.config(for:)` — does not model the image config's
/// `config.Healthcheck` field, so a HEALTHCHECK baked into an image at build
/// time is invisible through the typed path. The only way to see it is to read
/// the raw JSON config blob that the image manifest's config descriptor points
/// at. Blobs live in the daemon's content store
/// (`<app-support>/content/blobs/sha256/<hex>`), the same on-disk layout
/// `ClientManifestService` reads and writes.
///
/// Because content is addressed by digest, results are memoized per digest —
/// an image config blob is immutable, so a digest can never change meaning.
///
/// Every failure mode (blob missing, undecodable JSON, malformed healthcheck)
/// maps to `nil` plus at most a warning log: a healthcheck is auxiliary, so it
/// must never fail an image inspect or container create that would otherwise
/// succeed.
enum ImageHealthcheckExtractor {
    /// Raw view of the OCI image config JSON, decoding ONLY the
    /// `config.Healthcheck` key — every other field is ignored.
    private struct RawImageConfig: Decodable {
        let config: Config?

        struct Config: Decodable {
            let Healthcheck: HealthcheckConfig?
        }
    }

    /// Memoizes lookups by config-blob digest. Values are `HealthcheckConfig?`
    /// Only DEFINITIVE answers are cached: a blob that was read and decoded
    /// (nil = the image genuinely has no healthcheck). A missing or unreadable
    /// blob is transient — content not yet written, an image re-pulled after a
    /// prune — and must be retried on the next lookup, or one early miss would
    /// silently drop that digest's HEALTHCHECK for the daemon's whole life.
    private actor Cache {
        private var values: [String: HealthcheckConfig?] = [:]

        func get(_ digest: String) -> HealthcheckConfig?? {
            values[digest]
        }

        func set(_ value: HealthcheckConfig?, for digest: String) {
            values[digest] = value
        }
    }

    private static let cache = Cache()

    /// Extraction outcome: `.decoded` is definitive (cached), `.unreadable` is
    /// transient (never cached).
    private enum Extraction {
        case decoded(HealthcheckConfig?)
        case unreadable
    }

    /// Returns the image's `HEALTHCHECK`, or nil when the image has none or its
    /// config blob can't currently be read. Never throws.
    static func healthcheck(configDigest: String, appSupportURL: URL, logger: Logger) async -> HealthcheckConfig? {
        if let cached = await cache.get(configDigest) {
            return cached
        }
        switch extract(configDigest: configDigest, appSupportURL: appSupportURL, logger: logger) {
        case .decoded(let value):
            await cache.set(value, for: configDigest)
            return value
        case .unreadable:
            return nil
        }
    }

    private static func extract(configDigest: String, appSupportURL: URL, logger: Logger) -> Extraction {
        // The digest is spliced into a filesystem path; only a well-formed
        // `algorithm:hex` string may be followed (mirrors `OCILayoutPruner`'s
        // guard — anything else is treated as absent, not an error).
        guard configDigest.wholeMatch(of: /[a-z0-9]+:[a-fA-F0-9]{32,}/) != nil else {
            logger.warning("[healthcheck] refusing to read image config blob with malformed digest '\(configDigest)'")
            // A malformed digest can never address a real blob — definitive.
            return .decoded(nil)
        }
        let parts = configDigest.split(separator: ":")
        let blobURL =
            appSupportURL
            .appendingPathComponent("content")
            .appendingPathComponent("blobs")
            .appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))

        // Missing or unreadable blob → transient (not-yet-written content,
        // re-pull after a prune): NOT cached, retried next lookup.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: blobURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            let data = try? Data(contentsOf: blobURL)
        else {
            return .unreadable
        }

        do {
            return .decoded(try JSONDecoder().decode(RawImageConfig.self, from: data).config?.Healthcheck)
        } catch {
            // Undecodable: could be a truncated write — transient, retried.
            logger.warning(
                "[healthcheck] could not decode image config blob \(configDigest): \(error) — treating as no healthcheck this once"
            )
            return .unreadable
        }
    }
}

extension HealthConfig {
    /// Maps the container-side healthcheck model (the create-route label /
    /// `HealthCheckManager` currency) onto the image-inspect response model,
    /// widening the time fields from `Int` to `Int64`. `StartInterval` is a
    /// newer Docker extension the container-side model does not carry, so it
    /// maps to nil.
    init?(_ config: HealthcheckConfig?) {
        guard let config else { return nil }
        self.init(
            Test: config.Test,
            Interval: config.Interval.map(Int64.init),
            Timeout: config.Timeout.map(Int64.init),
            Retries: config.Retries,
            StartPeriod: config.StartPeriod.map(Int64.init),
            StartInterval: nil
        )
    }
}
