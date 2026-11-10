import ContainerizationOCI
import Foundation
import Logging

/// The parent-image run config a `docker commit` seeds the new image's config
/// from, plus the raw-config-only fields Apple's typed
/// `ContainerizationOCI.ImageConfig` does not model.
struct CommitParentConfig {
    let config: ContainerizationOCI.ImageConfig
    /// Keys of the parent config JSON's `config.ExposedPorts` object.
    let exposedPorts: Set<String>
    /// Keys of the parent config JSON's `config.Volumes` object.
    let volumes: Set<String>
}

/// Resolves a commit's parent image config by DIGEST from the daemon's
/// content store — never by reference. The tag a container was created from
/// may have been re-pulled or retagged since; a reference lookup would then
/// read the replacement image's config, while the digest the container's
/// `ImageDescription.descriptor` captured addresses the immutable content
/// the container was actually built on.
///
/// The image digest addresses the image INDEX for multi-platform images (or
/// the manifest directly for single-platform ones), so the walk is:
/// index blob → platform-matching manifest descriptor → manifest blob →
/// config descriptor → config blob. The final blob is decoded twice — once
/// as the typed `ContainerizationOCI.Image` (for the run config) and once as
/// a raw view recovering `config.ExposedPorts`/`config.Volumes`, the same
/// trick `ImageHealthcheckExtractor` uses for `config.Healthcheck`.
///
/// Every failure mode (blob missing — e.g. the image was pruned, undecodable
/// JSON, no manifest for the platform) maps to nil: commit then proceeds with
/// container-only seeding, the same fallback inspect uses.
enum CommitParentConfigResolver {
    static func read(
        digest: String,
        platform: Platform,
        appSupportURL: URL,
        logger: Logger
    ) -> CommitParentConfig? {
        guard
            let configDigest = resolveConfigDigest(imageDigest: digest, platform: platform, appSupportURL: appSupportURL),
            let configData = readBlob(digest: configDigest, appSupportURL: appSupportURL)
        else { return nil }

        guard let image = try? JSONDecoder().decode(ContainerizationOCI.Image.self, from: configData) else {
            logger.warning("[commit] could not decode parent image config blob \(configDigest) — committing with container-only config")
            return nil
        }
        guard let imageConfig = image.config else { return nil }

        let extras = (try? JSONDecoder().decode(RawConfigExtras.self, from: configData))?.config
        return CommitParentConfig(
            config: imageConfig,
            exposedPorts: extras?.exposedPorts.map { Set($0.keys) } ?? [],
            volumes: extras?.volumes.map { Set($0.keys) } ?? []
        )
    }

    /// image digest → the config blob digest for `platform`.
    private static func resolveConfigDigest(
        imageDigest: String,
        platform: Platform,
        appSupportURL: URL
    ) -> String? {
        guard let imageData = readBlob(digest: imageDigest, appSupportURL: appSupportURL) else { return nil }

        // An index (multi-platform) lists manifests; a bare manifest carries
        // its config descriptor directly. Try the index first, then the
        // manifest — whichever decodes wins.
        if let index = try? JSONDecoder().decode(RawIndex.self, from: imageData),
            let manifests = index.manifests, !manifests.isEmpty
        {
            // Attestation manifests share the build platform but are not
            // runnable content — skip them like the inspect route does.
            let candidates = manifests.filter { descriptor in
                descriptor.annotations?["vnd.docker.reference.type"] != "attestation-manifest"
                    && descriptor.platform?.os == platform.os
                    && descriptor.platform?.architecture == platform.architecture
            }
            // Prefer an exact variant match; a variant-less container
            // platform still accepts a variant-carrying manifest.
            let selected =
                candidates.first { $0.platform?.variant == platform.variant }
                ?? candidates.first
            guard let selected else { return nil }
            guard
                let manifestData = readBlob(digest: selected.digest, appSupportURL: appSupportURL),
                let manifest = try? JSONDecoder().decode(RawManifest.self, from: manifestData)
            else { return nil }
            return manifest.config?.digest
        }

        if let manifest = try? JSONDecoder().decode(RawManifest.self, from: imageData) {
            return manifest.config?.digest
        }
        return nil
    }

    /// Reads a content-store blob. The digest is spliced into a filesystem
    /// path, so only a well-formed `algorithm:hex` string may be followed
    /// (mirrors `ImageHealthcheckExtractor`'s guard).
    private static func readBlob(digest: String, appSupportURL: URL) -> Data? {
        guard digest.wholeMatch(of: /[a-z0-9]+:[a-fA-F0-9]{32,}/) != nil else { return nil }
        let parts = digest.split(separator: ":")
        let blobURL =
            appSupportURL
            .appendingPathComponent("content")
            .appendingPathComponent("blobs")
            .appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: blobURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else { return nil }
        return try? Data(contentsOf: blobURL)
    }

    /// Index view — only `manifests` is interesting; a manifest-shaped blob
    /// fails this decode and falls through to `RawManifest`.
    private struct RawIndex: Decodable {
        let manifests: [ContainerizationOCI.Descriptor]?
    }

    /// Manifest view — only the config descriptor is interesting.
    private struct RawManifest: Decodable {
        let config: ContainerizationOCI.Descriptor?
    }

    /// Raw view of the config blob's `config` object, decoding ONLY the keys
    /// the typed `ContainerizationOCI.ImageConfig` does not model.
    private struct RawConfigExtras: Decodable {
        let config: Extras?

        struct Extras: Decodable {
            let exposedPorts: [String: Empty]?
            let volumes: [String: Empty]?

            enum CodingKeys: String, CodingKey {
                case exposedPorts = "ExposedPorts"
                case volumes = "Volumes"
            }
        }
    }

    private struct Empty: Decodable {}
}
