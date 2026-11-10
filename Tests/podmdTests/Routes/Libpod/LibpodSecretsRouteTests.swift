import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Route-level coverage for the libpod secrets family — `podman secret
/// create/ls/inspect/rm/exists` over the bindings client. Pins the podman
/// contract (`pkg/api/server/register_secrets.go` v5.4.0/v6):
///
/// - `POST /libpod/secrets/create` — options in query params (maps as JSON
///   strings, what bindings ToParams sends), RAW body as the payload, 200
///   `{"ID"}`; 409 on name-in-use (including a name equal to another
///   secret's full ID); podman's data-size/name validation (byte-based, Go
///   `len()` semantics); 400 on malformed map params; 500 when persisting
///   fails; bodies past Vapor's 16 KiB collect default accepted up to
///   podman's 512000-byte limit.
/// - `GET /libpod/secrets/json` — metadata only, never payloads; `name`/`id`
///   regex filters; unknown filter keys rejected.
/// - `GET /libpod/secrets/{name}/json` — plain libpod dialect (no Docker-compat
///   `Version` wrapper); `showsecret=true` is the ONLY payload reveal, served
///   RAW (podman's `secretToReportWithData` passes `string(data)` through).
/// - `GET /libpod/secrets/{name}/exists` — 204/404.
/// - `DELETE /libpod/secrets/{name}` — 204/404.
/// - The store survives re-instantiation from the same directory, with 0600
///   payload files (podman filedriver parity), and repairs interrupted
///   persists (orphan payload GC) on load.
@Suite("LibpodSecretsRoute")
struct LibpodSecretsRouteTests {

    // MARK: - Create

