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
/// both files atomically on every mutation so a crash never leaves metadata
/// referencing payloads that aren't there (or vice versa — both files are
/// rewritten from the same in-memory state).
///
/// Semantics follow `go.podman.io/common/pkg/secrets` (SecretsManager.Store /
/// Delete / Lookup): names are validated (1–253 chars, no `,` `/` `=` or
/// NUL), data must be 1..<512000 bytes, `replace` deletes and re-stores under
/// a fresh ID, `ignore` returns the existing secret's ID, and both together
/// are an error. Lookup accepts an exact name OR exact ID, never a prefix.
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

        if let data = try? Data(contentsOf: metadataURL),
            let decoded = try? JSONDecoder().decode([StoredSecret].self, from: data)
        {
            secrets = decoded
        } else if fm.fileExists(atPath: metadataURL.path) {
            log.error("could not load secret metadata from \(metadataURL.path) — existing secrets are not visible until the file is fixed")
        }

        if let data = try? Data(contentsOf: payloadURL),
            let decoded = try? JSONDecoder().decode([String: Data].self, from: data)
        {
            payloads = decoded
        } else if fm.fileExists(atPath: payloadURL.path) {
            log.error("could not load secret payloads from \(payloadURL.path) — existing secrets are not inspectable with --showsecret until the file is fixed")
        }
        return (secrets, payloads)
    }

    // MARK: - Mutations

    /// Creates (or replaces) a secret, returning the stored record. Mirrors
    /// `SecretsManager.Store` including its validation order, so error
    /// precedence matches podman: name → data size → ignore+replace →
    /// name-in-use.
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
        guard !name.isEmpty, name.count <= 253, !name.contains(where: { ",/=\0".contains($0) }) else {
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

        if let index = secrets.firstIndex(where: { $0.name == name }) {
            guard replace || ignore else {
                throw StoreError.nameInUse(name)
            }
            if ignore {
                // Podman: return the existing secret untouched.
                return secrets[index]
            }
            // Replace: fresh ID, fresh timestamps-of-update, metadata rewritten.
            var replacement = secrets[index]
            payloads.removeValue(forKey: replacement.id)
            replacement.id = Self.generateID(existing: Set(secrets.map(\.id)))
            replacement.updatedAt = Date()
            replacement.labels = labels
            replacement.driverOptions = driverOptions
            replacement.driver = resolvedDriver
            secrets[index] = replacement
            payloads[replacement.id] = data
            persist()
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
        persist()
        return secret
    }

    /// Removes a secret by name, ID, or unambiguous ID prefix, returning the
    /// deleted record (nil when nothing matched — podman's `ErrNoSuchSecret`).
    @discardableResult
    func remove(nameOrID: String) -> StoredSecret? {
        guard let secret = lookup(nameOrID: nameOrID),
            let index = secrets.firstIndex(where: { $0.id == secret.id })
        else { return nil }
        let removed = secrets.remove(at: index)
        payloads.removeValue(forKey: removed.id)
        persist()
        return removed
    }

    // MARK: - Queries

    func list() -> [StoredSecret] {
        secrets
    }

    /// Exact name or full ID first, then an unambiguous ID prefix — podman's
    /// `SecretsManager.Lookup` / `secretsdb.getNameAndID`. An ambiguous prefix
    /// resolves to nothing (podman answers an explicit error there; callers
    /// surface it as not-found).
    func lookup(nameOrID: String) -> StoredSecret? {
        if let exact = secrets.first(where: { $0.name == nameOrID || $0.id == nameOrID }) {
            return exact
        }
        // ID prefix (podman getNameAndID): only references no longer than an
        // ID can be prefixes, and only when unambiguous.
        guard !nameOrID.isEmpty, nameOrID.count <= Self.secretIDLength else { return nil }
        let prefixMatches = secrets.filter { $0.id.hasPrefix(nameOrID) }
        return prefixMatches.count == 1 ? prefixMatches[0] : nil
    }

    /// The payload, only for the explicit `--showsecret` inspect path.
    func payload(id: String) -> Data? {
        payloads[id]
    }

    // MARK: - Persistence

    /// Rewrites both files from the same in-memory state so metadata and
    /// payloads can never disagree. Payloads get 0600 (podman's file driver
    /// `os.WriteFile(..., 0o600)`); metadata follows suit — labels aren't
    /// secret, but there's no reason for them to be readable either.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let metadata = try encoder.encode(secrets)
            try metadata.write(to: metadataURL, options: .atomic)
            let payloadData = try encoder.encode(payloads)
            try payloadData.write(to: payloadURL, options: .atomic)
            // write(to:options:) has no permissions argument — tighten after
            // the atomic rename (the temp file is created with 0644 umask).
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payloadURL.path)
        } catch {
            log.error(
                "could not persist the secret store under \(metadataURL.deletingLastPathComponent().path) — the change is in effect but will not survive a daemon restart: \(error)"
            )
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
}
