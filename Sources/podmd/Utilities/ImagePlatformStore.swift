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
/// Each record also carries the index digest it was written for. The
/// reference alone is mutable — `docker load`, `docker import` and
/// `docker commit` can put DIFFERENT content under an existing name without
/// touching this store — so a read that has the resolved image's digest
/// compares it and treats a mismatch as "no record" (host default) instead of
/// selecting a variant the content no longer has.
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
        /// The OCI index digest the reference resolved to when recorded.
        /// Optional: records written before this field existed decode as nil
        /// and are accepted unvalidated (the next pull rewrites them).
        let digest: String?
        /// When the record was written, in memory only — lets a deletion that
        /// suspends tell whether a concurrent pull re-recorded the reference
        /// in the meantime.
        var recordedAt: ContinuousClock.Instant?

        private enum CodingKeys: String, CodingKey { case os, arch, variant, digest }

        /// The recorded CONTENT is what identifies a record; the in-memory
        /// timestamp is bookkeeping and never part of an equality decision.
        static func == (lhs: Record, rhs: Record) -> Bool {
            lhs.os == rhs.os && lhs.arch == rhs.arch && lhs.variant == rhs.variant && lhs.digest == rhs.digest
        }
    }

    private var platforms: [String: Record] = [:]
    private var fileURL: URL?
    /// Same normalization the recording side uses (it needs the daemon's
    /// system config, which the delete route does not carry) — captured at
    /// configure time so `remove(matching:)` can find the key.
    private var normalizeReference: (@Sendable (String) -> String?)?
    /// A write failed; the in-memory state is ahead of disk until one succeeds.
    /// Retried by the next mutation that would otherwise be a no-op.
    private var needsPersist = false
    private let log = Logger(label: "podm.image-platforms")

    func configure(storageDirectory: URL, normalizeReference: (@Sendable (String) -> String?)? = nil) {
        let url = storageDirectory.appendingPathComponent("podm-image-platforms.json")
        fileURL = url
        self.normalizeReference = normalizeReference
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
    func record(reference: String, platform: Platform, digest: String? = nil) {
        guard !reference.isEmpty else { return }
        var record = Record(os: platform.os, arch: platform.architecture, variant: platform.variant, digest: digest)
        if platforms[reference] == record {
            // Same record again — but a previous persist may have failed, and
            // skipping the write here would leave disk behind forever.
            if needsPersist { persist() }
            return
        }
        record.recordedAt = .now
        platforms[reference] = record
        persist()
    }

    /// The variant the image at `reference` (normalized) was pulled or built
    /// for, if podm recorded one.
    func platform(forReference reference: String) -> Platform? {
        guard let record = platforms[reference] else { return nil }
        return Platform(arch: record.arch, os: record.os, variant: record.variant)
    }

    /// The variant for a reference the caller may hold in ANY spelling (a
    /// stored tag such as `demo:latest`, an image ID, or the request's own
    /// form). Tries the exact key first, then the configured normalization.
    /// A resolved image digest, when supplied, must match the one recorded —
    /// otherwise the reference has been replaced with different content and
    /// the record no longer describes it.
    func platform(matching reference: String, digest: String? = nil) -> Platform? {
        guard let record = matchingRecord(reference), digestMatches(record, digest: digest) else { return nil }
        return Platform(arch: record.arch, os: record.os, variant: record.variant)
    }

    /// A tag is the SAME image: the new reference inherits the variant.
    func copy(from source: String, to destination: String) {
        copy(resolved: platforms[source], to: destination)
    }

    /// `copy(from:to:)` for a source the caller holds in any spelling, and for
    /// a destination that may already have a record of its own.
    ///
    /// A source with no record copies its ABSENCE: tagging an arm64-only
    /// loaded image over a reference that still carries an amd64 pull record
    /// must clear that record, or later creates would request a variant the
    /// tag no longer has.
    func copy(matching source: String, digest: String? = nil, to destination: String) {
        let record = matchingRecord(source).flatMap { digestMatches($0, digest: digest) ? $0 : nil }
        copy(resolved: record, to: destination)
    }

    private func copy(resolved record: Record?, to destination: String) {
        guard !destination.isEmpty else { return }
        if var record {
            guard platforms[destination] != record else {
                if needsPersist { persist() }
                return
            }
            record.recordedAt = .now
            platforms[destination] = record
        } else {
            guard platforms.removeValue(forKey: destination) != nil else {
                if needsPersist { persist() }
                return
            }
        }
        persist()
    }

    /// The reference was deleted or untagged — forget its variant so a later
    /// image reusing the name cannot inherit it.
    func remove(reference: String) {
        guard platforms.removeValue(forKey: reference) != nil else {
            if needsPersist { persist() }
            return
        }
        persist()
    }

    /// Removes the variant recorded for a reference the caller only has in its
    /// STORED spelling.
    ///
    /// A built image keeps the loader's verbatim tag (`demo:latest`) as its
    /// stored reference, while the build recorded its variant under the
    /// normalized form (`docker.io/library/demo:latest`) — an exact removal with
    /// the stored spelling would miss, leaving a stale variant that a later
    /// `docker load` of the same name would inherit. Tries the exact key first,
    /// then the configured normalization. Dangling references (`<none>`,
    /// `untagged@…`) never match a record and are simply skipped.
    func remove(matching reference: String) {
        remove(matching: reference, recordedBefore: nil)
    }

    /// `remove(matching:)` that leaves alone a record written AFTER the caller
    /// snapshotted the reference.
    ///
    /// Deletion suspends (blob cleanup, remaining-reference lookup) and a pull
    /// arriving in that window can recreate the reference and record its own
    /// platform; an unconditional removal would then throw away the pull's
    /// selection. The caller reads `recordedInstant(matching:)` before it
    /// starts deleting and passes it here; a newer record wins.
    func remove(matching reference: String, recordedBefore cutoff: ContinuousClock.Instant?) {
        guard let key = matchingKey(reference) else {
            if needsPersist { persist() }
            return
        }
        if let cutoff, let recordedAt = platforms[key]?.recordedAt, recordedAt > cutoff {
            return
        }
        platforms.removeValue(forKey: key)
        persist()
    }

    /// When `reference` (any spelling) was last recorded, for the
    /// deletion-race guard above.
    func recordedInstant(matching reference: String) -> ContinuousClock.Instant? {
        guard let key = matchingKey(reference) else { return nil }
        return platforms[key]?.recordedAt
    }

    private func matchingKey(_ reference: String) -> String? {
        if platforms[reference] != nil { return reference }
        guard let normalized = normalizeReference?(reference), platforms[normalized] != nil else { return nil }
        return normalized
    }

    private func matchingRecord(_ reference: String) -> Record? {
        if let record = platforms[reference] { return record }
        guard let normalized = normalizeReference?(reference) else { return nil }
        return platforms[normalized]
    }

    private func digestMatches(_ record: Record, digest: String?) -> Bool {
        guard let stored = record.digest, let digest else { return true }
        return Self.strippedDigest(stored) == Self.strippedDigest(digest)
    }

    private static func strippedDigest(_ value: String) -> String {
        value.hasPrefix("sha256:") ? String(value.dropFirst("sha256:".count)) : value
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try JSONEncoder().encode(platforms).write(to: fileURL, options: .atomic)
            needsPersist = false
        } catch {
            needsPersist = true
            log.error("could not persist image platform overrides to \(fileURL.path): \(error)")
        }
    }
}