    @Test("create returns a 25-hex-char ID and persists the secret")
    func createReturnsID() async throws {
        try await withSecretsApp { app in
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=mysecret",
                body: ByteBuffer(string: "top-secret")
            ) { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretCreateReport.self, from: Data(buffer: res.body))
                #expect(report.ID.range(of: "^[0-9a-f]{25}$", options: .regularExpression) != nil)
            }
        }
    }

    @Test("create with labels and an explicit empty driver (podman's default fallback)")
    func createWithLabels() async throws {
        try await withSecretsApp { app in
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=labeled&driver=&labels=%7B%22team%22%3A%22core%22%7D",
                body: ByteBuffer(string: "x")
            ) { res async in
                #expect(res.status == .ok)
            }
            let body = try await inspectBody(app, "labeled")
            let report = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: body)
            #expect(report.Spec.Labels == ["team": "core"])
            #expect(report.Spec.Driver.Name == "file")
        }
    }

    @Test("malformed labels/driveropts JSON is a 400, not a silently empty map")
    func malformedMapParamsRejected() async throws {
        try await withSecretsApp { app in
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=x&labels=not-json",
                body: ByteBuffer(string: "x")
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("invalid JSON in labels"))
            }
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=x&driveropts=%7Bbroken",
                body: ByteBuffer(string: "x")
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("invalid JSON in driveropts"))
            }
        }
    }

    @Test("form-encoded '+' in map params decodes as space; %2B stays a literal plus")
    func plusDecodingInMapParams() async throws {
        try await withSecretsApp { app in
            // Podman's bindings QueryEscape map values: every space becomes
            // '+' (Go url.Values.Encode), so the server must read '+' as a
            // space (net/http url.ParseQuery semantics) while an explicit
            // %2B remains a real '+'.
            try await app.testing().test(
                .POST,
                "/v1.51/libpod/secrets/create?name=plus&labels=%7B%22k%22%3A%22x%2By%22%7D&driveropts=%7B%22owner%22%3A%22hello+world%22%7D",
                body: ByteBuffer(string: "x")
            ) { res async in
                #expect(res.status == .ok)
            }
            let report = try JSONDecoder().decode(
                LibpodSecretInfoReport.self, from: try await inspectBody(app, "plus")
            )
            #expect(report.Spec.Labels["k"] == "x+y")
            #expect(report.Spec.Driver.Options["owner"] == "hello world")
        }
    }

    @Test("duplicate name is 409 with podman's message")
    func duplicateNameIsConflict() async throws {
        try await withSecretsApp { app in
            try await createSecret(app, name: "dup", payload: "one")
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=dup",
                body: ByteBuffer(string: "two")
            ) { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("secret name in use"))
            }
        }
    }

    @Test("a name equal to another secret's full ID is 409 (podman's exactSecretExists checks IDs too)")
    func nameCollidingWithExistingIDRejected() async throws {
        try await withSecretsApp { app in
            let created = try await createSecret(app, name: "victim", payload: "x")
            // Creating a secret NAMED after an existing secret's ID would
            // make every later lookup of that name ambiguous — podman's
            // Store() treats it as name-in-use via exactSecretExists.
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=\(created.ID)",
                body: ByteBuffer(string: "y")
            ) { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("secret name in use"))
            }
            // The original secret is untouched — inspect by its ID still
            // resolves to it, not to any would-be shadow.
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/\(created.ID)/json") { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                #expect(report.Spec.Name == "victim")
            }
        }
    }

    @Test("replace=true re-stores under a fresh ID; ignore=true returns the existing ID")
    func replaceAndIgnoreSemantics() async throws {
        try await withSecretsApp { app in
            let first = try await createSecret(app, name: "swap", payload: "v1")
            // replace: new ID, new payload visible via showsecret
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=swap&replace=true",
                body: ByteBuffer(string: "v2")
            ) { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretCreateReport.self, from: Data(buffer: res.body))
                #expect(report.ID != first.ID)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/swap/json?showsecret=true") { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                #expect(report.SecretData == "v2")
            }
            // ignore: existing record, unchanged ID
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=swap&ignore=true",
                body: ByteBuffer(string: "v3")
            ) { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretCreateReport.self, from: Data(buffer: res.body))
                let current = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: try await inspectBody(app, "swap"))
                #expect(report.ID == current.ID)
            }
            // payload untouched by ignore: showsecret still reveals v2
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/swap/json?showsecret=true") { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                #expect(report.SecretData == "v2")
            }
        }
    }

    @Test("replace and ignore together are rejected")
    func replaceAndIgnoreConflict() async throws {
        try await withSecretsApp { app in
            try await createSecret(app, name: "either", payload: "x")
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=either&replace=true&ignore=true",
                body: ByteBuffer(string: "y")
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("cannot be used together"))
            }
        }
    }

    @Test("empty payload and oversize payload are 400 with podman's size rule")
    func payloadSizeValidation() async throws {
        try await withSecretsApp { app in
            try await app.testing().test(.POST, "/v1.51/libpod/secrets/create?name=empty", body: ByteBuffer(string: "")) {
                res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("larger than 0"))
            }
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=big",
                body: ByteBuffer(bytes: [UInt8](repeating: 0x61, count: SecretStore.maxSecretSize))
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("512000"))
            }
        }
    }

    @Test("invalid names are 400 (podman's charset/length rule)")
    func invalidNameRejected() async throws {
        try await withSecretsApp { app in
            try await app.testing().test(.POST, "/v1.51/libpod/secrets/create?name=bad%2Fname", body: ByteBuffer(string: "x")) {
                res async in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.POST, "/v1.51/libpod/secrets/create?name=a%3Db", body: ByteBuffer(string: "x")) {
                res async in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.POST, "/v1.51/libpod/secrets/create", body: ByteBuffer(string: "x")) { res async in
                #expect(res.status == .badRequest)  // missing name
            }
        }
    }

    @Test("name length is measured in UTF-8 bytes and forbidden chars in scalars (Go len()/ContainsAny semantics)")
    func byteBasedNameLimits() async throws {
        try await withSecretsApp { app in
            // 126 "é" = 252 UTF-8 bytes: legal.
            let legal = String(repeating: "%C3%A9", count: 126)
            try await app.testing().test(.POST, "/v1.51/libpod/secrets/create?name=\(legal)", body: ByteBuffer(string: "x")) {
                res async in
                #expect(res.status == .ok)
            }
            // 127 "é" = 254 bytes: one grapheme cluster under the old
            // Character-based count, but over the 253-BYTE limit Go enforces.
            let tooLong = String(repeating: "%C3%A9", count: 127)
            try await app.testing().test(.POST, "/v1.51/libpod/secrets/create?name=\(tooLong)", body: ByteBuffer(string: "x")) {
                res async in
                #expect(res.status == .badRequest)
            }
            // '/' + combining acute: ONE Swift grapheme cluster (so the old
            // Character-based forbidden-char check missed it), but its '/'
            // unicode scalar is forbidden.
            try await app.testing().test(.POST, "/v1.51/libpod/secrets/create?name=%2F%CC%81", body: ByteBuffer(string: "x")) {
                res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("a body past Vapor's 16 KiB collect default is accepted (podman allows up to 512000 bytes)")
    func largeBodyAccepted() async throws {
        // In-memory VaporTesting delivers pre-collected bodies, so the
        // collect(max:) cap only bites over a live socket — same approach
        // as the commit route's body-cap test.
        try await withSecretsApp(configure: { app in
            // configure.swift's daemon setting; must clear 16 KiB by far.
            app.routes.defaultMaxBodySize = "64mb"
        }) { app in
            let payload = String(repeating: "a", count: 300_000)
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/libpod/secrets/create?name=big",
                body: ByteBuffer(string: payload)
            ) { res async in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/big/json?showsecret=true") { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                #expect(report.SecretData == payload)
            }
        }
    }

    @Test("a persist failure answers 500 instead of a silent 200 (full disk etc.)")
    func persistFailureIs500() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretStore(storageDirectory: dir)
        let secretsDir = dir.appendingPathComponent("podm-secrets", isDirectory: true)
        try await withSecretsApp(store: store) { app in
            // Read-only metadata directory: the payload write (filedriver/
            // is a separate, still-writable dir) succeeds and the metadata
            // write fails — the mid-sequence failure persist() must surface.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: secretsDir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secretsDir.path) }
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=doomed",
                body: ByteBuffer(string: "x")
            ) { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("could not persist"))
            }
            // Direct store-level check: the same failure throws rather than
            // being logged and swallowed.
            await #expect(throws: SecretStore.StoreError.self) {
                try await store.create(
                    name: "direct", data: Data("x".utf8), driver: nil,
                    labels: [:], driverOptions: [:], replace: false, ignore: false
                )
            }
        }
    }

    @Test("unknown driver is rejected with the only-supported-driver reason")
    func unknownDriverRejected() async throws {
        try await withSecretsApp { app in
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=x&driver=pass",
                body: ByteBuffer(string: "x")
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("file driver"))
            }
        }
    }

    // MARK: - List

    @Test("list returns metadata only — the payload never rides along")
    func listIsMetadataOnly() async throws {
        try await withSecretsApp { app in
            try await createSecret(app, name: "alpha", payload: "alpha-payload")
            try await createSecret(app, name: "beta", payload: "beta-payload")
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/json") { res async throws in
                #expect(res.status == .ok)
                let reports = try JSONDecoder().decode([LibpodSecretInfoReport].self, from: Data(buffer: res.body))
                #expect(reports.count == 2)
                #expect(Set(reports.map(\.Spec.Name)) == ["alpha", "beta"])
                for report in reports {
                    #expect(report.Spec.Driver.Name == "file")
                    #expect(report.SecretData == nil)
                    #expect(!res.body.string.contains("alpha-payload"))
                    #expect(!res.body.string.contains("beta-payload"))
                }
            }
        }
    }

    @Test("list filters: name regex, id, and unknown keys rejected")
    func listFilters() async throws {
        try await withSecretsApp { app in
            let alpha = try await createSecret(app, name: "db-password", payload: "x")
            _ = try await createSecret(app, name: "api-key", payload: "y")
            // name filter (regex, anchored-style prefix match like podman)
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/json?filters=%7B%22name%22%3A%5B%22db-%2A%22%5D%7D") {
                res async throws in
                let reports = try JSONDecoder().decode([LibpodSecretInfoReport].self, from: Data(buffer: res.body))
                #expect(reports.map(\.Spec.Name) == ["db-password"])
            }
            // id filter
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/json?filters=%7B%22id%22%3A%5B%22\(alpha.ID)%22%5D%7D") {
                res async throws in
                let reports = try JSONDecoder().decode([LibpodSecretInfoReport].self, from: Data(buffer: res.body))
                #expect(reports.map(\.Spec.Name) == ["db-password"])
            }
            // unknown filter key
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/json?filters=%7B%22bogus%22%3A%5B%22x%22%5D%7D") {
                res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Inspect / exists

    @Test("inspect by name AND by exact ID; 404 for missing")
    func inspectByNameAndID() async throws {
        try await withSecretsApp { app in
            let created = try await createSecret(app, name: "lookup-me", payload: "seekrit")
            for reference in ["lookup-me", created.ID] {
                try await app.testing().test(.GET, "/v1.51/libpod/secrets/\(reference)/json") { res async throws in
                    #expect(res.status == .ok)
                    let report = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                    #expect(report.ID == created.ID)
                    #expect(report.Spec.Name == "lookup-me")
                    #expect(report.SecretData == nil, "inspect without showsecret must never reveal the payload")
                }
            }
            // Unambiguous ID prefix resolves (podman getNameAndID); a name can
            // never be shadowed by the prefix path.
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/\(String(created.ID.prefix(8)))/json") {
                res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                #expect(report.ID == created.ID)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/no-such/json") { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("no such secret"))
            }
        }
    }

    @Test("showsecret is the only reveal path, served RAW (podman serves string(data) unencoded)")
    func showSecretRevealsRawPayload() async throws {
        try await withSecretsApp { app in
            _ = try await createSecret(app, name: "reveal", payload: "seekrit")
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/reveal/json?showsecret=true") { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                #expect(report.SecretData == "seekrit")
            }
            // A podman-false value must not reveal
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/reveal/json?showsecret=false") { res async throws in
                let report = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                #expect(report.SecretData == nil)
            }
        }
    }

    @Test("exists answers 204/404")
    func existsSemantics() async throws {
        try await withSecretsApp { app in
            let created = try await createSecret(app, name: "here", payload: "x")
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/here/exists") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/\(created.ID)/exists") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/gone/exists") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    // MARK: - Remove

    @Test("remove deletes metadata AND payload; 404 when missing")
    func removeSemantics() async throws {
        try await withSecretsApp { app in
            _ = try await createSecret(app, name: "doomed", payload: "gone-soon")
            try await app.testing().test(.DELETE, "/v1.51/libpod/secrets/doomed") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/doomed/json") { res async in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.DELETE, "/v1.51/libpod/secrets/doomed") { res async in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/json") { res async throws in
                let reports = try JSONDecoder().decode([LibpodSecretInfoReport].self, from: Data(buffer: res.body))
                #expect(reports.isEmpty)
            }
        }
    }

    // MARK: - Persistence (podman filedriver parity)

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

    // MARK: - Helpers

    /// Boots a VaporTesting app with ONLY the libpod secrets collection
    /// registered, backed by a throwaway temp-dir store — never the daemon's
    /// real app-support directory. Pass `store` to control the backing
    /// directory (e.g. to make it unwritable), `configure` to adjust app
    /// settings (e.g. defaultMaxBodySize for live-socket tests).
    private func withSecretsApp(
        store providedStore: SecretStore? = nil,
        configure: ((Application) -> Void)? = nil,
        _ test: @escaping (Application) async throws -> Void
    ) async throws {
        var tempDir: URL?
        let store: SecretStore
        if let providedStore {
            store = providedStore
        } else {
            let dir = uniqueTempDir()
            tempDir = dir
            store = SecretStore(storageDirectory: dir)
        }
        defer { if let tempDir { try? FileManager.default.removeItem(at: tempDir) } }
        try await withApp(configure: { app in configure?(app) }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: LibpodSecretsRoute(store: store))
            try await test(app)
        }
    }

    @discardableResult
    private func createSecret(_ app: Application, name: String, payload: String) async throws -> LibpodSecretCreateReport {
        var created: LibpodSecretCreateReport?
        try await app.testing().test(
            .POST, "/v1.51/libpod/secrets/create?name=\(name)",
            body: ByteBuffer(string: payload)
        ) { res async throws in
            #expect(res.status == .ok, "seed create of \(name) failed: \(res.body.string)")
            created = try JSONDecoder().decode(LibpodSecretCreateReport.self, from: Data(buffer: res.body))
        }
        guard let created else { throw Abort(.internalServerError, reason: "seed create of \(name) produced no report") }
        return created
    }

    private func inspectBody(_ app: Application, _ name: String) async throws -> Data {
        var body: Data?
        try await app.testing().test(.GET, "/v1.51/libpod/secrets/\(name)/json") { res async throws in
            #expect(res.status == .ok)
            body = Data(buffer: res.body)
        }
        guard let body else { throw Abort(.internalServerError, reason: "inspect of \(name) produced no body") }
        return body
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
}

private func uniqueTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir

}
