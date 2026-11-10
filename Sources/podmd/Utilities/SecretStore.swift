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
        /// A `persist()` write failed — the mutation is live in memory but
        /// will not survive a restart. Podman propagates its driver and db
        /// write errors to the caller the same way (`SecretsManager.Store`
        /// wraps both as "creating secret %s: %w"); the route answers 500.
        case persistFailed(String)
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
        // even between init and first write.
        let fm = FileManager.default
        for directory in [dir, filedriverDir] where !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        let loaded = Self.load(metadataURL: metadataURL, payloadURL: payloadURL, log: log)
        secrets = loaded.secrets
        payloads = loaded.payloads
    }

    /// Static so the actor's nonisolated initializer stays in its
    /// initialization phase (property writes only); a load failure is logged
    /// and treated as empty (same posture as `RestartPolicyOverrideStore`): a
    /// hand-mangled store loses its secrets rather than taking the daemon down.
    private static func load(metadataURL: URL, payloadURL: URL, log: Logger) -> (secrets: [StoredSecret], payloads: [String: Data]) {
        var secrets: [StoredSecret] = []
        var payloads: [String: Data] = [:]
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
            Self.quarantineCorruptFile(at: metadataURL, fm: fm, log: log)
            secretsWasQuarantined = true
        }

        if let data = try? Data(contentsOf: payloadURL),
            let decoded = try? JSONDecoder().decode([String: Data].self, from: data)
        {
            payloads = decoded
        } else if fm.fileExists(atPath: payloadURL.path) {
            Self.quarantineCorruptFile(at: payloadURL, fm: fm, log: log)
        }

        // When the METADATA failed to decode (quarantined above), the
        // payloads on disk may still be perfectly healthy — they are simply
        // unattributable. The orphan prune below and the next persist's
        // payload write would DESTROY them, leaving the quarantined metadata
        // pointing at nothing recoverable. Quarantine the payload file aside
        // as well: the pair stays together for manual recovery, and the
        // store starts clean rather than half-loaded.
        if secretsWasQuarantined, fm.fileExists(atPath: payloadURL.path) {
            Self.quarantineCorruptFile(at: payloadURL, fm: fm, log: log)
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
        return (secrets, payloads)
    }

    // MARK: - Mutations

    /// Creates (or replaces) a secret, returning the stored record. Mirrors
    /// `SecretsManager.Store` including its validation order, so error
    /// precedence matches podman: name → data size → ignore+replace →
    /// name-in-use. Throws `persistFailed` when the files cannot be written
    /// (the in-memory mutation stands, like podman's mutated db cache, and
    /// the next successful mutation re-syncs both files).
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
            secrets[index] = replacement
            payloads.removeValue(forKey: oldID)
            payloads[replacement.id] = data
            var transitional = payloads
            if let oldPayload {
                transitional[oldID] = oldPayload
            }
            try persist([.payload(transitional), .metadata(secrets), .payload(payloads)])
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
        secrets.append(secret)
        payloads[secret.id] = data
        // Snapshot-and-restore: with a two-file store, leaving a failed
        // mutation in memory breaks the payload-superset invariant across
        // the NEXT mutation (a delete that failed to persist would vanish
        // from the next create's payload write). Memory always mirrors the
        // last-persisted disk state — podman can cache-before-write because
        // its db is one file; we cannot.
        let savedSecrets = secrets
        let savedPayloads = payloads
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
        let removed = secrets.remove(at: index)
        payloads.removeValue(forKey: removed.id)
        let savedSecrets = secrets
        let savedPayloads = payloads
        do {
            try persist([.metadata(secrets), .payload(payloads)])
        } catch {
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
    /// writes on disk; the in-memory mutation stands (as does podman's
    /// mutated db cache) and the next successful mutation re-syncs both
    /// files. On restart, `load` repairs whatever the interrupted sequence
    /// left behind.
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
        do {
            for write in writes {
                switch write {
                case .payload(let payloads):
                    try Self.writeJSON(payloads, to: payloadURL)
                case .metadata(let secrets):
                    try Self.writeJSON(secrets, to: metadataURL)
                }
            }
        } catch {
            throw StoreError.persistFailed("\(error)")
        }
    }

    /// Encodes and atomically replaces one store file. Payloads get 0600
    /// (podman's file driver `os.WriteFile(..., 0o600)`); metadata follows
    /// suit — labels aren't secret, but there's no reason for them to be
    /// readable either.
    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        // write(to:options:) has no permissions argument — tighten after
        // the atomic rename (the temp file is created with the default umask).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
    /// only copy of whatever the user was told to fix.
    private static func quarantineCorruptFile(at url: URL, fm: FileManager, log: Logger) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.appendingPathExtension("corrupt-\(stamp)")
        do {
            try fm.moveItem(at: url, to: backup)
            log.error(
                "could not load store file \(url.path) — moved aside as \(backup.lastPathComponent); starting empty. The file remains available for manual recovery."
            )
        } catch {
            log.error(
                "could not load store file \(url.path) and could not move it aside (\(error.localizedDescription)) — it will be overwritten by the next persist"
            )
        }
    }
}
