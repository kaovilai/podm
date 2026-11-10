import Foundation
import Testing

@testable import podmd

/// SecretStore semantics beyond the HTTP surface: load-time repair, lookup
/// resolution, single-hop reads, persistence, and corrupt-file quarantine.
@Suite("SecretStore")
struct SecretStoreTests {
    @Test("an interrupted persist leaves only orphan payloads, which load prunes")
    func loadRepairsOrphanPayloads() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = SecretStore(storageDirectory: dir)  // creates the directory layout

        // Crash mid-persist after the payload write but before the metadata
        // write: the payload file gains an entry no metadata references.
        let real = StoredSecret(
            id: "aaaaaaaaaaaaaaaaaaaaaaaaa", name: "real", createdAt: Date(), updatedAt: Date(),
            labels: [:], driver: "file", driverOptions: [:]
        )
        let encoder = JSONEncoder()
        try encoder.encode([real]).write(
            to: dir.appendingPathComponent("podm-secrets/secrets.json"), options: .atomic
        )
        try encoder.encode([
            "aaaaaaaaaaaaaaaaaaaaaaaaa": Data("real-data".utf8),
            "bbbbbbbbbbbbbbbbbbbbbbbbb": Data("orphan-data".utf8),
        ]).write(
            to: dir.appendingPathComponent("podm-secrets/filedriver/secretsdata.json"), options: .atomic
        )

        let store = SecretStore(storageDirectory: dir)
        #expect(await store.payload(id: "bbbbbbbbbbbbbbbbbbbbbbbbb") == nil, "orphaned payload must be pruned on load")
        #expect(await store.payload(id: "aaaaaaaaaaaaaaaaaaaaaaaaa") == Data("real-data".utf8))
        #expect(await store.lookup(nameOrID: "real")?.id == "aaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    @Test("a metadata record with no payload is kept, not dropped (podman keeps dangling records)")
    func loadKeepsDanglingMetadata() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = SecretStore(storageDirectory: dir)

        // Only reachable by hand-mangling the store (persist's ordering
        // cannot produce it); podman's driver.Lookup fails for such records
        // while ls/inspect still answer, so the record must survive load.
        let ghost = StoredSecret(
            id: "ccccccccccccccccccccccccc", name: "ghost", createdAt: Date(), updatedAt: Date(),
            labels: [:], driver: "file", driverOptions: [:]
        )
        try JSONEncoder().encode([ghost]).write(
            to: dir.appendingPathComponent("podm-secrets/secrets.json"), options: .atomic
        )
        try JSONEncoder().encode([String: Data]()).write(
            to: dir.appendingPathComponent("podm-secrets/filedriver/secretsdata.json"), options: .atomic
        )

