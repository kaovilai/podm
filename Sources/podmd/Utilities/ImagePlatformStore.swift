import Foundation
import Logging

/// The platform variant of each image podm actually pulled.
///
/// Apple's image store keeps the whole OCI INDEX under a reference and
/// resolves a variant on demand, so "which variant is this image" is not
/// recorded anywhere the routes can read. That made `podman pull --platform
/// linux/amd64 alpine` followed by `podman run alpine` silently run the
/// ARM64 variant: container create defaulted to the host platform and the
/// store happily unpacked that variant out of the same index.
///
/// Docker's semantics are the opposite: the image you pulled IS the image you
/// run (`docker run` on an amd64 image runs amd64 under emulation, with a
/// warning, instead of quietly switching variants). This store records the
/// variant at pull time — keyed by the image's stored digest, which survives
/// reference spelling differences (`alpine` vs `alpine:latest` vs
/// `docker.io/library/alpine:latest`) — so container create and image inspect
/// resolve the variant the user actually asked for.
///
/// Persisted: podmd idle-exits between uses, and a forgotten variant would
/// silently revert every later run to the host platform.
actor ImagePlatformStore {
    static let shared = ImagePlatformStore()

    private var platforms: [String: String] = [:]
    private var fileURL: URL?
    private let log = Logger(label: "podm.image-platforms")

    func configure(storageDirectory: URL) {
        let url = storageDirectory.appendingPathComponent("podm-image-platforms.json")
        fileURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            platforms = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        } catch {
            log.error(
                "could not load image platform overrides from \(url.path) — images pulled for a non-host platform are resolved by host platform again: \(error)"
            )
        }
    }

    /// Records the variant `digest` was pulled for.
    func record(digest: String, platform: Platform) {
        guard let key = Self.key(digest) else { return }
        let spec = Self.spec(platform)
        guard platforms[key] != spec else { return }
        platforms[key] = spec
        persist()
    }

    /// The variant the image was last pulled for, if podm pulled it.
    func platform(forDigest digest: String) -> Platform? {
        guard let key = Self.key(digest), let spec = platforms[key] else { return nil }
        return try? Platform(from: spec)
    }

    func remove(digest: String) {
        guard let key = Self.key(digest), platforms.removeValue(forKey: key) != nil else { return }
        persist()
    }

    /// Digests arrive as an index digest or (for single-platform images) a
    /// bare manifest digest, and Apple may hand them back with or without the
    /// algorithm prefix. Normalizing to the bare hex keeps both paths on one
    /// key.
    static func key(_ digest: String) -> String? {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let colon = trimmed.firstIndex(of: ":"), !trimmed[..<colon].contains("/") {
            return String(trimmed[trimmed.index(after: colon)...])
        }
        return trimmed
    }

    static func spec(_ platform: Platform) -> String {
        platform.variant.map { "\(platform.os)/\(platform.architecture)/\($0)" }
            ?? "\(platform.os)/\(platform.architecture)"
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try JSONEncoder().encode(platforms).write(to: fileURL, options: .atomic)
        } catch {
            log.error("could not persist image platform overrides to \(fileURL.path): \(error)")
        }
    }
}
