// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Logging

/// One plugin in the local store — moby's `types.Plugin` fields podm can
/// serve without a plugin runtime, plus bookkeeping.
struct StoredPlugin: Codable, Sendable, Equatable {
    /// 64 lowercase hex characters — moby's `stringid.GenerateRandomID`
    /// shape (`pkg/stringid/stringid.go`).
    let id: String
    /// The familiar repo name moby stores (`vieux/sshfs:latest`) — see
    /// `PluginReferenceUtility.repoName`.
    let name: String
    let createdAt: Date
    /// Always false in podm: `enable`/`disable` need the plugin execution
    /// model and stay deliberate stubs.
    var enabled: Bool
    /// The decoded `config.json`, with moby's create-time adjustments
    /// applied (`rootfs` digest, `DockerVersion`).
    var config: DockerPluginConfig
    /// moby's `InitEmptySettings` snapshot, taken at create.
    var settings: DockerPluginSettings
    /// `PluginReference` — moby's `CreateFromContext` sets it to the name.
    var pluginReference: String
}

/// The local plugin metadata store backing podm's docker-dialect `/plugins`
/// family. A deliberately SIMPLER sibling of `SecretStore`/`ConfigStore`:
/// plugins have no payload half here — podm stores no rootfs blobs because
/// nothing can execute one (the runtime half — enable/disable/pull/push/set/
/// upgrade — stays deliberately stubbed). The store keeps the ingested
/// metadata (moby's `types.Plugin` minus runtime state) so list/inspect and
/// re-creation conflict checks have real, persistent answers.
///
/// Layout (own directory, sibling of `podm-secrets`/`podm-configs`):
///
/// - `<storageDirectory>/podm-plugins/plugins.json` — the metadata DB
///
/// File 0600, directory 0700, same least-privilege discipline as the secret
/// and config stores (a plugin's config can carry host mount paths and
/// device nodes — nothing another local user should read).
///
/// An actor because route handlers hit it concurrently. Persistence rewrites
/// the single file atomically per mutation (temp file + F_FULLFSYNC +
/// rename); a failed write rolls the in-memory state back to the last
/// persisted snapshot, so memory never disagrees with disk. Corrupt files
/// are quarantined aside (`.corrupt-<timestamp>`) rather than overwritten;
/// a file that cannot be moved aside blocks mutations until an operator
/// resolves it — the same posture as the secret/config stores.
actor PluginStore {
    enum StoreError: Error, Equatable {
        /// moby `alreadyExistsError` (`plugin/errors.go`) → HTTP 409:
        /// "plugin %s already exists".
        case nameInUse(String)
        /// A persist write failed; memory was rolled back to the last
        /// persisted state, so the mutation is retryable.
        case persistFailed(String)
        /// The store could not be secured at load time — mutations are
        /// refused rather than persisting over the only copy of unreadable
        /// data; the operator resolves the files and restarts the daemon.
        case quarantineBlocked(String)
    }

    /// moby's resolution outcome for a ref-or-ID input
    /// (`plugin/store.go` `resolvePluginID`).
    enum Resolution: Equatable {
        case found(StoredPlugin)
        case notFound
        /// "multiple plugins found for %q" — moby's errAmbiguous, an
        /// InvalidParameter (400) at the route.
        case ambiguous(Int)
    }

    /// moby `stringid.GenerateRandomID`: 64 lowercase hex characters.
    static let pluginIDLength = 64

    /// In insertion order — array order keeps listings stable and
    /// oldest-first, like the config store.
    private var plugins: [StoredPlugin] = []
    private let metadataURL: URL
    private let log: Logger
    /// True when a corrupt store file could not be moved aside at load time.
    private let quarantineBlocked: Bool
    /// The data-flush primitive used before publishing a swap: F_FULLFSYNC
    /// (reaches past the drive cache; plain fsync does not). Instance-scoped
    /// so tests can fault-inject flush failures Foundation cannot produce.
    private let fullSync: @Sendable (Int32) -> Int32

    /// Loads (or initializes) the store under `storageDirectory`. A missing
    /// file is not an error — the store starts empty and writes on first
    /// mutation. A corrupt file is logged, quarantined aside, and treated as
    /// empty (same posture as `SecretStore`/`ConfigStore`).
    init(
        storageDirectory: URL, logger: Logger = Logger(label: "podm.plugins"),
        flushSync: (@Sendable (Int32) -> Int32)? = nil
    ) {
        let dir = storageDirectory.appendingPathComponent("podm-plugins", isDirectory: true)
        metadataURL = dir.appendingPathComponent("plugins.json")
        log = logger
        fullSync = flushSync ?? { fd in fcntl(fd, F_FULLFSYNC, 0) }

        // 0700 from the start; pre-existing directories are TIGHTENED, not
        // trusted — write permission on the directory is what lets another
        // local user replace or delete the store file. Only bits are
        // cleared, never set; a directory that cannot be inspected or
        // secured BLOCKS mutations.
        var permissionsUnsecured = false
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(
                    at: dir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                log.error(
                    "could not create plugin store directory \(dir.path) (\(error.localizedDescription)) — the store will refuse mutations"
                )
                permissionsUnsecured = true
            }
        } else if !Self.tightenPermissions(of: dir, fm: fm, log: log) {
            permissionsUnsecured = true
        }
        // Same for a store file that predates the 0600 discipline.
        if fm.fileExists(atPath: metadataURL.path) {
            Self.tightenPermissions(of: metadataURL, fm: fm, log: log)
        }

        let loaded = Self.load(metadataURL: metadataURL, log: log)
        plugins = loaded.plugins
        quarantineBlocked = loaded.quarantineBlocked || permissionsUnsecured
    }

    /// Static so the actor's nonisolated initializer stays in its
    /// initialization phase (property writes only).
    private static func load(
        metadataURL: URL, log: Logger
    ) -> (plugins: [StoredPlugin], quarantineBlocked: Bool) {
        var plugins: [StoredPlugin] = []
        var quarantineBlocked = false
        let fm = FileManager.default

        if let data = try? Data(contentsOf: metadataURL),
            let decoded = try? JSONDecoder().decode([StoredPlugin].self, from: data)
        {
            plugins = decoded
        } else if fm.fileExists(atPath: metadataURL.path) {
            // Back the corrupt file aside before starting empty: the next
            // persist would otherwise overwrite the only copy of the data
            // the log message says to fix.
            if !Self.quarantineCorruptFile(at: metadataURL, fm: fm, log: log) {
                quarantineBlocked = true
            }
        }

        // Crash leftovers: writeJSON's temp files from a persist interrupted
        // between temp creation and the swap are unreferenced garbage
        // nothing else removes — sweep them so they cannot accumulate. (The
        // `.corrupt-` quarantine backups are NOT touched: they hold
        // recoverable data.)
        let directory = metadataURL.deletingLastPathComponent()
        if let contents = try? fm.contentsOfDirectory(atPath: directory.path) {
            for entry in contents where entry.hasPrefix(".") && entry.contains(".tmp-") {
                try? fm.removeItem(at: directory.appendingPathComponent(entry))
            }
        }
        return (plugins, quarantineBlocked)
    }

    // MARK: - Mutations

    /// Mutations refuse to run while the store could not be secured at load
    /// time — persisting would overwrite the only copy of unreadable data.
    /// Reads keep working; the operator resolves the files and restarts.
    private func ensureNotBlocked() throws {
        if quarantineBlocked {
            throw StoreError.quarantineBlocked(
                "the plugin store could not be secured at load time (unreadable permissions, or a corrupt file could not be moved aside) — resolve the files under "
                    + metadataURL.deletingLastPathComponent().path + " and restart podmd")
        }
    }

    /// Registers an ingested plugin. The name must already be the familiar
    /// repo name (`PluginReferenceUtility.repoName`); a duplicate is moby's
    /// `validateName` → `alreadyExistsError` (409 at the route). The ID is
    /// minted here, moby's `stringid.GenerateRandomID` shape.
    @discardableResult
    func create(
        name: String, config: DockerPluginConfig, settings: DockerPluginSettings, pluginReference: String
    ) throws -> StoredPlugin {
        try ensureNotBlocked()
        // moby's validateName is an exact, case-SENSITIVE name comparison
        // (unlike swarmkit's lowercased config/secret index).
        if plugins.contains(where: { $0.name == name }) {
            throw StoreError.nameInUse(name)
        }
        let plugin = StoredPlugin(
            id: Self.generateID(existing: Set(plugins.map(\.id))),
            name: name,
            createdAt: Date(),
            enabled: false,
            config: config,
            settings: settings,
            pluginReference: pluginReference)
        // Snapshot-and-restore: a failed persist left applied in memory
        // would make the store serve a plugin that vanishes on restart.
        let saved = plugins
        plugins.append(plugin)
        do {
            try persist()
        } catch {
            plugins = saved
            throw error
        }
        return plugin
    }

    // MARK: - Queries

    func list() -> [StoredPlugin] {
        plugins
    }

    /// moby `Store.resolvePluginID` (`plugin/store.go`), verbatim order:
    /// a full-ID-shaped input resolves by exact ID only; anything else is
    /// parsed as a reference and matched against the stored familiar names
    /// first, then as an ID prefix (ambiguous → error, never a silent pick).
    /// An unparseable input resolves to nothing — the route's 404, like
    /// moby's errNotFound wrap of the parse failure.
    func resolve(refOrID: String) -> Resolution {
        if PluginReferenceUtility.isFullID(refOrID) {
            guard let byID = plugins.first(where: { $0.id == refOrID }) else { return .notFound }
            return .found(byID)
        }
        if let lookupName = PluginReferenceUtility.lookupName(from: refOrID),
            let byName = plugins.first(where: { $0.name == lookupName })
        {
            return .found(byName)
        }
        // Prefix matches use the RAW input, like moby's strings.HasPrefix
        // loop; only inputs no longer than an ID can be prefixes.
        guard !refOrID.isEmpty, refOrID.count <= Self.pluginIDLength else { return .notFound }
        let prefixMatches = plugins.filter { $0.id.hasPrefix(refOrID) }
        switch prefixMatches.count {
        case 1: return .found(prefixMatches[0])
        case 0: return .notFound
        default: return .ambiguous(prefixMatches.count)
        }
    }

    // MARK: - Persistence

    /// Rewrites the store file atomically, THROWING on failure so callers
    /// surface a 500 instead of acknowledging a create that would vanish on
    /// restart. Callers roll memory back on failure; the atomic swap means
    /// the file on disk is either the old state or the new one, never a mix.
    private func persist() throws {
        do {
            try Self.writeJSON(plugins, to: metadataURL, log: log, fullSync: fullSync)
        } catch {
            throw StoreError.persistFailed("\(error)")
        }
    }

    /// Encodes and atomically replaces the store file, 0600 from the start.
    ///
    /// Failure ordering contract (inherited from the secret/config stores):
    /// only THROWS before the data swap commits (temp creation, sync,
    /// replace/move). The temp's data is flushed BEFORE the swap (fsync
    /// upgraded to F_FULLFSYNC — on macOS a plain fsync only reaches the
    /// drive's cache) and the containing directory after (post-commit,
    /// logged, never thrown). When F_FULLFSYNC is unsupported
    /// (ENOTSUP/EINVAL) the fallback is plain fsync.
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
                atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
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
        // Post-commit, best-effort directory flush — never throws (the swap
        // already committed).
        let directory = url.deletingLastPathComponent()
        let dirFD = open(directory.path, O_RDONLY)
        if dirFD >= 0 {
            let synced = fcntl(dirFD, F_FULLFSYNC, 0) == 0 || fsync(dirFD) == 0
            close(dirFD)
            if !synced {
                log.warning(
                    "plugin store directory \(directory.path) could not be synced after committing \(url.lastPathComponent) — the rename may not survive a power loss"
                )
            }
        }
        // A same-directory swap may leave the temp behind; either way it
        // must not linger.
        try? FileManager.default.removeItem(at: temp)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // The data swap already committed — never throw from here. The
            // mode was secured before the swap; this is a logged anomaly.
            log.warning(
                "plugin store file \(url.path) committed but its mode could not be re-asserted (\(error.localizedDescription))"
            )
        }
    }

    /// Strips group/other access bits from an existing file or directory,
    /// reporting whether the item is verifiably owner-only afterwards.
    /// Only bits are cleared, never set — a deliberately read-only item
    /// keeps its owner bits.
    @discardableResult
    private static func tightenPermissions(of url: URL, fm: FileManager, log: Logger) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        else {
            log.error("could not inspect permissions of \(url.path) — treating the plugin store as unsecured")
            return false
        }
        guard perms & 0o077 != 0 else { return true }
        do {
            try fm.setAttributes([.posixPermissions: perms & ~0o077], ofItemAtPath: url.path)
            return true
        } catch {
            log.error(
                "could not tighten permissions of \(url.path) (\(error.localizedDescription)) — other local users may reach the plugin store; refusing mutations"
            )
            return false
        }
    }

    /// 64 lowercase hex characters — moby's `stringid.GenerateRandomID`
    /// shape. Collision with an existing ID is astronomically unlikely
    /// (256 bits) but checked anyway.
    private static func generateID(existing: Set<String> = []) -> String {
        var rng = SystemRandomNumberGenerator()
        while true {
            let hex = (0..<4).map { _ in String(format: "%016llx", rng.next()) }.joined()
            let id = String(hex.prefix(pluginIDLength))
            if !existing.contains(id) {
                return id
            }
        }
    }

    /// Renames an undecodable store file aside (`.corrupt-<timestamp>`)
    /// instead of leaving it in place: the next persist would overwrite the
    /// original name, destroying the only copy of whatever the user was told
    /// to fix. Returns false when the move itself failed — the caller blocks
    /// mutations.
    @discardableResult
    private static func quarantineCorruptFile(at url: URL, fm: FileManager, log: Logger) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.appendingPathExtension("corrupt-\(stamp)")
        do {
            try fm.moveItem(at: url, to: backup)
            // Owner-only regardless of the modes the corrupt file carried.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            log.error(
                "could not load plugin store file \(url.path) — moved aside as \(backup.lastPathComponent); starting empty. The file remains available for manual recovery."
            )
            return true
        } catch {
            log.error(
                "could not load plugin store file \(url.path) and could not move it aside (\(error.localizedDescription)) — it will NOT be overwritten: mutations are refused until it is resolved and the daemon restarted"
            )
            return false
        }
    }
}
