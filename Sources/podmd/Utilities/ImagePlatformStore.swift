import Foundation
import Logging

/// The platform variant of each image reference podm pulled or built.
///
/// Apple's image store keeps the whole OCI INDEX under a reference and
/// resolves a variant on demand, so "which variant is this image" is not
/// recorded anywhere the routes can read. That made `podman pull --platform
/// linux/amd64 alpine` followed by `podman run alpine` silently run the ARM64
/// variant: container create defaulted to the host platform and the store
/// happily unpacked that variant out of the same index.
///
/// Docker's semantics are the opposite: the image you pulled IS the image you
/// run (`docker run` on an amd64 image runs amd64 under emulation, with a
/// warning, instead of quietly switching variants). This store records the
/// variant per NORMALIZED REFERENCE — the identity clients tag, run and delete
/// by — so a tag made from the image keeps its variant (`copy`), and deleting
/// it forgets the entry. Keying by digest instead conflated every tag pointing
/// at the same index: tagging an amd64 pull, then pulling the same name for
/// arm64, silently changed the tag's variant.
///
/// Persisted: podmd idle-exits between uses, and a forgotten variant would
/// silently revert every later run to the host platform.
actor ImagePlatformStore {
    static let shared = ImagePlatformStore()

    /// The platform's components. Persisted as components rather than a
    /// `"os/arch/variant"` string: `Platform(from:)` rejects some valid OCI
    /// platforms in that textual form (e.g. `linux/amd64/v3`), and a stored
    /// value that cannot be parsed back would silently resolve to the host.
    struct Record: Codable, Equatable {
        let os: String
        let arch: String
        let variant: String?
    }

    private var platforms: [String: Record] = [:]
    private var fileURL: URL?
    private let log = Logger(label: "podm.image-platforms")

    func configure(storageDirectory: URL) {
        let url = storageDirectory.appendingPathComponent("podm-image-platforms.json")
        fileURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            platforms = try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: url))
        } catch {
            log.error(
                "could not load image platform overrides from \(url.path) — images pulled for a non-host platform are resolved by host platform again: \(error)"
            )
        }
    }

    /// Records the variant `reference` (normalized) was pulled or built for.
    func record(reference: String, platform: Platform) {
        guard !reference.isEmpty else { return }
        let record = Record(os: platform.os, arch: platform.architecture, variant: platform.variant)
        guard platforms[reference] != record else { return }
        platforms[reference] = record
        persist()
    }

    /// The variant the image at `reference` (normalized) was pulled or built
    /// for, if podm recorded one.
    func platform(forReference reference: String) -> Platform? {
        guard let record = platforms[reference] else { return nil }
        return Platform(arch: record.arch, os: record.os, variant: record.variant)
    }

    /// A tag is the SAME image: the new reference inherits the variant.
    func copy(from source: String, to destination: String) {
        guard let record = platforms[source], platforms[destination] != record else { return }
        platforms[destination] = record
        persist()
    }

    /// The reference was deleted or untagged — forget its variant so a later
    /// image reusing the name cannot inherit it.
    func remove(reference: String) {
        guard platforms.removeValue(forKey: reference) != nil else { return }
        persist()
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
