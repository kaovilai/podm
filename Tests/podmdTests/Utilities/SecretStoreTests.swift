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
        let listed = try await store.list()
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
        let listed = try await store.list()
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
        let listed = try await store.list()
        #expect(listed.isEmpty)
        let payloadFiles = try FileManager.default.contentsOfDirectory(atPath: filedriverDir.path)
        #expect(payloadFiles.contains { $0.hasPrefix("secretsdata.json.corrupt-") }, "payloads quarantined")
        #expect(!FileManager.default.fileExists(atPath: filedriverDir.appendingPathComponent("secretsdata.json").path))
    }

    private func uniqueTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
