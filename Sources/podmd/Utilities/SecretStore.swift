// SPDX-License-Identifier: Apache-2.0
import Foundation
import Logging

/// One secret in the local store — metadata only. The payload never leaves
/// `SecretStore`'s payload file; the API surface returns `StoredSecret` (or a
/// DTO derived from it), never the bytes, except the explicit
/// `showsecret`/`--showsecret` inspect path.
struct StoredSecret: Codable, Sendable, Equatable {
    /// Podman-shaped secret ID: 25 lowercase hex characters
    /// (`common/pkg/secrets` `secretIDLength`, from a 64-char
    /// `GenerateNonCryptoID` truncated). `var` because podman's replace path
    /// re-stores the secret under a fresh ID.
    var id: String
    let name: String
    let createdAt: Date
    var updatedAt: Date
    var labels: [String: String]
    /// Always "file" — the only driver podm implements (podman's default).
    var driver: String
    var driverOptions: [String: String]
}

/// Podman's local secret store (`podman secret create/ls/inspect/rm`), backed
/// by files under the app-support directory, modeled on the
/// sidecar-persistence precedent of `RestartPolicyOverrideStore`:
///
/// - `<storageDirectory>/podm-secrets/secrets.json` — the metadata DB
///   (podman's `secrets.json`),
/// - `<storageDirectory>/podm-secrets/filedriver/secretsdata.json` — the
///   payloads keyed by ID, mirroring podman's file driver layout, written with
///   0600 permissions so only the daemon's user can read secret data.
///
/// An actor because route handlers hit it concurrently; persistence rewrites
/// both files atomically per mutation under a strict write ORDER (payload
/// superset first, metadata second, payload trim last — see `persist`) so a
/// crash between renames can only ever leave orphan payload entries, never
/// metadata referencing payloads that aren't there.
///
/// Semantics follow `go.podman.io/common/pkg/secrets` (SecretsManager.Store /
/// Delete / Lookup): names are validated (1–253 UTF-8 bytes, no `,` `/` `=`
/// or NUL — Go's len() and ContainsAny semantics), data must be
/// 1..<512000 bytes, `replace` deletes and re-stores under a fresh ID,
/// `ignore` returns the existing secret's ID, and both together are an
/// error. Lookup accepts an exact name OR exact ID (ID first), never a
/// prefix except an unambiguous ID prefix.
actor SecretStore {
    enum StoreError: Error, Equatable {
        /// `errInvalidSecretName`
        case invalidName(String)
        /// `errDataSize` — podman: "secret data must be larger than 0 and less than 512000 bytes"
        case dataTooLarge
        /// `errIgnoreIfExistsAndReplace`
        case ignoreAndReplace
        /// `errSecretNameInUse`
        case nameInUse(String)
        /// Only the "file" driver exists here (podman also has "pass" etc.).
        case unsupportedDriver(String)
        /// A `persist()` write failed — `writeIndex` is the 0-based position
        /// of the failed write in the mutation's persist sequence, so callers
        /// can tell "nothing committed" (early writes) from "the final state
        /// already landed" (late writes) when deciding what to roll back.
        /// Podman propagates its driver and db write errors to the caller the
        /// same way (`SecretsManager.Store` wraps both as "creating secret
        /// %s: %w"); the route answers 500.
        case persistFailed(reason: String, writeIndex: Int)
        /// The store could not be secured at load time — a corrupt file
        /// could not be quarantined aside (its directory was not writable),
        /// or a store directory's permissions could not be verified or
        /// tightened to owner-only. Either way the unreadable/insecure data
        /// still sits where the next persist would touch it: mutations are
        /// REFUSED rather than persisting over the only copy or exposing
        /// secret material to other local users; the operator resolves the
        /// files and restarts the daemon.
        case quarantineBlocked(String)
    }

    /// `common/pkg/secrets` `maxSecretSize` — 512kB.
    static let maxSecretSize = 512_000
    /// `common/pkg/secrets` `secretIDLength` — 25.
    static let secretIDLength = 25

    /// In insertion order — podman's `secret ls` output order for the local
    /// driver follows DB iteration; array order keeps it stable and oldest-first.
    private var secrets: [StoredSecret] = []
    /// id → payload. Kept in step with `secrets` on every mutation.
    private var payloads: [String: Data] = [:]
    private let metadataURL: URL
    private let payloadURL: URL
    private let log: Logger
    /// True when a corrupt store file could not be moved aside at load time
    /// — the next persist would overwrite the only copy of unreadable data.
    /// Set once at init; cleared by fixing the files and restarting.
    private let quarantineBlocked: Bool

    /// Loads (or initializes) the store under `storageDirectory`. Missing
    /// files are not an error — the store simply starts empty and writes both
    /// files on first mutation. Corrupt files are logged and treated as empty
    /// (same posture as `RestartPolicyOverrideStore`): a hand-mangled store
    /// loses its secrets rather than taking the daemon down.
    init(storageDirectory: URL, logger: Logger = Logger(label: "podm.secrets")) {
        let dir = storageDirectory.appendingPathComponent("podm-secrets", isDirectory: true)
        let filedriverDir = dir.appendingPathComponent("filedriver", isDirectory: true)
        metadataURL = dir.appendingPathComponent("secrets.json")
        payloadURL = filedriverDir.appendingPathComponent("secretsdata.json")
        log = logger

        // Restrictive permissions from the start: 0700 dirs (readable/traversable
        // only by the daemon's user), so payloads can never be world-readable
        // even between init and first write. Pre-existing directories are
        // TIGHTENED, not trusted: write permission on the directory is what
        // lets another local user replace or delete the store files, and a
        // directory left behind by an older build or a restored backup can
        // carry group/world bits. Only bits are cleared, never set — a
        // deliberately read-only directory keeps its owner bits. A directory
        // that cannot be inspected or secured BLOCKS the store: proceeding
        // would expose secret material to other local users.
        var permissionsUnsecured = false
        let fm = FileManager.default
        for directory in [dir, filedriverDir] {
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
        // directories above.
        for file in [metadataURL, payloadURL] where fm.fileExists(atPath: file.path) {
            Self.tightenPermissions(of: file, fm: fm, log: log)
        }

        let loaded = Self.load(metadataURL: metadataURL, payloadURL: payloadURL, log: log)
        secrets = loaded.secrets
        payloads = loaded.payloads
        quarantineBlocked = loaded.quarantineBlocked || permissionsUnsecured
    }

    /// Static so the actor's nonisolated initializer stays in its
    /// initialization phase (property writes only); a load failure is logged
    /// and treated as empty (same posture as `RestartPolicyOverrideStore`): a
    /// hand-mangled store loses its secrets rather than taking the daemon down.
    private static func load(
        metadataURL: URL, payloadURL: URL, log: Logger
    ) -> (secrets: [StoredSecret], payloads: [String: Data], quarantineBlocked: Bool) {
        var secrets: [StoredSecret] = []
        var payloads: [String: Data] = [:]
        var quarantineBlocked = false
        let fm = FileManager.default

        var secretsWasQuarantined = false
        if let data = try? Data(contentsOf: metadataURL),
            let decoded = try? JSONDecoder().decode([StoredSecret].self, from: data)
        {
            secrets = decoded
        } else if fm.fileExists(atPath: metadataURL.path) {
            // Back the corrupt file aside before starting empty: the next
            // persist would otherwise overwrite it, destroying the only copy
            // of the data the log message says to fix.
            if !Self.quarantineCorruptFile(at: metadataURL, fm: fm, log: log) {
                quarantineBlocked = true
            }
            secretsWasQuarantined = true
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
        if secretsWasQuarantined, fm.fileExists(atPath: payloadURL.path) {
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
        // arises from a hand-mangled store; podman keeps such records too
        // (its driver.Lookup fails while ls/inspect still answer), so keep
        // them and log loudly rather than silently dropping secrets.
        let referenced = Set(secrets.map(\.id))
        let orphans = payloads.keys.filter { !referenced.contains($0) }
        if !orphans.isEmpty {
            log.warning(
                "pruning \(orphans.count) orphaned secret payload(s) left behind by an interrupted persist: \(orphans.sorted().joined(separator: ", "))"
            )
            payloads = payloads.filter { referenced.contains($0.key) }
        }
        for secret in secrets where payloads[secret.id] == nil {
            log.error("secret \(secret.name) (\(secret.id)) has no payload on disk — --showsecret will return no data")
        }
        return (secrets, payloads, quarantineBlocked)
    }

    // MARK: - Mutations

    /// Mutations refuse to run while the store could not be secured at load
    /// time — a corrupt file still sits under its original name (quarantine
    /// move failed), or a store directory could not be verified/tightened
    /// to owner-only: persisting would overwrite the only copy of
    /// unreadable data or expose secret material to other local users.
    /// Reads keep working; the operator resolves the files and restarts
    /// the daemon.
    private func ensureNotBlocked() throws {
        if quarantineBlocked {
            throw StoreError.quarantineBlocked(
                "the secret store could not be secured at load time (unreadable permissions, or a corrupt file could not be moved aside) — resolve the files under "
                    + metadataURL.deletingLastPathComponent().path + " and restart podmd")
        }
    }

    /// Creates (or replaces) a secret, returning the stored record. Mirrors
    /// `SecretsManager.Store` including its validation order, so error
    /// precedence matches podman: name → data size → ignore+replace →
    /// name-in-use. Throws `persistFailed` when the files cannot be written
    /// (the in-memory state rolls back to the pre-mutation snapshot, keeping
    /// memory a payload-superset of the on-disk metadata).
    @discardableResult
    func create(
        name: String,
        data: Data,
        driver: String?,
        labels: [String: String],
        driverOptions: [String: String],
        replace: Bool,
        ignore: Bool
    ) throws -> StoredSecret {
        // Go's validateSecretName measures len(name) in UTF-8 BYTES (127
        // "é" are 254 of them) and scans forbidden characters over unicode
        // SCALARS — a combining mark after '/' would fuse into one Swift
        // grapheme cluster and slip past a Character-based check.
        guard !name.isEmpty, name.utf8.count <= 253,
            !name.unicodeScalars.contains(where: Self.forbiddenNameScalars.contains)
        else {
            throw StoreError.invalidName(name)
        }
        guard !data.isEmpty, data.count < Self.maxSecretSize else {
            throw StoreError.dataTooLarge
        }
        guard !(ignore && replace) else {
            throw StoreError.ignoreAndReplace
        }

        let resolvedDriver = driver ?? "file"
        guard resolvedDriver == "file" else {
            throw StoreError.unsupportedDriver(resolvedDriver)
        }
        // A blocked store (unquarantinable corrupt file) refuses mutations:
        // persisting would overwrite the only copy of unreadable data.
        try ensureNotBlocked()

        // Podman's exactSecretExists → getExactNameAndID resolves an exact
        // FULL-ID match before a name match (IDToName is consulted before
        // NameToID), so a name equal to another secret's ID counts as
        // "in use" — permitting it would make every later lookup of that
        // name resolve to the other secret's record.
        if let index = exactIndex(nameOrID: name) {
            guard replace || ignore else {
                throw StoreError.nameInUse(name)
            }
            if ignore {
                // Podman: return the existing secret untouched.
                return secrets[index]
            }
            // Replace: fresh ID, fresh timestamps-of-update, payload
            // re-stored under the new ID. The transitional payload write
            // below keeps the OLD entry on disk while the metadata still
            // references it; the trim removes it only after the metadata
            // has landed (persist's ordering invariant).
            var replacement = secrets[index]
            let oldID = replacement.id
            let oldPayload = payloads[oldID]
            replacement.id = Self.generateID(existing: Set(secrets.map(\.id)))
            replacement.updatedAt = Date()
            replacement.labels = labels
            replacement.driverOptions = driverOptions
            replacement.driver = resolvedDriver
            let savedSecrets = secrets
            let savedPayloads = payloads
            secrets[index] = replacement
            payloads.removeValue(forKey: oldID)
            payloads[replacement.id] = data
            var transitional = payloads
            if let oldPayload {
                transitional[oldID] = oldPayload
            }
            do {
                try persist([.payload(transitional), .metadata(secrets), .payload(payloads)])
            } catch {
                if let storeError = error as? StoreError,
                    case .persistFailed(_, let writeIndex) = storeError, writeIndex >= 2
                {
                    // Only the final payload TRIM failed — the replacement
                    // metadata has already committed, so the pre-replacement
                    // state is no longer recoverable (its metadata is gone
                    // from disk). The replacement stands and is REPORTED as
                    // the success it is: the un-trimmed old-ID payload is an
                    // orphan that load prunes, and answering 500 would make
                    // the client retry a create that already happened.
                    log.warning(
                        "replace of \(name) committed but the old payload could not be trimmed (\(storeError)) — the stale entry is pruned on the next load"
                    )
                    return replacement
                }
                // An early write failed — disk still describes the OLD
                // secret, so memory must too: keeping the replacement in
                // memory would let the next mutation's payload write drop
                // the old payload while the on-disk metadata still
                // references it (dangling reference, data lost forever).
                secrets = savedSecrets
                payloads = savedPayloads
                throw error
            }
            return replacement
        }

        let now = Date()
        let secret = StoredSecret(
            id: Self.generateID(existing: Set(secrets.map(\.id))),
            name: name,
            createdAt: now,
            updatedAt: now,
            labels: labels,
            driver: resolvedDriver,
            driverOptions: driverOptions
        )
        // Snapshot-and-restore, taken BEFORE the mutation: with a two-file
        // store, a failed mutation left in memory breaks the payload-superset
        // invariant across the NEXT mutation — a failed delete followed by a
        // failed create would write a payload file without the "deleted"
        // secret's data while the on-disk metadata still references it
        // (dangling reference; the payload is gone forever). Memory must
        // mirror the last-PERSISTED disk state. Podman can keep its mutated
        // db cache because its store is one file; we cannot.
        let savedSecrets = secrets
        let savedPayloads = payloads
        secrets.append(secret)
        payloads[secret.id] = data
        do {
            try persist([.payload(payloads), .metadata(secrets)])
        } catch {
            secrets = savedSecrets
            payloads = savedPayloads
            throw error
        }
        return secret
    }

    /// Removes a secret by name, ID, or unambiguous ID prefix, returning the
    /// deleted record (nil when nothing matched — podman's `ErrNoSuchSecret`).
    /// Metadata is persisted BEFORE the payload trim so a crash between the
    /// two renames leaves an orphan payload entry (garbage, pruned on load),
    /// never metadata referencing a deleted payload.
    @discardableResult
    func remove(nameOrID: String) throws -> StoredSecret? {
        guard let secret = lookup(nameOrID: nameOrID),
            let index = secrets.firstIndex(where: { $0.id == secret.id })
        else { return nil }
        // Reads (the 404 above) still work on a blocked store; the
        // mutation does not — persisting would overwrite the only copy of
        // the unreadable file.
        try ensureNotBlocked()
        // Snapshot BEFORE mutating, same rationale as create(): a failed
        // remove left applied in memory would let the next mutation's
        // payload write drop data the on-disk metadata still references.
        let savedSecrets = secrets
        let savedPayloads = payloads
        let removed = secrets.remove(at: index)
        payloads.removeValue(forKey: removed.id)
        do {
            try persist([.metadata(secrets), .payload(payloads)])
        } catch {
            if let storeError = error as? StoreError,
                case .persistFailed(_, let writeIndex) = storeError, writeIndex >= 1
            {
                // Only the payload TRIM failed — the deletion already
                // committed to the metadata on disk, so restoring the
                // secret in memory would disagree with disk: a restart
                // loses it while the next successful mutation writes it
                // back (resurrection). The deletion stands and is REPORTED
                // as the success it is: the un-trimmed payload entry is an
                // orphan that load prunes, and answering 500 would make the
                // client retry a delete that already happened (404).
                log.warning(
                    "remove of \(nameOrID) committed but the payload could not be trimmed (\(storeError)) — the stale entry is pruned on the next load"
                )
                return removed
            }
            // The metadata write failed — nothing committed, so memory
            // keeps mirroring disk: the secret stays, fully retryable.
            secrets = savedSecrets
            payloads = savedPayloads
            throw error
        }
        return removed
    }

    // MARK: - Queries

    func list() -> [StoredSecret] {
        secrets
    }

    /// Exact name or full ID first, then an unambiguous ID prefix — podman's
    /// `SecretsManager.Lookup` / `secretsdb.getNameAndID`. An exact FULL-ID
    /// match always wins over a name match (podman consults IDToName before
    /// NameToID). An ambiguous prefix resolves to nothing (podman answers an
    /// explicit error there; callers surface it as not-found).
    func lookup(nameOrID: String) -> StoredSecret? {
        if let index = exactIndex(nameOrID: nameOrID) {
            return secrets[index]
        }
        // ID prefix (podman getNameAndID): only references no longer than an
        // ID can be prefixes, and only when unambiguous.
        guard !nameOrID.isEmpty, nameOrID.count <= Self.secretIDLength else { return nil }
        let prefixMatches = secrets.filter { $0.id.hasPrefix(nameOrID) }
        return prefixMatches.count == 1 ? prefixMatches[0] : nil
    }

    /// Index of the secret matching `nameOrID` exactly — full ID first, then
    /// exact name — mirroring podman's `getExactNameAndID` precedence.
    private func exactIndex(nameOrID: String) -> Int? {
        if let byID = secrets.firstIndex(where: { $0.id == nameOrID }) {
            return byID
        }
        return secrets.firstIndex(where: { $0.name == nameOrID })
    }

    /// Metadata plus (optionally) the payload in ONE actor hop, so a
    /// concurrent replace/remove can never be interleaved between the two
    /// reads and pair fresh metadata with a stale payload or vice versa
    /// (podman holds its lockfile across `LookupSecretData` the same way).
    /// The only path that hands a payload to a caller.
    func inspect(nameOrID: String, showSecret: Bool) -> (secret: StoredSecret, payload: Data?)? {
        guard let secret = lookup(nameOrID: nameOrID) else { return nil }
        return (secret, showSecret ? payloads[secret.id] : nil)
    }

    /// The raw payload for a known ID. `inspect(nameOrID:showSecret:)` is
    /// the API-facing read path; this exists for direct/testing access.
    func payload(id: String) -> Data? {
        payloads[id]
    }

    // MARK: - Persistence

    /// One ordered file write in a persistence sequence.
    private enum PersistWrite {
        case payload([String: Data])
        case metadata([StoredSecret])
    }

    /// Forbidden secret-name characters as unicode scalars (Go's
    /// `strings.ContainsAny(name, ",/=\000")` walks code points, not
    /// grapheme clusters).
    private static let forbiddenNameScalars: Set<Unicode.Scalar> = Set(",/=\0".unicodeScalars)

    /// Rewrites the store's files in the given order, THROWING on the first
    /// failure (`persistFailed`) so callers surface a 500 instead of
    /// acknowledging a create that would vanish on restart — podman
    /// propagates its driver.Store and db write errors the same way
    /// ("creating secret %s: %w"). A mid-sequence failure may leave earlier
    /// writes on disk; callers roll memory back to the pre-mutation state
    /// (except where a late write already committed the new metadata — see
    /// the replace branch), keeping memory a payload-superset of whatever
    /// the on-disk metadata references. On restart, `load` repairs whatever
    /// the interrupted sequence left behind.
    ///
    /// Ordering invariant — why the payload file always lands first as a
    /// SUPERSET of the IDs the incoming metadata references, and is only
    /// trimmed after that metadata has landed: a crash between renames must
    /// only ever leave ORPHAN payload entries (unreferenced garbage, pruned
    /// by `load`), never metadata referencing a payload that is not on disk
    /// (a secret that inspects fine but whose --showsecret data is gone —
    /// corruption). Hence per mutation:
    ///
    ///   - create (new secret): payload(final) → metadata(final)
    ///   - remove: metadata(final) → payload(final)
    ///   - replace: payload(old ∪ new) → metadata(final) → payload(final)
    ///
    /// Podman's own write order is payload-before-metadata too
    /// (`driver.Store` before the db rewrite) but pays a dangling-reference
    /// window on deletes/replace (driver.Delete runs first); the
    /// superset-first scheme closes that as well.
    private func persist(_ writes: [PersistWrite]) throws {
        for (index, write) in writes.enumerated() {
            do {
                switch write {
                case .payload(let payloads):
                    try Self.writeJSON(payloads, to: payloadURL, log: log)
                case .metadata(let secrets):
                    try Self.writeJSON(secrets, to: metadataURL, log: log)
                }
            } catch {
                throw StoreError.persistFailed(reason: "\(error)", writeIndex: index)
            }
        }
    }

    /// Encodes and atomically replaces one store file. Payloads get 0600
    /// (podman's file driver `os.WriteFile(..., 0o600)`); metadata follows
    /// suit — labels aren't secret, but there's no reason for them to be
    /// readable either. The temp file is created 0600 FROM THE START:
    /// `data.write(options: .atomic)` would create it with the process
    /// umask (typically 0644), leaving a world-readable window.
    ///
    /// Failure ordering contract: this function only THROWS before the data
    /// swap commits (temp creation, replace/move). Once the swap has landed
    /// the file's new contents are durable, and a post-commit failure must
    /// not surface as an error — the callers' rollback logic cannot tell a
    /// failed write from a committed one, and rolling back after a
    /// committed metadata write would let a later mutation discard payloads
    /// the on-disk metadata still references. `replaceItemAt` (verified
    /// empirically) preserves the DESTINATION's mode, not the temp's — the
    /// destination is guaranteed owner-only by init's tightening — so the
    /// post-swap mode re-assertion is belt-and-braces and only logs.
    private static func writeJSON<T: Encodable>(_ value: T, to url: URL, log: Logger) throws {
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
    /// mutations rather than expose secret material.
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

    /// 25 lowercase hex characters — `stringid.GenerateNonCryptoID()` truncated
    /// to `secretIDLength` in podman. Collision with an existing ID is
    /// astronomically unlikely (25 hex ≈ 100 bits) but checked anyway, matching
    /// podman's retry loop.
    private static func generateID(existing: Set<String> = []) -> String {
        var rng = SystemRandomNumberGenerator()
        while true {
            let hex = (0..<4).map { _ in String(format: "%016llx", rng.next()) }.joined()
            let id = String(hex.prefix(secretIDLength))
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
            // The backup holds secret payloads — owner-only, regardless of
            // the modes the corrupt file carried.
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
