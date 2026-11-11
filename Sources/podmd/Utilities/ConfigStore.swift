// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Logging

/// One config in the local store.
struct StoredConfig: Codable, Sendable, Equatable {
    /// 25 lowercase hex characters — same shape class as swarmkit's
    /// `identity.NewID()` (a 25-char base36 token); see `ConfigStore`'s
    /// ID-shape notes.
    let id: String
    let name: String
    let createdAt: Date
    var updatedAt: Date
    var labels: [String: String]
}

/// A config paired with its payload in one read — the list/inspect shape.
/// Configs (unlike secrets) ARE served with their data: swarmkit strips
/// `Spec.Data` on every secret reply but never on a config reply (verified,
/// moby v28.5.2 / swarmkit `8c1959736554` — see `ConfigsRoute`).
struct StoredConfigWithPayload: Sendable, Equatable {
    let config: StoredConfig
    let data: Data?
}

/// The local docker-dialect config store (moby `GET/POST /configs…`), backed
/// by files under the app-support directory. A STRUCTURAL MIRROR of
/// `SecretStore` — the same hardening, deliberately duplicated rather than
/// generalized:
///
/// - Generalizing into one generic blob store would force parameterizing
///   `SecretStore`'s podman-specific policy (driver/driverOptions plumbing,
///   `replace`/`ignore`, podman's name charset, the 512000 secret limit) and
///   put a hardened, reviewed component through churn — with in-flight
///   secrets branches stacking on it. A mirror touches nothing existing.
/// - The policies genuinely differ, so much of the "duplication" is real
///   divergence: configs validate names per SWARMKIT, not podman (≤64 bytes
///   of `[a-zA-Z0-9-_.]`, anchored alphanumerics — swarmkit
///   `manager/controlapi/common.go` `validateConfigOrSecretAnnotations`),
///   the size limit is swarmkit's `MaxConfigSize` 1000\*1024 (NOT the
///   secret store's 500\*1024), there is no driver concept at all
///   (moby's `swarm.ConfigSpec` has no `Driver` field), and there is no
///   replace/ignore (docker config create has neither).
///
/// Layout (own directory, sibling of `podm-secrets`):
///
/// - `<storageDirectory>/podm-configs/configs.json` — the metadata DB
/// - `<storageDirectory>/podm-configs/payloads/configsdata.json` — the
///   payloads keyed by ID
///
/// Both 0600, both directories 0700. Configs are non-sensitive by design
/// (that's swarm's whole secret-vs-config distinction), but there is no
/// reason for them to be group/world readable either — least privilege,
/// same discipline as the secret store. The metadata/payload SPLIT (two
/// directories, not two files in one) is what makes the persist ordering
/// invariant's failure domains separable — a test (or an unlucky
/// filesystem) can take one file's directory read-only without the other's.
///
/// An actor because route handlers hit it concurrently; persistence rewrites
/// both files atomically per mutation under a strict write ORDER (payload
/// superset first, metadata second, payload trim last — see `persist`) so a
/// process crash between renames can only ever leave orphan payload entries,
/// never metadata referencing payloads that aren't there. (Across a power
/// loss that invariant is best-effort — see writeJSON's durability notes.)
actor ConfigStore {
    enum StoreError: Error, Equatable {
        /// swarmkit `validateConfigOrSecretAnnotations`: empty name, >64
        /// UTF-8 bytes, or outside `[a-zA-Z0-9-_.]` with alphanumeric ends.
        case invalidName(String)
        /// swarmkit `validateConfigSpec`: `len(Data) >= MaxConfigSize || < 1`
        /// — "config data must be larger than 0 and less than 1024000 bytes".
        case dataTooLarge
        /// swarmkit `store.ErrNameConflict` surfaced as `AlreadyExists`
        /// ("config %s already exists").
        case nameInUse(String)
        /// A `persist()` write failed — `writeIndex` is the 0-based position
        /// of the failed write in the mutation's persist sequence, so callers
        /// can tell "nothing committed" (early writes) from "the final state
        /// already landed" (late writes) when deciding what to roll back.
        case persistFailed(reason: String, writeIndex: Int)
        /// The store could not be secured at load time — a corrupt file
        /// could not be quarantined aside (its directory was not writable),
        /// or a store directory's permissions could not be verified or
        /// tightened to owner-only. Mutations are REFUSED rather than
        /// persisting over the only copy of unreadable data; the operator
        /// resolves the files and restarts the daemon.
        case quarantineBlocked(String)
    }

    /// swarmkit `manager/controlapi/config.go`: `MaxConfigSize = 1000 * 1024`
    /// — 1000KB, TWICE the secret limit (`api/validation` `MaxSecretSize` is
    /// 500\*1024). Verified against moby v28.5.2's pinned swarmkit
    /// (`8c1959736554`).
    static let maxConfigSize = 1_024_000
    /// Same ID length class as the secret store and swarmkit's NewID.
    static let configIDLength = 25

    /// In insertion order — array order keeps listings stable and
    /// oldest-first.
    private var configs: [StoredConfig] = []
    /// id → payload. Kept in step with `configs` on every mutation.
    private var payloads: [String: Data] = [:]
    private let metadataURL: URL
    private let payloadURL: URL
    private let log: Logger
    /// True when a corrupt store file could not be moved aside at load time
    /// — the next persist would overwrite the only copy of unreadable data.
    /// Set once at init; cleared by fixing the files and restarting.
    private let quarantineBlocked: Bool
    /// The data-flush primitive used before publishing a swap: F_FULLFSYNC
    /// (reaches past the drive cache; plain fsync does not). Instance-scoped
    /// so tests can fault-inject flush failures Foundation cannot produce.
    private let fullSync: @Sendable (Int32) -> Int32

    /// Loads (or initializes) the store under `storageDirectory`. Missing
    /// files are not an error — the store simply starts empty and writes both
    /// files on first mutation. Corrupt files are logged, quarantined aside,
    /// and treated as empty (same posture as `SecretStore`): a hand-mangled
    /// store loses its configs rather than taking the daemon down.
    /// `flushSync` overrides the pre-swap data-flush primitive (tests only).
    init(
        storageDirectory: URL, logger: Logger = Logger(label: "podm.configs"),
        flushSync: (@Sendable (Int32) -> Int32)? = nil
    ) {
        let dir = storageDirectory.appendingPathComponent("podm-configs", isDirectory: true)
        let payloadsDir = dir.appendingPathComponent("payloads", isDirectory: true)
        metadataURL = dir.appendingPathComponent("configs.json")
        payloadURL = payloadsDir.appendingPathComponent("configsdata.json")
        log = logger
        fullSync = flushSync ?? { fd in fcntl(fd, F_FULLFSYNC, 0) }

        // Restrictive permissions from the start: 0700 dirs (readable only by
        // the daemon's user). Pre-existing directories are TIGHTENED, not
        // trusted: write permission on the directory is what lets another
        // local user replace or delete the store files, and a directory left
        // behind by an older build or a restored backup can carry group/world
        // bits. Only bits are cleared, never set — a deliberately read-only
        // directory keeps its owner bits. A directory that cannot be
        // inspected or secured BLOCKS the store: proceeding would expose
        // store files to other local users.
        var permissionsUnsecured = false
        let fm = FileManager.default
        for directory in [dir, payloadsDir] {
            if !fm.fileExists(atPath: directory.path) {
                do {
                    try fm.createDirectory(
                        at: directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                } catch {
                    log.error(
                        "could not create store directory \(directory.path) (\(error.localizedDescription)) — the store will refuse mutations"
                    )
                    permissionsUnsecured = true
                }
            } else if !Self.tightenPermissions(of: directory, fm: fm, log: log) {
                permissionsUnsecured = true
            }
        }
        // Same for store files that predate the 0600 discipline — best
        // effort: they are only reachable through the (now owner-only)
        // directory above.
        for file in [metadataURL, payloadURL] where fm.fileExists(atPath: file.path) {
            Self.tightenPermissions(of: file, fm: fm, log: log)
        }

        let loaded = Self.load(metadataURL: metadataURL, payloadURL: payloadURL, log: log)
        configs = loaded.configs
        payloads = loaded.payloads
        quarantineBlocked = loaded.quarantineBlocked || permissionsUnsecured
    }

    /// Static so the actor's nonisolated initializer stays in its
    /// initialization phase (property writes only); a load failure is logged,
    /// quarantined aside, and treated as empty (same posture as
    /// `SecretStore`).
    private static func load(
        metadataURL: URL, payloadURL: URL, log: Logger
    ) -> (configs: [StoredConfig], payloads: [String: Data], quarantineBlocked: Bool) {
        var configs: [StoredConfig] = []
        var payloads: [String: Data] = [:]
        var quarantineBlocked = false
        let fm = FileManager.default

        var configsWasQuarantined = false
        if let data = try? Data(contentsOf: metadataURL),
            let decoded = try? JSONDecoder().decode([StoredConfig].self, from: data)
        {
            configs = decoded
        } else if fm.fileExists(atPath: metadataURL.path) {
            // Back the corrupt file aside before starting empty: the next
            // persist would otherwise overwrite it, destroying the only copy
            // of the data the log message says to fix.
            if !Self.quarantineCorruptFile(at: metadataURL, fm: fm, log: log) {
                quarantineBlocked = true
            }
            configsWasQuarantined = true
        }

        if let data = try? Data(contentsOf: payloadURL),
            let decoded = try? JSONDecoder().decode([String: Data].self, from: data)
        {
            payloads = decoded
        } else if fm.fileExists(atPath: payloadURL.path) {
            if !Self.quarantineCorruptFile(at: payloadURL, fm: fm, log: log) {
                quarantineBlocked = true
            }
        }

        // When the METADATA failed to decode (quarantined above), the
        // payloads on disk may still be perfectly healthy — they are simply
        // unattributable. The orphan prune below and the next persist's
        // payload write would DESTROY them, leaving the quarantined metadata
        // pointing at nothing recoverable. Quarantine the payload file aside
        // as well: the pair stays together for manual recovery, and the
        // store starts clean rather than half-loaded.
        if configsWasQuarantined, fm.fileExists(atPath: payloadURL.path) {
            if !Self.quarantineCorruptFile(at: payloadURL, fm: fm, log: log) {
                quarantineBlocked = true
            }
            payloads = [:]
        }

        // Load-time repair, the read side of persist()'s ordering invariant
        // (see `persist`): an interrupted persist can leave ORPHAN payload
        // entries — a payload written whose metadata never landed — which is
        // unreferenced garbage: prune it. The reverse (metadata referencing a
        // missing payload) cannot be produced by persist's ordering and only
        // arises from a hand-mangled store; keep such records and log loudly
        // rather than silently dropping configs (the payload is served as
        // nil data, never fabricated).
        let referenced = Set(configs.map(\.id))
        let orphans = payloads.keys.filter { !referenced.contains($0) }
        if !orphans.isEmpty {
            log.warning(
                "pruning \(orphans.count) orphaned config payload(s) left behind by an interrupted persist: \(orphans.sorted().joined(separator: ", "))"
            )
            payloads = payloads.filter { referenced.contains($0.key) }
        }
        for config in configs where payloads[config.id] == nil {
            log.error("config \(config.name) (\(config.id)) has no payload on disk — its Data will be served as absent")
        }

        // Crash leftovers: writeJSON's temp files (".configs.json.tmp-<uuid>")
        // from a persist interrupted between temp creation and the swap are
        // unreferenced garbage nothing else removes — sweep them so they
        // cannot accumulate. (The `.corrupt-` quarantine backups are NOT
        // touched: they hold recoverable data.)
        for directory in [metadataURL.deletingLastPathComponent(), payloadURL.deletingLastPathComponent()] {
            guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for entry in contents where entry.hasPrefix(".") && entry.contains(".tmp-") {
                try? fm.removeItem(at: directory.appendingPathComponent(entry))
            }
        }
        return (configs, payloads, quarantineBlocked)
    }

    // MARK: - Mutations

    /// Mutations refuse to run while the store could not be secured at load
    /// time — a corrupt file still sits under its original name (quarantine
    /// move failed), or the store directory could not be verified/tightened
    /// to owner-only: persisting would overwrite the only copy of unreadable
    /// data. Reads keep working; the operator resolves the files and
    /// restarts the daemon.
    private func ensureNotBlocked() throws {
        if quarantineBlocked {
            throw StoreError.quarantineBlocked(
                "the config store could not be secured at load time (unreadable permissions, or a corrupt file could not be moved aside) — resolve the files under "
                    + metadataURL.deletingLastPathComponent().path + " and restart podmd")
        }
    }

    /// Creates a config, returning the stored record. Validation order
    /// mirrors swarmkit's `validateConfigSpec` (moby v28.5.2's pinned
    /// swarmkit `manager/controlapi/config.go`): name → data size; the
    /// name-in-use check happens at store-creation time like swarmkit's
    /// `store.ErrNameConflict`. Throws `persistFailed` when the files cannot
    /// be written (the in-memory state rolls back to the pre-mutation
    /// snapshot, keeping memory a payload-superset of the on-disk metadata).
    @discardableResult
    func create(name: String, data: Data, labels: [String: String]) throws -> StoredConfig {
        // swarmkit's validateConfigOrSecretAnnotations measures len(name) in
        // UTF-8 BYTES (Go len()) and anchors the charset regex at true
        // end-of-string — ICU's `$` would also match before a trailing
        // newline, so \z is used instead (Go's `$` without (?m) is absolute).
        guard !name.isEmpty, name.utf8.count <= 64,
            name.range(of: "^[a-zA-Z0-9]+(?:[a-zA-Z0-9-_.]*[a-zA-Z0-9])?\\z", options: .regularExpression) != nil
        else {
            throw StoreError.invalidName(name)
        }
        guard !data.isEmpty, data.count < Self.maxConfigSize else {
            throw StoreError.dataTooLarge
        }
        // A blocked store (unquarantinable corrupt file) refuses mutations:
        // persisting would overwrite the only copy of unreadable data.
        try ensureNotBlocked()

        // A name equal to another config's ID counts as "in use": moby's
        // getConfig resolves a full-ID match BEFORE a name match, so
        // permitting it would make every later lookup of that name resolve
        // to the other config's record (same precedence the secret store
        // keeps for podman's getExactNameAndID).
        if exactIndex(nameOrID: name) != nil {
            throw StoreError.nameInUse(name)
        }

        // Config name uniqueness is case-INSENSITIVE, matching swarmkit's
        // store: the name index keys are lowercased (`api.ConfigIndexerByName`
        // does strings.ToLower) and `CreateConfig` looks up
        // strings.ToLower(name) — "CaseSensitive" and "casesensitive"
        // conflict (ErrNameConflict → podm's 409). Names are
        // charset-validated ASCII above, so Swift's lowercased() matches
        // Go's strings.ToLower byte-for-byte here. RESOLUTION below stays
        // byte-wise (`sameName`): swarmkit's ByName query is NOT lowercased
        // (raw input vs the lowercase index — a mixed-case lookup misses,
        // a lowercase one hits), an asymmetric quirk podm deliberately does
        // not mirror; exact-spelling lookups keep working instead.
        let lowered = name.lowercased()
        if configs.contains(where: { $0.name.lowercased() == lowered }) {
            throw StoreError.nameInUse(name)
        }

        let now = Date()
        let config = StoredConfig(
            id: Self.generateID(existing: Set(configs.map(\.id))),
            name: name,
            createdAt: now,
            updatedAt: now,
            labels: labels
        )
        // Snapshot-and-restore, taken BEFORE the mutation: with a two-file
        // store, a failed mutation left applied in memory breaks the
        // payload-superset invariant across the NEXT mutation — a failed
        // delete followed by a failed create would write a payload file
        // without the "deleted" config's data while the on-disk metadata
        // still references it (dangling reference; the payload is gone
        // forever). Memory must mirror the last-PERSISTED disk state.
        let savedConfigs = configs
        let savedPayloads = payloads
        configs.append(config)
        payloads[config.id] = data
        do {
            try persist([.payload(payloads), .metadata(configs)])
        } catch {
            configs = savedConfigs
            payloads = savedPayloads
            throw error
        }
        return config
    }

    /// Removes a config by name, ID, or unambiguous ID prefix, returning the
    /// deleted record (nil when nothing matched). Metadata is persisted
    /// BEFORE the payload trim so a crash between the two renames leaves an
    /// orphan payload entry (garbage, pruned on load), never metadata
    /// referencing a deleted payload.
    @discardableResult
    func remove(nameOrID: String) throws -> StoredConfig? {
        guard let config = lookup(nameOrID: nameOrID),
            let index = configs.firstIndex(where: { $0.id == config.id })
        else { return nil }
        return try remove(at: index, loggingAs: nameOrID)
    }

    /// Removes a config by EXACT full ID — no name fallback, no prefix
    /// resolution. The docker DELETE route resolves name/prefix → full ID
    /// from a snapshot, then removes by that ID: between the snapshot and
    /// this actor hop a concurrent remove+create can mint a NEW config
    /// whose NAME equals the old ID (charset-legal once the ID is free),
    /// and `remove(nameOrID:)`'s name fallback would delete that unrelated
    /// config. ID-exact removal turns the lost race into a nil (the route's
    /// 404), never a misfire.
    @discardableResult
    func remove(id: String) throws -> StoredConfig? {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return nil }
        return try remove(at: index, loggingAs: id)
    }

    /// Shared mutation body for both removal entry points. Snapshot BEFORE
    /// mutating, same rationale as create(): a failed remove left applied
    /// in memory would let the next mutation's payload write drop data the
    /// on-disk metadata still references.
    private func remove(at index: Int, loggingAs nameOrID: String) throws -> StoredConfig? {
        // The caller's nil lookup still works on a blocked store; the
        // mutation does not — persisting would overwrite the only copy of
        // the unreadable file.
        try ensureNotBlocked()
        let savedConfigs = configs
        let savedPayloads = payloads
        let removed = configs.remove(at: index)
        payloads.removeValue(forKey: removed.id)
        do {
            try persist([.metadata(configs), .payload(payloads)])
        } catch {
            if let storeError = error as? StoreError,
                case .persistFailed(_, let writeIndex) = storeError, writeIndex >= 1
            {
                // Only the payload TRIM failed — the deletion already
                // committed to the metadata on disk, so restoring the config
                // in memory would disagree with disk: a restart loses it
                // while the next successful mutation writes it back
                // (resurrection). The deletion stands and is REPORTED as the
                // success it is: the un-trimmed payload entry is an orphan
                // that load prunes, and answering 500 would make the client
                // retry a delete that already happened (404).
                log.warning(
                    "remove of \(nameOrID) committed but the payload could not be trimmed (\(storeError)) — the stale entry is pruned on the next load"
                )
                return removed
            }
            // The metadata write failed — nothing committed, so memory keeps
            // mirroring disk: the config stays, fully retryable.
            configs = savedConfigs
            payloads = savedPayloads
            throw error
        }
        return removed
    }

    // MARK: - Queries

    func list() -> [StoredConfig] {
        configs
    }

    /// Metadata AND payloads in ONE actor hop, so a concurrent remove can
    /// never be interleaved between the two reads and pair fresh metadata
    /// with a stale payload or vice versa. Configs are served WITH their
    /// data (moby parity — nothing strips config Data on the read path).
    func listWithPayloads() -> [StoredConfigWithPayload] {
        configs.map { StoredConfigWithPayload(config: $0, data: payloads[$0.id]) }
    }

    /// Exact name or full ID first, then an unambiguous ID prefix — mirroring
    /// moby's `getConfig` precedence (full ID before full name; swarmkit
    /// `store.ByName` / `ByIDPrefix`). An exact FULL-ID match always wins
    /// over a name match. An ambiguous prefix resolves to nothing (the
    /// route surfaces it as moby's 400).
    func lookup(nameOrID: String) -> StoredConfig? {
        if let index = exactIndex(nameOrID: nameOrID) {
            return configs[index]
        }
        // ID prefix: only references no longer than an ID can be prefixes,
        // and only when unambiguous.
        guard !nameOrID.isEmpty, nameOrID.count <= Self.configIDLength else { return nil }
        let prefixMatches = configs.filter { $0.id.hasPrefix(nameOrID) }
        return prefixMatches.count == 1 ? prefixMatches[0] : nil
    }

    /// Index of the config matching `nameOrID` exactly — full ID first, then
    /// exact name — mirroring moby's getConfig precedence. Names compare by
    /// UTF-8 BYTES, not Swift's `==`: Go string equality is byte-wise, so
    /// "café" in NFC and NFD are two DISTINCT configs — canonical-equivalence
    /// matching would collide them into a name-in-use 409.
    private func exactIndex(nameOrID: String) -> Int? {
        if let byID = configs.firstIndex(where: { $0.id == nameOrID }) {
            return byID
        }
        return configs.firstIndex(where: { Self.sameName($0.name, nameOrID) })
    }

    /// Go's string equality: byte-for-byte UTF-8, with no Unicode
    /// canonical-equivalence folding.
    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// Metadata plus payload in ONE actor hop, so a concurrent remove can
    /// never interleave between the two reads (the docker inspect path —
    /// config Data is part of the reply, unlike secrets).
    func inspect(nameOrID: String) -> StoredConfigWithPayload? {
        guard let config = lookup(nameOrID: nameOrID) else { return nil }
        return StoredConfigWithPayload(config: config, data: payloads[config.id])
    }

    /// The raw payload for a known ID. `inspect(nameOrID:)` is the
    /// API-facing read path; this exists for direct/testing access.
    func payload(id: String) -> Data? {
        payloads[id]
    }

    // MARK: - Persistence

    /// One ordered file write in a persistence sequence.
    private enum PersistWrite {
        case payload([String: Data])
        case metadata([StoredConfig])
    }

    /// Rewrites the store's files in the given order, THROWING on the first
    /// failure (`persistFailed`) so callers surface a 500 instead of
    /// acknowledging a create that would vanish on restart. A mid-sequence
    /// failure may leave earlier writes on disk; callers roll memory back to
    /// the pre-mutation state, keeping memory a payload-superset of whatever
    /// the on-disk metadata references. On restart, `load` repairs whatever
    /// the interrupted sequence left behind.
    ///
    /// Ordering invariant — why the payload file always lands first as a
    /// SUPERSET of the IDs the incoming metadata references, and is only
    /// trimmed after that metadata has landed: a PROCESS CRASH between
    /// renames must only ever leave ORPHAN payload entries (unreferenced
    /// garbage, pruned by `load`), never metadata referencing a payload that
    /// is not on disk (a config that inspects fine but whose Data is gone —
    /// corruption). (Across a POWER LOSS this invariant is best-effort: it
    /// relies on writeJSON's flush ordering, which is only as strong as the
    /// filesystem's flush semantics — see writeJSON's durability notes.)
    /// Hence per mutation:
    ///
    ///   - create: payload(final) → metadata(final)
    ///   - remove: metadata(final) → payload(final)
    private func persist(_ writes: [PersistWrite]) throws {
        for (index, write) in writes.enumerated() {
            do {
                switch write {
                case .payload(let payloads):
                    try Self.writeJSON(payloads, to: payloadURL, log: log, fullSync: fullSync)
                case .metadata(let configs):
                    try Self.writeJSON(configs, to: metadataURL, log: log, fullSync: fullSync)
                }
            } catch {
                throw StoreError.persistFailed(reason: "\(error)", writeIndex: index)
            }
        }
    }

    /// Encodes and atomically replaces one store file, 0600 from the start.
    ///
    /// Failure ordering contract: this function only THROWS before the data
    /// swap commits (temp creation, sync, replace/move). Once the swap has
    /// landed the file's new contents survive a process crash outright.
    /// Across a POWER LOSS the ordering is BEST-EFFORT, and reads as follows
    /// while every flush succeeds: the temp's data is flushed BEFORE the
    /// swap (fsync upgraded to F_FULLFSYNC — on macOS a plain fsync only
    /// reaches the drive's cache) and the containing directory after
    /// (post-commit, logged on failure, never thrown). The data therefore
    /// cannot be ordered behind the rename that publishes it, which is what
    /// keeps metadata from referencing a payload that never reached the disk
    /// (persist's ordering invariant). Guarantee boundary: a FAILED data
    /// flush before the swap throws (pre-commit); a failed DIRECTORY flush
    /// after it is logged and later writes proceed — the affected rename's
    /// durability stays unestablished, an availability-over-paranoia trade
    /// for a local daemon. When F_FULLFSYNC is unsupported on the filesystem
    /// (ENOTSUP/EINVAL) the fallback is plain fsync. The residual risk is
    /// the platform's own flush semantics — no stronger primitive is
    /// available on macOS. Callers' rollback logic cannot tell a failed
    /// write from a committed one, and rolling back after a committed
    /// metadata write would let a later mutation discard payloads the
    /// on-disk metadata still references. `replaceItemAt` (verified
    /// empirically in the secret store) preserves the DESTINATION's mode,
    /// not the temp's — the destination is guaranteed owner-only by init's
    /// tightening — so the post-swap mode re-assertion is belt-and-braces
    /// and only logs.
    private static func writeJSON<T: Encodable>(
        _ value: T, to url: URL, log: Logger, fullSync: @Sendable (Int32) -> Int32
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard
            FileManager.default.createFile(
                atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Durability, part 1 (pre-commit, may throw): flush the data to the
        // disk BEFORE the rename that publishes it — renames are atomic but
        // not ordered against data writes, so without this the OS could
        // persist the metadata rename while the payload data is still in
        // cache, and a power loss would leave metadata referencing payloads
        // that never landed. F_FULLFSYNC reaches past the drive cache where
        // plain fsync (already done by synchronize()) does not. An
        // UNSUPPORTED flush (ENOTSUP/EINVAL — not every filesystem
        // implements it) falls back to the fsync above; any OTHER failure is
        // a real flush failure, is pre-commit, and THROWS: the swap must not
        // publish data that was never flushed.
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.synchronize()
            if fullSync(handle.fileDescriptor) != 0, errno != ENOTSUP, errno != EINVAL {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        // Durability, part 2 (post-commit, best-effort and LOGGED — see the
        // failure ordering contract): flush the directory entry so the
        // publishing rename itself reaches the disk. Never throws: the swap
        // already committed.
        let directory = url.deletingLastPathComponent()
        let dirFD = open(directory.path, O_RDONLY)
        if dirFD >= 0 {
            let synced = fcntl(dirFD, F_FULLFSYNC, 0) == 0 || fsync(dirFD) == 0
            close(dirFD)
            if !synced {
                log.warning(
                    "store directory \(directory.path) could not be synced after committing \(url.lastPathComponent) — the rename may not survive a power loss"
                )
            }
        } else {
            log.warning(
                "could not open store directory \(directory.path) for syncing after committing \(url.lastPathComponent) — the rename may not survive a power loss"
            )
        }
        // A same-directory swap may leave the temp behind holding the old
        // data; either way it must not linger.
        try? FileManager.default.removeItem(at: temp)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // The data swap already committed — never throw from here (see
            // the failure ordering contract above). The mode was secured
            // before the swap; this is a logged anomaly.
            log.warning(
                "store file \(url.path) committed but its mode could not be re-asserted (\(error.localizedDescription))"
            )
        }
    }

    /// Strips group/other access bits from an existing file or directory,
    /// reporting whether the item is verifiably owner-only afterwards.
    /// Only bits are cleared, never set, so a deliberately read-only item
    /// keeps its owner bits — this closes replacement/deletion of store
    /// files by other local users (directory write permission) without
    /// fighting an operator's intentional modes. False means the item's
    /// mode could not be inspected or secured: the caller must refuse
    /// mutations rather than expose the store to other local users.
    @discardableResult
    private static func tightenPermissions(of url: URL, fm: FileManager, log: Logger) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        else {
            log.error("could not inspect permissions of \(url.path) — treating the store as unsecured")
            return false
        }
        guard perms & 0o077 != 0 else { return true }
        do {
            try fm.setAttributes([.posixPermissions: perms & ~0o077], ofItemAtPath: url.path)
            return true
        } catch {
            log.error(
                "could not tighten permissions of \(url.path) (\(error.localizedDescription)) — other local users may reach the store; refusing mutations"
            )
            return false
        }
    }

    /// 25 lowercase hex characters — same shape class as swarmkit's
    /// `identity.NewID()` (25-char base36). Collision with an existing ID is
    /// astronomically unlikely (25 hex ≈ 100 bits) but checked anyway.
    private static func generateID(existing: Set<String> = []) -> String {
        var rng = SystemRandomNumberGenerator()
        while true {
            let hex = (0..<4).map { _ in String(format: "%016llx", rng.next()) }.joined()
            let id = String(hex.prefix(configIDLength))
            if !existing.contains(id) {
                return id
            }
        }
    }

    /// Renames an undecodable store file aside (`.corrupt-<timestamp>`)
    /// instead of leaving it in place: the next persist overwrites the
    /// original name, and without the quarantine that would destroy the
    /// only copy of whatever the user was told to fix. Returns false when
    /// the move itself failed — the caller records a blocked state and
    /// refuses to persist over the unreadable file.
    @discardableResult
    private static func quarantineCorruptFile(at url: URL, fm: FileManager, log: Logger) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.appendingPathExtension("corrupt-\(stamp)")
        do {
            try fm.moveItem(at: url, to: backup)
            // Owner-only regardless of the modes the corrupt file carried.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            log.error(
                "could not load store file \(url.path) — moved aside as \(backup.lastPathComponent); starting empty. The file remains available for manual recovery."
            )
            return true
        } catch {
            log.error(
                "could not load store file \(url.path) and could not move it aside (\(error.localizedDescription)) — it will NOT be overwritten: mutations are refused until it is resolved and the daemon restarted"
            )
            return false
        }
    }
}