        let store = SecretStore(storageDirectory: dir)
        #expect(await store.lookup(nameOrID: "ghost")?.name == "ghost")
        #expect(await store.payload(id: "ccccccccccccccccccccccccc") == nil)
    }

    @Test("lookup resolves an exact full ID before a name (podman getExactNameAndID)")
    func lookupPrefersIDOverName() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = SecretStore(storageDirectory: dir)

        // A hand-mangled store where B's NAME equals A's ID — exactly the
        // collision create() now refuses (409). ID-first lookup still
        // resolves it deterministically, like podman's IDToName-before-
        // NameToID consultation order.
        let aID = "aaaaaaaaaaaaaaaaaaaaaaaaa"
        let a = StoredSecret(
            id: aID, name: "alpha", createdAt: Date(), updatedAt: Date(),
            labels: [:], driver: "file", driverOptions: [:]
        )
        let b = StoredSecret(
            id: "ddddddddddddddddddddddddd", name: aID, createdAt: Date(), updatedAt: Date(),
            labels: [:], driver: "file", driverOptions: [:]
        )
        try JSONEncoder().encode([a, b]).write(
            to: dir.appendingPathComponent("podm-secrets/secrets.json"), options: .atomic
        )

        let store = SecretStore(storageDirectory: dir)
        #expect(await store.lookup(nameOrID: aID)?.id == aID)
        #expect(await store.lookup(nameOrID: "alpha")?.id == aID)
    }

    @Test("inspect returns metadata and payload in one actor hop")
    func singleHopInspect() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretStore(storageDirectory: dir)
        let created = try await store.create(
            name: "one-hop", data: Data("seekrit".utf8), driver: nil,
            labels: [:], driverOptions: [:], replace: false, ignore: false
        )
        let revealed = await store.inspect(nameOrID: "one-hop", showSecret: true)
        #expect(revealed?.secret.id == created.id)
        #expect(revealed?.payload == Data("seekrit".utf8))
        let hidden = await store.inspect(nameOrID: created.id, showSecret: false)
        #expect(hidden?.secret.id == created.id)
        #expect(hidden?.payload == nil)
        #expect(await store.inspect(nameOrID: "no-such", showSecret: true) == nil)
    }

    @Test("a corrupt store file is quarantined aside, not silently overwritten")
    func corruptFileQuarantined() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("secret-quarantine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Write garbage where the metadata belongs.
        let metadata = dir.appendingPathComponent("podm-secrets").appendingPathComponent("secrets.json")
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: metadata)

        let store = SecretStore(storageDirectory: dir)
        // Loading starts empty; the corrupt file must have been moved aside.
        let listed = await store.list()
        #expect(listed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: metadata.path), "original name freed for the next persist")
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: metadata.deletingLastPathComponent().path
        )
        .filter { $0.hasPrefix("secrets.json.corrupt-") }
        #expect(backups.count == 1, "corrupt data preserved for manual recovery")
    }

    @Test("a metadata quarantine also quarantines the payloads — the pair stays recoverable")
    func metadataFailureQuarantinesPayloadsToo() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let podmDir = dir.appendingPathComponent("podm-secrets")
        let filedriverDir = podmDir.appendingPathComponent("filedriver")
        try FileManager.default.createDirectory(at: filedriverDir, withIntermediateDirectories: true)
        // Corrupt metadata + healthy payloads on disk.
        try Data("garbage".utf8).write(to: podmDir.appendingPathComponent("secrets.json"))
        try Data("{\"someid\": \"c29tZWRhdGE=\"}".utf8)
            .write(to: filedriverDir.appendingPathComponent("secretsdata.json"))

        let store = SecretStore(storageDirectory: dir)
        let listed = await store.list()
        #expect(listed.isEmpty)
        let metaFiles = try FileManager.default.contentsOfDirectory(atPath: podmDir.path)
        #expect(metaFiles.contains { $0.hasPrefix("secrets.json.corrupt-") }, "metadata quarantined")
        let payloadFiles = try FileManager.default.contentsOfDirectory(atPath: filedriverDir.path)
        #expect(payloadFiles.contains { $0.hasPrefix("secretsdata.json.corrupt-") }, "payloads quarantined with it")
    }

    @Test("secrets survive store re-instantiation from the same directory, with 0600 payload files")
    func persistenceAndPermissions() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = SecretStore(storageDirectory: dir)
        let created = try await first.create(name: "persistent", data: Data("survives".utf8), driver: nil, labels: [:], driverOptions: [:], replace: false, ignore: false)
        let second = SecretStore(storageDirectory: dir)
        let reloaded = await second.lookup(nameOrID: "persistent")
        #expect(reloaded?.id == created.id)
        let payload = await second.payload(id: created.id)
        #expect(payload == Data("survives".utf8))

        let payloadFile = dir.appendingPathComponent("podm-secrets/filedriver/secretsdata.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: payloadFile.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600, "secret payloads must be owner-only readable (podman filedriver 0o600)")
        let metadataFile = dir.appendingPathComponent("podm-secrets/secrets.json")
        let metaAttrs = try FileManager.default.attributesOfItem(atPath: metadataFile.path)
        #expect((metaAttrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test("a corrupt payload file alone is quarantined (metadata healthy)")
    func corruptPayloadAloneQuarantined() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("secret-payload-quarantine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let podmDir = dir.appendingPathComponent("podm-secrets")
        let filedriverDir = podmDir.appendingPathComponent("filedriver")
        try FileManager.default.createDirectory(at: filedriverDir, withIntermediateDirectories: true)
        // Healthy metadata, garbage payloads.
        try Data("[]".utf8).write(to: podmDir.appendingPathComponent("secrets.json"))
        try Data("garbage".utf8).write(to: filedriverDir.appendingPathComponent("secretsdata.json"))

        let store = SecretStore(storageDirectory: dir)
        let listed = await store.list()
        #expect(listed.isEmpty)
        let payloadFiles = try FileManager.default.contentsOfDirectory(atPath: filedriverDir.path)
        #expect(payloadFiles.contains { $0.hasPrefix("secretsdata.json.corrupt-") }, "payloads quarantined")
        #expect(!FileManager.default.fileExists(atPath: filedriverDir.appendingPathComponent("secretsdata.json").path))
    }

    @Test("a quarantine that cannot move the file logs and leaves it in place")
    func failedQuarantineMoveLeavesFileInPlace() async throws {
        let dir = uniqueTempDir()
        let podmDir = dir.appendingPathComponent("podm-secrets")
        let filedriverDir = podmDir.appendingPathComponent("filedriver")
        try FileManager.default.createDirectory(at: filedriverDir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: podmDir.appendingPathComponent("secrets.json"))
        try Data("garbage".utf8).write(to: filedriverDir.appendingPathComponent("secretsdata.json"))
        // Deny write on BOTH store directories — either quarantine rename
        // would succeed against a writable dir (we are not root, so a
        // read-only dir blocks the rename), exercising the catch branch.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: podmDir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: filedriverDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: podmDir.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: filedriverDir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let store = SecretStore(storageDirectory: dir)
        #expect(await store.list().isEmpty, "load still starts empty")
        // Neither file could be moved aside — both remain under their
        // original names.
        #expect(FileManager.default.fileExists(atPath: podmDir.appendingPathComponent("secrets.json").path))
        #expect(
            FileManager.default.fileExists(atPath: filedriverDir.appendingPathComponent("secretsdata.json").path))
        let metaFiles = try FileManager.default.contentsOfDirectory(atPath: podmDir.path)
        #expect(!metaFiles.contains { $0.hasPrefix("secrets.json.corrupt-") })

        // Mutations are REFUSED while the unreadable files sit under their
        // original names — persisting would overwrite the only copy.
        do {
            _ = try await store.create(
                name: "blocked", data: Data("x".utf8), driver: nil,
                labels: [:], driverOptions: [:], replace: false, ignore: false
            )
            Issue.record("create must be refused on a store whose quarantine failed")
        } catch SecretStore.StoreError.quarantineBlocked {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // Even with the permissions fixed, THIS instance stays blocked —
        // the flag is load-time; only a restart (after the operator
        // resolves the files) clears it.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: podmDir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: filedriverDir.path)
        do {
            _ = try await store.create(
                name: "still-blocked", data: Data("x".utf8), driver: nil,
                labels: [:], driverOptions: [:], replace: false, ignore: false
            )
            Issue.record("create must stay refused until the daemon restarts")
        } catch SecretStore.StoreError.quarantineBlocked {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // The operator resolves the files; a fresh instance works again.
        try FileManager.default.removeItem(at: podmDir.appendingPathComponent("secrets.json"))
        try FileManager.default.removeItem(at: filedriverDir.appendingPathComponent("secretsdata.json"))
        let recovered = SecretStore(storageDirectory: dir)
        _ = try await recovered.create(
            name: "fresh", data: Data("x".utf8), driver: nil,
            labels: [:], driverOptions: [:], replace: false, ignore: false
        )
        #expect(await recovered.lookup(nameOrID: "fresh") != nil)
    }

    @Test("a replace whose metadata write fails rolls back to the old secret (superset invariant)")
    func failedReplaceRollsBackToOldSecret() async throws {
        let dir = uniqueTempDir()
        let podmDir = dir.appendingPathComponent("podm-secrets")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: podmDir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = SecretStore(storageDirectory: dir)
        let original = try await store.create(
            name: "orig", data: Data("old-data".utf8), driver: nil,
            labels: [:], driverOptions: [:], replace: false, ignore: false
        )
        // Read-only metadata dir, writable payload dir: the replace's
        // transitional payload write (old ∪ new) LANDS, the metadata write
        // fails — the branch where keeping the replacement in memory would
        // let a later mutation drop the old payload while the on-disk
        // metadata still references it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: podmDir.path)
        await #expect(throws: SecretStore.StoreError.self) {
            _ = try await store.create(
                name: "orig", data: Data("new-data".utf8), driver: nil,
                labels: [:], driverOptions: [:], replace: true, ignore: false
            )
        }
        // Rollback: the OLD secret is intact in memory, same ID, same payload.
        let afterFailure = await store.inspect(nameOrID: "orig", showSecret: true)
        #expect(afterFailure?.secret.id == original.id)
        #expect(afterFailure?.payload == Data("old-data".utf8))

        // "Crash" + reload: the transitional payload entry is an orphan the
        // load prunes; the old secret survives whole.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: podmDir.path)
        let reloaded = SecretStore(storageDirectory: dir)
        let revealed = await reloaded.inspect(nameOrID: "orig", showSecret: true)
        #expect(revealed?.secret.id == original.id)
        #expect(revealed?.payload == Data("old-data".utf8))
        let listed = await reloaded.list()
        #expect(listed.count == 1)
    }

    @Test("a remove whose payload trim fails keeps the committed deletion and answers success")
    func failedRemoveTrimKeepsDeletion() async throws {
        let dir = uniqueTempDir()
        let filedriverDir = dir.appendingPathComponent("podm-secrets/filedriver")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: filedriverDir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = SecretStore(storageDirectory: dir)
        let created = try await store.create(
            name: "half-removed", data: Data("leftover".utf8), driver: nil,
            labels: [:], driverOptions: [:], replace: false, ignore: false
        )
        // Read-only PAYLOAD dir, writable metadata dir: remove's metadata
        // write commits the deletion, the payload trim fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: filedriverDir.path)
        // The deletion committed — it is reported as the success it is;
        // answering an error would make the client retry a delete that
        // already happened (404).
        let removed = try await store.remove(nameOrID: "half-removed")
        #expect(removed?.name == "half-removed")
        #expect(await store.lookup(nameOrID: "half-removed") == nil)
        // "Crash" + reload: the metadata no longer references the secret;
        // the un-trimmed payload entry is an orphan that load prunes —
        // the secret must NOT resurrect.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: filedriverDir.path)
        let reloaded = SecretStore(storageDirectory: dir)
        #expect(await reloaded.lookup(nameOrID: "half-removed") == nil)
        #expect(await reloaded.payload(id: created.id) == nil)
        #expect(await reloaded.list().isEmpty)
    }

    @Test("pre-existing loose permissions are tightened on load (other local users must not reach the store)")
    func loosePreexistingPermissionsTightened() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let podmDir = dir.appendingPathComponent("podm-secrets")
        let filedriverDir = podmDir.appendingPathComponent("filedriver")
        // Directories and files as a previous build or a restored backup
        // with a loose umask could have left them: group/world bits set.
        // Directory write permission is what would let another local user
        // replace or delete the store files.
        try FileManager.default.createDirectory(
            at: filedriverDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o775])
        let metadata = podmDir.appendingPathComponent("secrets.json")
        try Data("[]".utf8).write(to: metadata)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: metadata.path)
        let payloads = filedriverDir.appendingPathComponent("secretsdata.json")
        try Data("garbage".utf8).write(to: payloads)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: payloads.path)

        _ = SecretStore(storageDirectory: dir)  // load also quarantines the garbage payload

        func groupOtherBits(_ path: String) throws -> Int {
            let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! Int
            return perms & 0o077
        }
        #expect(try groupOtherBits(podmDir.path) == 0, "store directory must lose group/world bits")
        #expect(try groupOtherBits(filedriverDir.path) == 0, "payload directory must lose group/world bits")
        #expect(try groupOtherBits(metadata.path) == 0, "metadata file must lose group/world bits")
        // The quarantine backup holds secret payloads — owner-only too.
        let backups = try FileManager.default.contentsOfDirectory(atPath: filedriverDir.path)
            .filter { $0.hasPrefix("secretsdata.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(try groupOtherBits(filedriverDir.appendingPathComponent(backups[0]).path) == 0)
    }

    @Test("a store directory that cannot be secured blocks mutations")
    func unsecurableDirectoryBlocksMutations() async throws {
        let dir = uniqueTempDir()
        let podmDir = dir.appendingPathComponent("podm-secrets")
        let filedriverDir = podmDir.appendingPathComponent("filedriver")
        try FileManager.default.createDirectory(
            at: filedriverDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o775])
        // Lock the directory's mode (user-immutable): chmod now fails even
        // for the owning user, so init cannot strip the group bits.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: podmDir.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: podmDir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let store = SecretStore(storageDirectory: dir)
        do {
            _ = try await store.create(
                name: "blocked", data: Data("x".utf8), driver: nil,
                labels: [:], driverOptions: [:], replace: false, ignore: false
            )
            Issue.record("create must be refused while the store directory cannot be secured")
        } catch SecretStore.StoreError.quarantineBlocked {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // The mode lock released, a fresh instance secures the directory
        // and works.
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: podmDir.path)
        let recovered = SecretStore(storageDirectory: dir)
        _ = try await recovered.create(
            name: "fresh", data: Data("x".utf8), driver: nil,
            labels: [:], driverOptions: [:], replace: false, ignore: false
        )
        #expect(await recovered.lookup(nameOrID: "fresh") != nil)
        let perms =
            try FileManager.default.attributesOfItem(atPath: podmDir.path)[.posixPermissions] as! Int
        #expect(perms & 0o077 == 0, "the recovered instance tightened the directory")
    }

    @Test("a mode-locked store file fails the swap pre-commit — rollback stays correct")
    func lockedMetadataFileFailsPreCommit() async throws {
        let dir = uniqueTempDir()
        let metadata = dir.appendingPathComponent("podm-secrets/secrets.json")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metadata.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = SecretStore(storageDirectory: dir)
        _ = try await store.create(
            name: "locked", data: Data("x".utf8), driver: nil,
            labels: [:], driverOptions: [:], replace: false, ignore: false
        )
        // Lock the METADATA file's mode (user-immutable): the atomic
        // replace itself now fails — strictly BEFORE any data swap — so
        // the mutation is a safe pre-commit failure and the rollback must
        // keep the secret fully retryable. (This pins writeJSON's failure
        // ordering contract: nothing may throw after the swap commits.)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: metadata.path)
        await #expect(throws: SecretStore.StoreError.self) {
            _ = try await store.remove(nameOrID: "locked")
        }
        #expect(await store.lookup(nameOrID: "locked") != nil, "pre-commit failure must roll back")
        // Released, the retry goes through.
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metadata.path)
        _ = try await store.remove(nameOrID: "locked")
        #expect(await store.lookup(nameOrID: "locked") == nil)
    }

    @Test("canonically-equivalent names are DISTINCT secrets (Go byte equality, not Swift ==)")
    func unicodeNameEquivalenceIsByteWise() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretStore(storageDirectory: dir)
        // "café" in NFC and NFD: Swift's == calls them equal; Go (podman's
        // name maps and string equality) compares UTF-8 bytes and keeps
        // them distinct. They must be two separate secrets.
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        #expect(nfc == nfd, "sanity: Swift folds these — the store must not")
        let first = try await store.create(
            name: nfc, data: Data("one".utf8), driver: nil,
            labels: [:], driverOptions: [:], replace: false, ignore: false
        )
        let second = try await store.create(
            name: nfd, data: Data("two".utf8), driver: nil,
            labels: [:], driverOptions: [:], replace: false, ignore: false
        )
        #expect(first.id != second.id, "an NFD name must not collide with the NFC secret")
        #expect(await store.lookup(nameOrID: nfc)?.id == first.id)
        #expect(await store.lookup(nameOrID: nfd)?.id == second.id)
        // Replacing the NFD secret must not touch the NFC one.
        let third = try await store.create(
            name: nfd, data: Data("three".utf8), driver: nil,
            labels: [:], driverOptions: [:], replace: true, ignore: false
        )
        #expect(third.id != first.id)
        #expect(await store.lookup(nameOrID: nfc)?.id == first.id, "a byte-distinct secret must never be overwritten")
        #expect(await store.list().count == 2)
    }

    @Test("interrupted-persist temp files are swept on load")
    func crashLeftoverTempFilesSwept() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let podmDir = dir.appendingPathComponent("podm-secrets")
        let filedriverDir = podmDir.appendingPathComponent("filedriver")
        try FileManager.default.createDirectory(at: filedriverDir, withIntermediateDirectories: true)
        // A crash between temp creation and the swap leaves these behind.
        try Data("garbage".utf8).write(to: podmDir.appendingPathComponent(".secrets.json.tmp-AAAA"))
        try Data("garbage".utf8).write(to: filedriverDir.appendingPathComponent(".secretsdata.json.tmp-BBBB"))
        // A quarantine backup must NOT be swept.
        let backup = podmDir.appendingPathComponent("secrets.json.corrupt-123")
        try Data("recoverable".utf8).write(to: backup)

        _ = SecretStore(storageDirectory: dir)

        #expect(!FileManager.default.fileExists(atPath: podmDir.appendingPathComponent(".secrets.json.tmp-AAAA").path))
        #expect(
            !FileManager.default.fileExists(atPath: filedriverDir.appendingPathComponent(".secretsdata.json.tmp-BBBB").path))
        #expect(FileManager.default.fileExists(atPath: backup.path), "quarantine backups hold recoverable data")
    }

    private func uniqueTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
