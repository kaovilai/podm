// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import podmd

/// Store-level coverage for the local plugin metadata store: moby's name
/// semantics (validateName → alreadyExistsError), `resolvePluginID`'s
/// resolution order, `stringid.GenerateRandomID`'s ID shape, and the file
/// hardening (0600/0700, atomic persist, corrupt-file quarantine, blocked
/// store) inherited from the secret/config store discipline.
@Suite("PluginStore")
struct PluginStoreTests {

    private func makeConfig() -> DockerPluginConfig {
        DockerPluginConfig(
            Description: "a test plugin",
            Documentation: "https://example.com/docs",
            Entrypoint: ["/bin/plugin"],
            Env: [DockerPluginEnv(Name: "DEBUG", Value: "0")],
            Interface: DockerPluginConfigInterface(
                Socket: "plugin.sock",
                Types: [DockerPluginInterfaceType(Prefix: "docker", Capability: "volumedriver", Version: "1.0")]),
            Linux: DockerPluginConfigLinux(),
            Mounts: [],
            Network: DockerPluginConfigNetwork(networkType: "bridge"),
            PropagatedMount: "",
            WorkDir: "/work",
            rootfs: DockerPluginConfigRootfs(diff_ids: ["sha256:abc"], type: "layers"))
    }

    @Test("create stores a disabled plugin with a 64-hex ID, moby's shape")
    func createShape() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PluginStore(storageDirectory: dir)
        let plugin = try await store.create(
            name: "vieux/sshfs:latest", config: makeConfig(),
            settings: DockerPluginSettings.emptySettings(from: makeConfig()),
            pluginReference: "vieux/sshfs:latest")
        #expect(plugin.id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, "moby stringid.GenerateRandomID shape")
        #expect(plugin.name == "vieux/sshfs:latest")
        #expect(plugin.enabled == false, "createPlugin never enables — that is the stubbed runtime half")
        let listed = await store.list()
        #expect(listed == [plugin])
    }

    @Test("duplicate name is moby's alreadyExistsError (case-sensitive, exact)")
    func duplicateName() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PluginStore(storageDirectory: dir)
        _ = try await store.create(
            name: "myplugin:latest", config: makeConfig(),
            settings: DockerPluginSettings(), pluginReference: "myplugin:latest")
        await #expect(throws: PluginStore.StoreError.nameInUse("myplugin:latest")) {
            _ = try await store.create(
                name: "myplugin:latest", config: makeConfig(),
                settings: DockerPluginSettings(), pluginReference: "myplugin:latest")
        }
        // moby's validateName is a byte-exact comparison, unlike swarmkit's
        // lowercased config/secret index — a different case is a DIFFERENT
        // plugin name.
        _ = try await store.create(
            name: "MyPlugin:latest", config: makeConfig(),
            settings: DockerPluginSettings(), pluginReference: "MyPlugin:latest")
        let listed = await store.list()
        #expect(listed.count == 2)
    }

    @Test("resolution follows moby's resolvePluginID: full ID, name, prefix, ambiguous")
    func resolution() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PluginStore(storageDirectory: dir)
        let first = try await store.create(
            name: "alpha/plugin:latest", config: makeConfig(),
            settings: DockerPluginSettings(), pluginReference: "alpha/plugin:latest")
        let second = try await store.create(
            name: "beta/plugin:latest", config: makeConfig(),
            settings: DockerPluginSettings(), pluginReference: "beta/plugin:latest")

        // Full ID — exact.
        let byID = await store.resolve(refOrID: first.id)
        #expect(byID == .found(first))

        // A full-ID-SHAPED input that matches nothing is a 404, never a
        // prefix candidate (moby checks validFullID first).
        let missShaped = await store.resolve(refOrID: String(repeating: "a", count: 64))
        #expect(missShaped == .notFound)

        // Familiar name — the stored, normalized form.
        let byName = await store.resolve(refOrID: "alpha/plugin")
        #expect(byName == .found(first))

        // Unambiguous ID prefix.
        let prefix = String(first.id.prefix(12))
        let byPrefix = await store.resolve(refOrID: prefix)
        #expect(byPrefix == .found(first))

        // Ambiguous prefix — moby's errAmbiguous, never a silent pick.
        // Random IDs rarely share a prefix; keep creating until some first
        // character is shared by two plugins, then resolve by it.
        var firstChars: [Character: Int] = [:]
        for id in [first.id, second.id] {
            firstChars[id.first!, default: 0] += 1
        }
        var shared = firstChars.first(where: { $0.value >= 2 })?.key
        while shared == nil {
            let extra = try await store.create(
                name: "extra\(firstChars.count)/plugin:latest", config: makeConfig(),
                settings: DockerPluginSettings(), pluginReference: "extra/plugin:latest")
            let char = extra.id.first!
            firstChars[char, default: 0] += 1
            if firstChars[char]! >= 2 {
                shared = char
            }
        }
        let ambiguous = await store.resolve(refOrID: String(shared!))
        if case .ambiguous(let count) = ambiguous {
            #expect(count >= 2)
        } else {
            Issue.record("expected an ambiguous resolution, got \(ambiguous)")
        }

        // Garbage input resolves to nothing — moby wraps the parse failure
        // as errNotFound, so the route 404s instead of 400ing.
        let garbage = await store.resolve(refOrID: "NOT A REFERENCE!!")
        #expect(garbage == .notFound)
        #expect(await store.resolve(refOrID: second.name) == .found(second))
    }

    @Test("the store persists across re-instantiation from the same directory")
    func persistence() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PluginStore(storageDirectory: dir)
        let created = try await store.create(
            name: "persist/plugin:latest", config: makeConfig(),
            settings: DockerPluginSettings.emptySettings(from: makeConfig()),
            pluginReference: "persist/plugin:latest")
        let reopened = PluginStore(storageDirectory: dir)
        let listed = await reopened.list()
        #expect(listed == [created])
        #expect(await reopened.resolve(refOrID: "persist/plugin") == .found(created))
    }

    @Test("store files are owner-only: directory 0700, file 0600")
    func permissions() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PluginStore(storageDirectory: dir)
        _ = try await store.create(
            name: "perm/plugin:latest", config: makeConfig(),
            settings: DockerPluginSettings(), pluginReference: "perm/plugin:latest")
        let storeDir = dir.appendingPathComponent("podm-plugins")
        let file = storeDir.appendingPathComponent("plugins.json")
        let fm = FileManager.default
        let dirPerms = try fm.attributesOfItem(atPath: storeDir.path)[.posixPermissions] as? Int
        let filePerms = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(dirPerms == 0o700)
        #expect(filePerms == 0o600)
        // A pre-existing group/world-readable directory is tightened at load.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeDir.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        _ = PluginStore(storageDirectory: dir)
        let tightenedDir = try fm.attributesOfItem(atPath: storeDir.path)[.posixPermissions] as? Int
        let tightenedFile = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(tightenedDir == 0o700)
        #expect(tightenedFile == 0o600)
    }

    @Test("a corrupt store file is quarantined aside and the store starts empty")
    func corruptFileQuarantine() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeDir = dir.appendingPathComponent("podm-plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let file = storeDir.appendingPathComponent("plugins.json")
        try Data("not json at all".utf8).write(to: file)
        let store = PluginStore(storageDirectory: dir)
        #expect(await store.list().isEmpty)
        // The corrupt original survives under a .corrupt- backup name for
        // manual recovery; the live name is gone (replaced on next persist).
        let backups = try FileManager.default.contentsOfDirectory(atPath: storeDir.path)
            .filter { $0.hasPrefix("plugins.json.corrupt-") }
        #expect(backups.count == 1)
        // Mutations still work — the quarantine made the name writable.
        _ = try await store.create(
            name: "after/quarantine:latest", config: makeConfig(),
            settings: DockerPluginSettings(), pluginReference: "after/quarantine:latest")
        #expect(await store.list().count == 1)
    }

    @Test("an unquarantinable corrupt file blocks mutations, reads keep working")
    func blockedStore() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeDir = dir.appendingPathComponent("podm-plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let file = storeDir.appendingPathComponent("plugins.json")
        try Data("garbage".utf8).write(to: file)
        // Read-only directory: the quarantine move fails, so the corrupt
        // file cannot be moved aside — persisting would overwrite the only
        // copy, so mutations are refused.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: storeDir.path)
        let store = PluginStore(storageDirectory: dir)
        #expect(await store.list().isEmpty)
        do {
            _ = try await store.create(
                name: "blocked/plugin:latest", config: makeConfig(),
                settings: DockerPluginSettings(), pluginReference: "blocked/plugin:latest")
            Issue.record("expected quarantineBlocked")
        } catch PluginStore.StoreError.quarantineBlocked {
            // expected
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDir.path)
    }

    @Test("an untightenable metadata file blocks mutations — the file check feeds the same refusal")
    func unsecurableMetadataFileBlocksMutations() async throws {
        let dir = uniqueTempDir()
        let storeDir = dir.appendingPathComponent("podm-plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let file = storeDir.appendingPathComponent("plugins.json")
        try Data("[]".utf8).write(to: file)
        // Group-readable AND mode-locked (user-immutable): inspection
        // succeeds, but the chmod that strips the group bits fails — the
        // store file stays world-readable, so persisting over it must be
        // refused (the discarded tighten result used to let it through).
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let store = PluginStore(storageDirectory: dir)
        // Reads keep working — the (valid) file still loads.
        #expect(await store.list().isEmpty)
        do {
            _ = try await store.create(
                name: "blocked/plugin:latest", config: makeConfig(),
                settings: DockerPluginSettings(), pluginReference: "blocked/plugin:latest")
            Issue.record("create must be refused while the store file cannot be secured")
        } catch PluginStore.StoreError.quarantineBlocked {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // Lock released: a fresh instance tightens the file and works.
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
        let recovered = PluginStore(storageDirectory: dir)
        _ = try await recovered.create(
            name: "fresh/plugin:latest", config: makeConfig(),
            settings: DockerPluginSettings(), pluginReference: "fresh/plugin:latest")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! Int
        #expect(perms & 0o077 == 0, "the recovered instance tightened the file")
    }

    @Test("a failed persist rolls back memory — the store never serves a plugin that would vanish on restart")
    func persistFailureRollsBack() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Fault-injected F_FULLFSYNC: sets a real errno and fails, so
        // writeJSON throws before the swap ever commits (same technique as
        // the config store tests).
        let store = PluginStore(
            storageDirectory: dir,
            flushSync: { _ in
                errno = EIO
                return -1
            })
        do {
            _ = try await store.create(
                name: "rollback/plugin:latest", config: makeConfig(),
                settings: DockerPluginSettings(), pluginReference: "rollback/plugin:latest")
            Issue.record("expected persistFailed")
        } catch PluginStore.StoreError.persistFailed {
            // expected
        }
        #expect(await store.list().isEmpty, "memory mirrors the last persisted state")
        // A reopen sees nothing on disk either.
        let reopened = PluginStore(storageDirectory: dir)
        #expect(await reopened.list().isEmpty)
    }
}

private func uniqueTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
