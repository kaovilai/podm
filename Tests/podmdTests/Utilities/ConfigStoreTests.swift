// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import podmd

/// Store-level coverage for `ConfigStore` — the structural mirror of
/// `SecretStoreTests`, with the CONFIG policy differences pinned (moby
/// v28.5.2 / swarmkit `8c1959736554`):
///
/// - Names follow swarmkit's `validateConfigOrSecretAnnotations` (≤64 bytes
///   of `[a-zA-Z0-9-_.]`, alphanumeric ends) — NOT podman's secret charset.
/// - Data must be 1..<1024000 bytes (swarmkit `MaxConfigSize` 1000\*1024 —
///   twice the secret store's 500\*1024).
/// - No driver, no replace/ignore (moby's `swarm.ConfigSpec` has neither).
/// - The persistence machinery (paired quarantine, pre-mutation rollback,
///   orphan prune, permission tightening) behaves like the secret store's.
@Suite("ConfigStore")
struct ConfigStoreTests {

    // MARK: - Validation

    @Test("names follow swarmkit's config rules, not podman's secret charset")
    func swarmkitNameValidation() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(storageDirectory: dir)

        // Valid: alphanumerics, dashes, underscores, dots; single char.
        for valid in ["app", "app-config", "app_config", "app.config", "a", "A9-z_0"] {
            _ = try await store.create(name: valid, data: Data("x".utf8), labels: [:])
        }
        // Invalid: empty, >64 bytes, bad charset, bad anchors.
        for invalid in [
            "",
            String(repeating: "a", count: 65),  // swarmkit: >64 rejected (podman allows 253)
            "has=equals",  // valid PODMAN secret name, invalid swarmkit config name
            "has/slash",
            "has,comma",
            "-leading", "trailing-", ".leading", "trailing.",
            "café",  // non-ASCII
            "trailing-newline\n",
        ] {
            await #expect(throws: ConfigStore.StoreError.self) {
                _ = try await store.create(name: invalid, data: Data("x".utf8), labels: [:])
            }
        }
    }

    @Test("data must be 1..<1024000 bytes — swarmkit MaxConfigSize, twice the secret limit")
    func dataSizeValidation() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(storageDirectory: dir)

        #expect(ConfigStore.maxConfigSize == 1_024_000, "swarmkit MaxConfigSize = 1000*1024")
        // Empty is rejected.
        await #expect(throws: ConfigStore.StoreError.dataTooLarge) {
            _ = try await store.create(name: "empty", data: Data(), labels: [:])
        }
        // Exactly the limit is rejected (swarmkit: len >= MaxConfigSize).
        await #expect(throws: ConfigStore.StoreError.dataTooLarge) {
            _ = try await store.create(name: "at-limit", data: Data(repeating: 0x61, count: ConfigStore.maxConfigSize), labels: [:])
        }
        // One under the limit is accepted.
        let big = try await store.create(
            name: "under-limit", data: Data(repeating: 0x61, count: ConfigStore.maxConfigSize - 1), labels: [:])
        let paired = await store.inspect(nameOrID: big.id)
        #expect(paired?.data?.count == ConfigStore.maxConfigSize - 1)
    }

    @Test("duplicate names are rejected; a name equal to an existing ID counts as in use")
    func nameInUse() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(storageDirectory: dir)

        let first = try await store.create(name: "dup", data: Data("x".utf8), labels: [:])
        await #expect(throws: ConfigStore.StoreError.self) {
            _ = try await store.create(name: "dup", data: Data("y".utf8), labels: [:])
        }
        // moby's getConfig resolves a full ID BEFORE a name — permitting a
        // name equal to an existing ID would hijack every later lookup.
        await #expect(throws: ConfigStore.StoreError.self) {
            _ = try await store.create(name: first.id, data: Data("y".utf8), labels: [:])
        }
    }

    @Test("name equality is byte-wise: no case folding, no canonical equivalence")
    func unicodeNameEquivalenceIsByteWise() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(storageDirectory: dir)
        // Swarmkit's charset is ASCII-only, so NFC/NFD collisions cannot
        // arise for configs; byte-wise equality still means NO case folding
        // — Go string comparison, like the secret store's sameName.
        _ = try await store.create(name: "CaseSensitive", data: Data("x".utf8), labels: [:])
        _ = try await store.create(name: "casesensitive", data: Data("y".utf8), labels: [:])
        let a = await store.lookup(nameOrID: "CaseSensitive")
        let b = await store.lookup(nameOrID: "casesensitive")
        #expect(a?.id != b?.id, "Go string equality is byte-wise: no case folding")
        #expect(await store.list().count == 2)
    }

    // MARK: - Lookup

    @Test("lookup resolves an exact full ID before a name")
    func lookupPrefersIDOverName() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(storageDirectory: dir)
        let config = try await store.create(name: "alpha", data: Data("x".utf8), labels: [:])
        let found = await store.lookup(nameOrID: config.id)
        #expect(found?.id == config.id)
        let byName = await store.lookup(nameOrID: "alpha")
        #expect(byName?.id == config.id)
        // A prefix longer than an ID cannot be a prefix; an ambiguous
        // prefix resolves to nothing.
        #expect(await store.lookup(nameOrID: String(repeating: "z", count: 30)) == nil)
    }

    @Test("inspect and listWithPayloads pair metadata with the right payload in one hop")
    func pairedReads() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(storageDirectory: dir)
        _ = try await store.create(name: "one", data: Data("payload-one".utf8), labels: ["k": "v"])
        _ = try await store.create(name: "two", data: Data("payload-two".utf8), labels: [:])

        let inspected = await store.inspect(nameOrID: "one")
        #expect(inspected?.config.name == "one")
        #expect(inspected?.data == Data("payload-one".utf8))

        let listed = await store.listWithPayloads()
        #expect(listed.count == 2)
        #expect(listed.first { $0.config.name == "two" }?.data == Data("payload-two".utf8))
        #expect(listed.first { $0.config.name == "one" }?.config.labels == ["k": "v"])
    }

    // MARK: - Persistence and repair

    @Test("an interrupted persist leaves only orphan payloads, which load prunes")
    func loadRepairsOrphanPayloads() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = ConfigStore(storageDirectory: dir)  // creates the directory layout

        // Crash mid-persist after the payload write but before the metadata
        // write: the payload file gains an entry no metadata references.
        let real = StoredConfig(
            id: "aaaaaaaaaaaaaaaaaaaaaaaaa", name: "real", createdAt: Date(), updatedAt: Date(), labels: [:])
        let encoder = JSONEncoder()
        try encoder.encode([real]).write(
            to: dir.appendingPathComponent("podm-configs/configs.json"), options: .atomic)
        try encoder.encode([
            "aaaaaaaaaaaaaaaaaaaaaaaaa": Data("real-data".utf8),
            "bbbbbbbbbbbbbbbbbbbbbbbbb": Data("orphan-data".utf8),
        ]).write(
            to: dir.appendingPathComponent("podm-configs/payloads/configsdata.json"), options: .atomic)

        let store = ConfigStore(storageDirectory: dir)
        #expect(await store.payload(id: "bbbbbbbbbbbbbbbbbbbbbbbbb") == nil, "orphaned payload must be pruned on load")
        #expect(await store.payload(id: "aaaaaaaaaaaaaaaaaaaaaaaaa") == Data("real-data".utf8))
        #expect(await store.lookup(nameOrID: "real")?.id == "aaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    @Test("a metadata record with no payload is kept, not dropped — its Data reads as absent")
    func loadKeepsDanglingMetadata() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = ConfigStore(storageDirectory: dir)

        // Only reachable by hand-mangling the store (persist's ordering
        // cannot produce it); keep such records rather than silently
        // dropping configs — the payload serves as absent, never fabricated.
        let ghost = StoredConfig(
            id: "ccccccccccccccccccccccccc", name: "ghost", createdAt: Date(), updatedAt: Date(), labels: [:])
        try JSONEncoder().encode([ghost]).write(
            to: dir.appendingPathComponent("podm-configs/configs.json"), options: .atomic)
        try JSONEncoder().encode([String: Data]()).write(
            to: dir.appendingPathComponent("podm-configs/payloads/configsdata.json"), options: .atomic)

        let store = ConfigStore(storageDirectory: dir)
        #expect(await store.lookup(nameOrID: "ghost")?.name == "ghost")
        #expect(await store.payload(id: "ccccccccccccccccccccccccc") == nil)
    }

    @Test("configs survive store re-instantiation from the same directory, with 0600 payload files")
    func persistenceAndPermissions() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(storageDirectory: dir)
        let created = try await store.create(name: "durable", data: Data("payload".utf8), labels: ["a": "b"])

        let reloaded = ConfigStore(storageDirectory: dir)
        let found = await reloaded.lookup(nameOrID: created.id)
        #expect(found?.name == "durable")
        #expect(found?.labels == ["a": "b"])
        let inspected = await reloaded.inspect(nameOrID: "durable")
        #expect(inspected?.data == Data("payload".utf8))

        let fm = FileManager.default
        for file in [
            dir.appendingPathComponent("podm-configs/configs.json"),
            dir.appendingPathComponent("podm-configs/payloads/configsdata.json"),
        ] {
            let perms = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as! Int
            #expect(perms & 0o077 == 0, "\(file.path) must be owner-only")
        }
    }

    @Test("a corrupt store file is quarantined aside, not silently overwritten")
    func corruptFileQuarantined() async throws {
        let dir = uniqueTempDir()
        let podmDir = dir.appendingPathComponent("podm-configs")
        try FileManager.default.createDirectory(at: podmDir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: podmDir.appendingPathComponent("configs.json"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(storageDirectory: dir)
        #expect(await store.list().isEmpty)
        let metaFiles = try FileManager.default.contentsOfDirectory(atPath: podmDir.path)
        #expect(metaFiles.contains { $0.hasPrefix("configs.json.corrupt-") })
        #expect(!metaFiles.contains("configs.json"))
        // The store works after the quarantine.
        let created = try await store.create(name: "fresh", data: Data("x".utf8), labels: [:])
        #expect(await store.lookup(nameOrID: created.id) != nil)
    }

    @Test("a metadata quarantine also quarantines the payloads — the pair stays recoverable")
    func metadataFailureQuarantinesPayloadsToo() async throws {
        let dir = uniqueTempDir()
        let podmDir = dir.appendingPathComponent("podm-configs")
        let payloadsDir = podmDir.appendingPathComponent("payloads")
        try FileManager.default.createDirectory(at: payloadsDir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: podmDir.appendingPathComponent("configs.json"))
        try Data("garbage".utf8).write(to: payloadsDir.appendingPathComponent("configsdata.json"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(storageDirectory: dir)
        #expect(await store.list().isEmpty)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: payloadsDir.path).contains("configsdata.json"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: payloadsDir.path)
                .contains { $0.hasPrefix("configsdata.json.corrupt-") })
    }

    @Test("a quarantine that cannot move the file blocks mutations until restart")
    func failedQuarantineMoveBlocksMutations() async throws {
        let dir = uniqueTempDir()
        let podmDir = dir.appendingPathComponent("podm-configs")
        let payloadsDir = podmDir.appendingPathComponent("payloads")
        try FileManager.default.createDirectory(at: payloadsDir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: podmDir.appendingPathComponent("configs.json"))
        try Data("garbage".utf8).write(to: payloadsDir.appendingPathComponent("configsdata.json"))
        // Deny write on BOTH store directories — either quarantine rename
        // would succeed against a writable dir.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: podmDir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: payloadsDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: podmDir.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payloadsDir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let store = ConfigStore(storageDirectory: dir)
        #expect(await store.list().isEmpty, "reads still work")
        do {
            _ = try await store.create(name: "blocked", data: Data("x".utf8), labels: [:])
            Issue.record("create must be refused on a store whose quarantine failed")
        } catch ConfigStore.StoreError.quarantineBlocked {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // Fixing permissions does not unblock THIS instance — the flag is
        // load-time; only a restart clears it.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: podmDir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payloadsDir.path)
        do {
            _ = try await store.create(name: "still-blocked", data: Data("x".utf8), labels: [:])
            Issue.record("create must stay refused until the daemon restarts")
        } catch ConfigStore.StoreError.quarantineBlocked {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Rollback (the superset invariant)

    @Test("a create whose persist fails rolls back — memory mirrors the last-persisted disk state")
    func failedCreateRollsBack() async throws {
        let dir = uniqueTempDir()
        let podmDir = dir.appendingPathComponent("podm-configs")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: podmDir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = ConfigStore(storageDirectory: dir)
        _ = try await store.create(name: "orig", data: Data("old-data".utf8), labels: [:])
        // Read-only store dir: every persist write fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: podmDir.path)
        await #expect(throws: ConfigStore.StoreError.self) {
            _ = try await store.create(name: "second", data: Data("new-data".utf8), labels: [:])
        }
        // Rollback: the failed create is gone from memory AND a reload from
        // disk agrees — only the first config exists.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: podmDir.path)
        #expect(await store.list().count == 1)
        let reloaded = ConfigStore(storageDirectory: dir)
        #expect(await reloaded.list().count == 1)
        let inspected = await reloaded.inspect(nameOrID: "orig")
        #expect(inspected?.data == Data("old-data".utf8))
    }

    @Test("a remove whose payload trim fails keeps the committed deletion and answers success")
    func failedRemoveTrimKeepsDeletion() async throws {
        let dir = uniqueTempDir()
        let payloadsDir = dir.appendingPathComponent("podm-configs/payloads")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payloadsDir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = ConfigStore(storageDirectory: dir)
        _ = try await store.create(name: "half-removed", data: Data("leftover".utf8), labels: [:])
        // Read-only PAYLOAD dir, writable metadata dir: remove's metadata
        // write commits the deletion, the payload trim fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: payloadsDir.path)
        // The deletion committed — it is reported as the success it is;
        // answering an error would make the client retry a delete that
        // already happened (404).
        let removed = try await store.remove(nameOrID: "half-removed")
        #expect(removed?.name == "half-removed")
        #expect(await store.list().isEmpty)
        // Reload agrees: the deletion landed in the metadata.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payloadsDir.path)
        let reloaded = ConfigStore(storageDirectory: dir)
        #expect(await reloaded.list().isEmpty)
    }

    @Test("pre-existing loose permissions are tightened on load")
    func loosePreexistingPermissionsTightened() async throws {
        let dir = uniqueTempDir()
        let podmDir = dir.appendingPathComponent("podm-configs")
        let payloadsDir = podmDir.appendingPathComponent("payloads")
        try FileManager.default.createDirectory(at: podmDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createDirectory(at: payloadsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = ConfigStore(storageDirectory: dir)
        func groupOtherBits(_ path: String) throws -> Int {
            let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! Int
            return perms & 0o077
        }
        #expect(try groupOtherBits(podmDir.path) == 0, "store directory must lose group/world bits")
        #expect(try groupOtherBits(payloadsDir.path) == 0, "payload directory must lose group/world bits")
    }

    @Test("interrupted-persist temp files are swept on load")
    func crashLeftoverTempFilesSwept() async throws {
        let dir = uniqueTempDir()
        let podmDir = dir.appendingPathComponent("podm-configs")
        let payloadsDir = podmDir.appendingPathComponent("payloads")
        try FileManager.default.createDirectory(at: payloadsDir, withIntermediateDirectories: true)
        // Crash leftovers in both directories; the .corrupt- backups must
        // NOT be touched.
        try Data("x".utf8).write(to: podmDir.appendingPathComponent(".configs.json.tmp-abc"))
        try Data("x".utf8).write(to: payloadsDir.appendingPathComponent(".configsdata.json.tmp-def"))
        try Data("x".utf8).write(to: podmDir.appendingPathComponent("configs.json.corrupt-123"))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = ConfigStore(storageDirectory: dir)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: podmDir.path).contains(".configs.json.tmp-abc"))
        #expect(try !FileManager.default.contentsOfDirectory(atPath: payloadsDir.path).contains(".configsdata.json.tmp-def"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: podmDir.path)
                .contains { $0.hasPrefix("configs.json.corrupt-") })
    }

    @Test("a failed data flush before the swap is a pre-commit failure (rollback, retryable)")
    func dataFlushFailureIsPreCommitFailure() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Fault-injected F_FULLFSYNC: fails with a real I/O errno (not the
        // benign ENOTSUP/EINVAL fallback), so the flush failure is a real
        // pre-commit error — the swap must not publish unflushed data.
        let store = ConfigStore(
            storageDirectory: dir,
            flushSync: { _ in
                errno = EIO
                return -1
            })
        await #expect(throws: ConfigStore.StoreError.self) {
            _ = try await store.create(name: "unflushed", data: Data("x".utf8), labels: [:])
        }
        // Pre-commit failure: rolled back, fully retryable.
        #expect(await store.lookup(nameOrID: "unflushed") == nil)
        // The store itself stays usable — the failure is per-write.
        let healthy = ConfigStore(storageDirectory: dir)
        _ = try await healthy.create(name: "after", data: Data("x".utf8), labels: [:])
        #expect(await healthy.lookup(nameOrID: "after") != nil)
    }

    // MARK: - Boundaries

    @Test("the config store is independent of the secret store's directory")
    func storeDirectoryIsDistinct() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configStore = ConfigStore(storageDirectory: dir)
        let secretStore = SecretStore(storageDirectory: dir)
        _ = try await configStore.create(name: "shared-name", data: Data("config".utf8), labels: [:])
        _ = try await secretStore.create(
            name: "shared-name", data: Data("secret".utf8), driver: nil, labels: [:],
            driverOptions: [:], replace: false, ignore: false)
        // Same name, two stores, two payloads — neither sees the other.
        let config = await configStore.inspect(nameOrID: "shared-name")
        let secret = await secretStore.inspect(nameOrID: "shared-name", showSecret: true)
        #expect(config?.data == Data("config".utf8))
        #expect(secret?.payload == Data("secret".utf8))
        #expect(await configStore.list().count == 1)
        #expect(await secretStore.list().count == 1)
        // "shared-name" is valid in both namespaces: podman's secret charset
        // and swarmkit's config charset both allow it.
    }

    private func uniqueTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
