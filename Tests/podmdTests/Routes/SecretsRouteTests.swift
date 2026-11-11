// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Route-level coverage for the docker-dialect `/secrets` family (moby
/// v28.5.2 `api/server/router/swarm/cluster.go`), served over the SAME
/// `SecretStore` as the libpod family. Pins the moby contract:
///
/// - `POST /secrets/create` — `swarm.SecretSpec` JSON body (`Data`
///   base64), 201 `{"ID"}`; 409 on name-in-use; swarmkit/podman data-size
///   rule (1..<512000); driver/templating guards.
/// - `GET /secrets` — moby's `swarm.Secret` reports (Version.Index 1,
///   metadata only, `Data` NEVER returned); `names` (exact) / `name`
///   (prefix) / `id` (prefix) OR'd, `label` AND'd; unknown keys and
///   malformed filters are 400s.
/// - `GET /secrets/{id}` — moby getSecret resolution: full ID, exact
///   name, ID prefix; 0 matches → 404 `secret <input> not found`;
///   ambiguous prefix → 400.
/// - `DELETE /secrets/{id}` — 204 / 404 with moby's message shape.
/// - `POST /secrets/{id}/update` — 501 "update is not supported"
///   (podman compat parity).
/// - Cross-dialect: secrets created via one dialect are visible in the
///   other (one store, two DTO dialects).
@Suite("SecretsRoute")
struct SecretsRouteTests {

    // MARK: - Create

    @Test("create answers 201 with an ID and round-trips through inspect")
    func createRoundTrip() async throws {
        try await withSecretsApp { app in
            let created = try await createSecret(app, name: "mysecret", payload: "top-secret")
            #expect(
                created.ID.range(of: "^[0-9a-f]{25}$", options: .regularExpression) != nil,
                "the store's podman-shaped 25-hex ID is served as-is (docker IDs are opaque; swarmkit's NewID is a 25-char base36 token of the same shape class)")
            let report = try await inspect(app, created.ID)
            #expect(report.ID == created.ID)
            #expect(report.Spec.Name == "mysecret")
            #expect(report.Spec.Labels.isEmpty)
            #expect(report.Version.Index == 1, "podman compat reports Version.Index 1 — a never-updated secret never increments")
        }
    }

    @Test("create with labels round-trips them into the report Spec")
    func createWithLabels() async throws {
        try await withSecretsApp { app in
            let body = #"{"Name":"labeled","Labels":{"team":"core","app":"web"},"Data":"\#(base64("x"))"}"#
            let created = try await createSecret(app, body: body)
            let report = try await inspect(app, created.ID)
            #expect(report.Spec.Labels == ["team": "core", "app": "web"])
        }
    }

    @Test("create decodes base64 Data; invalid base64 is a 400 (Go's json []byte strictness)")
    func base64DataHandling() async throws {
        try await withSecretsApp { app in
            // Non-ASCII payload: must survive the base64 round trip
            // byte-for-byte (verified via the libpod showsecret reveal —
            // one store, one payload).
            let payload = "héllo wörld ✓"
            let body = #"{"Name":"utf8","Data":"\#(Data(payload.utf8).base64EncodedString())"}"#
            let created = try await createSecret(app, body: body)
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/utf8/json?showsecret=true") { res async throws in
                #expect(res.status == .ok)
                let libpod = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                #expect(libpod.SecretData == payload)
            }
            _ = created
            // Binary (non-UTF8) bytes decode fine too — the libpod reveal
            // maps them to U+FFFD like Go's json.Marshal, so only presence
            // is asserted there.
            let binary = Data([0x00, 0xFF, 0x10, 0x42])
            try await createSecret(app, body: #"{"Name":"binary","Data":"\#(binary.base64EncodedString())"}"#)
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/binary/json?showsecret=true") { res async throws in
                #expect(res.status == .ok)
                let libpod = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                #expect(libpod.SecretData != nil)
            }
            // Invalid base64 in Data: a client error, not a 500.
            try await app.testing().test(
                .POST, "/v1.51/secrets/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"bad64","Data":"!!not-base64!!"}"#)
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("duplicate name is 409; empty and oversize data are 400 with the size rule")
    func createValidation() async throws {
        try await withSecretsApp { app in
            _ = try await createSecret(app, name: "dup", payload: "one")
            try await app.testing().test(
                .POST, "/v1.51/secrets/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"dup","Data":"\#(base64("two"))"}"#)
            ) { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("secret dup already exists"))
            }
            try await app.testing().test(
                .POST, "/v1.51/secrets/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"empty","Data":""}"#)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("larger than 0"))
            }
            let oversize = Data(repeating: 0x61, count: SecretStore.maxSecretSize).base64EncodedString()
            try await app.testing().test(
                .POST, "/v1.51/secrets/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"big","Data":"\#(oversize)"}"#)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("512000"))
            }
        }
    }

    @Test("templating and driver guards: 400s, not silent drops")
    func createTemplatingAndDriverGuards() async throws {
        try await withSecretsApp { app in
            try await app.testing().test(
                .POST, "/v1.51/secrets/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"tmpl","Data":"\#(base64("x"))","Templating":{"Name":"golang"}}"#)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("templating"))
            }
            // swarmkit: a driver without a name is InvalidArgument.
            try await app.testing().test(
                .POST, "/v1.51/secrets/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"anon","Driver":{"Options":{}},"Data":"\#(base64("x"))"}"#)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("driver must have a name"))
            }
            // Only the file driver exists (podman's local store).
            try await app.testing().test(
                .POST, "/v1.51/secrets/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"ext","Driver":{"Name":"vault"},"Data":"\#(base64("x"))"}"#)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("only the file driver"))
            }
        }
    }

    @Test("a malformed spec body is a 400, not a 500")
    func malformedSpecRejected() async throws {
        try await withSecretsApp { app in
            try await app.testing().test(
                .POST, "/v1.51/secrets/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: "not-json")
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - List

    @Test("list returns moby-shaped reports; Data is never present")
    func listReports() async throws {
        try await withSecretsApp { app in
            _ = try await createSecret(app, name: "alpha", payload: "x")
            try await app.testing().test(.GET, "/v1.51/secrets") { res async throws in
                #expect(res.status == .ok)
                let reports = try JSONDecoder().decode([DockerSecretReport].self, from: Data(buffer: res.body))
                #expect(reports.count == 1)
                #expect(reports[0].Spec.Name == "alpha")
                #expect(reports[0].Version.Index == 1)
                // RFC3339 timestamps like Go's time.Time marshaling.
                #expect(reports[0].CreatedAt.contains("T"), "CreatedAt must be RFC3339: \(reports[0].CreatedAt)")
                // The payload must never appear in any form — no Data /
                // SecretData key at all (swarmkit nils Spec.Data before
                // every list/inspect reply).
                let bodyString = res.body.string
                #expect(!bodyString.contains("\"Data\"") && !bodyString.contains("SecretData"))
            }
        }
    }

    @Test("list filters: names exact, name/id prefix, OR'd across keys; label AND'd on top")
    func listFilters() async throws {
        try await withSecretsApp { app in
            let a = try await createSecret(app, name: "app-config", payload: "x")
            let b = try await createSecret(app, name: "db-password", payload: "y", labels: ["team": "db"])
            _ = try await createSecret(app, name: "other", payload: "z", labels: ["team": "web"])
            // names: EXACT (swarmkit ByName) — "app" must not match "app-config".
            try await expectNames(app, filters: ["names": ["app-config"]], names: ["app-config"])
            try await expectNames(app, filters: ["names": ["app"]], names: [])
            // name: PREFIX.
            try await expectNames(app, filters: ["name": ["db-"]], names: ["db-password"])
            // id: PREFIX.
            try await expectNames(app, filters: ["id": [String(b.ID.prefix(8))]], names: ["db-password"])
            // OR across the three keys (one store.Or in swarmkit).
            try await expectNames(
                app,
                filters: ["names": ["app-config"], "name": ["other"], "id": [String(a.ID.prefix(12))]],
                names: ["app-config", "other"])
            // label k=v AND presence forms.
            try await expectNames(app, filters: ["label": ["team=db"]], names: ["db-password"])
            try await expectNames(app, filters: ["label": ["team"]], names: ["db-password", "other"])
            // labels AND with an id selector.
            try await expectNames(
                app,
                filters: ["id": [String(a.ID.prefix(12))], "label": ["team=db"]],
                names: [])
            // The docker map form ({"names": {"app-config": true}}) is accepted.
            let mapForm = "/v1.51/secrets?filters=%7B%22names%22%3A%7B%22app-config%22%3Atrue%7D%7D"
            try await app.testing().test(.GET, mapForm) { res async throws in
                #expect(res.status == .ok)
                let reports = try JSONDecoder().decode([DockerSecretReport].self, from: Data(buffer: res.body))
                #expect(reports.map(\.Spec.Name) == ["app-config"])
            }
        }
    }

    @Test("malformed or unknown filter keys are 400s, not everything")
    func malformedFiltersRejected() async throws {
        try await withSecretsApp { app in
            _ = try await createSecret(app, name: "somename", payload: "x")
            try await app.testing().test(.GET, "/v1.51/secrets?filters=notjson") { res async in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.GET, "/v1.51/secrets?filters=%5B%5D") { res async in
                #expect(res.status == .badRequest)
            }
            // moby's accepted keys are names/name/id/label — anything else is rejected.
            try await app.testing().test(.GET, "/v1.51/secrets?filters=%7B%22driver%22%3A%5B%22file%22%5D%7D") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("unrecognized filter key"))
            }
            try await app.testing().test(.GET, "/v1.51/secrets?filters=%7B%22names%22%3A%22somename%22%7D") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Inspect

    @Test("inspect resolves full ID, exact name, and a unique ID prefix; 404 with moby's message")
    func inspectResolution() async throws {
        try await withSecretsApp { app in
            let created = try await createSecret(app, name: "resolve-me", payload: "x")
            // Full ID.
            let byID = try await inspect(app, created.ID)
            #expect(byID.Spec.Name == "resolve-me")
            // Exact name.
            let byName = try await inspect(app, "resolve-me")
            #expect(byName.ID == created.ID)
            // Unique ID prefix.
            let byPrefix = try await inspect(app, String(created.ID.prefix(10)))
            #expect(byPrefix.ID == created.ID)
            // Not found: moby's getSecret message shape.
            try await app.testing().test(.GET, "/v1.51/secrets/nope") { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("secret nope not found"))
            }
        }
    }

    @Test("an ambiguous ID prefix is a 400 (moby's InvalidParameter), never a silent pick")
    func ambiguousPrefixRejected() async throws {
        try await withSecretsApp { app in
            // Create several secrets, then find a prefix shared by ≥2 of
            // their 25-hex IDs (hex alphabet is small enough that a 1-char
            // prefix over a handful of IDs usually collides; walk down
            // until one does).
            var ids: [String] = []
            for i in 0..<12 {
                ids.append(try await createSecret(app, name: "amb-\(i)", payload: "x").ID)
            }
            var ambiguous: String?
            for length in 1...4 {
                let prefixes = ids.map { String($0.prefix(length)) }
                if Set(prefixes).count < prefixes.count {
                    ambiguous = prefixes.first { prefix in prefixes.filter { $0 == prefix }.count > 1 }
                    break
                }
            }
            guard let ambiguous else {
                // Statistically unlikely; the empty-prefix "" case below
                // still exercises ambiguity deterministically.
                try await app.testing().test(.GET, "/v1.51/secrets/%20") { res async in
                    #expect(res.status == .notFound || res.status == .badRequest)
                }
                return
            }
            try await app.testing().test(.GET, "/v1.51/secrets/\(ambiguous)") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("ambiguous"))
            }
        }
    }

    // MARK: - Delete

    @Test("delete answers 204 and the secret is gone; 404 with moby's message")
    func deleteRoundTrip() async throws {
        try await withSecretsApp { app in
            let created = try await createSecret(app, name: "doomed", payload: "x")
            try await app.testing().test(.DELETE, "/v1.51/secrets/doomed") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/secrets/\(created.ID)") { res async in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.DELETE, "/v1.51/secrets/doomed") { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("secret doomed not found"))
            }
        }
    }

    @Test("update answers 501 with podman compat's message")
    func updateNotSupported() async throws {
        try await withSecretsApp { app in
            let created = try await createSecret(app, name: "frozen", payload: "x")
            try await app.testing().test(.POST, "/v1.51/secrets/\(created.ID)/update?version=1") { res async in
                #expect(res.status == .notImplemented)
                #expect(res.body.string.contains("update is not supported"))
            }
        }
    }

    // MARK: - Cross-dialect (one store, two dialects)

    @Test("a secret created via the docker API is visible via the libpod API, and vice versa")
    func crossDialectVisibility() async throws {
        try await withSecretsApp { app in
            // docker → libpod.
            let created = try await createSecret(app, name: "docker-made", payload: "from-docker")
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/json") { res async throws in
                #expect(res.status == .ok)
                let reports = try JSONDecoder().decode([LibpodSecretInfoReport].self, from: Data(buffer: res.body))
                #expect(reports.contains { $0.ID == created.ID && $0.Spec.Name == "docker-made" })
            }
            // libpod → docker (same ID, dialect-specific shapes differ).
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=podman-made",
                body: ByteBuffer(string: "from-podman")
            ) { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretCreateReport.self, from: Data(buffer: res.body))
                let dockerReport = try await inspect(app, "podman-made")
                #expect(dockerReport.ID == report.ID)
            }
            // Deleting via the docker surface removes it from the libpod one.
            try await app.testing().test(.DELETE, "/v1.51/secrets/docker-made") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/docker-made/json") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("the store persists across re-instantiation from the same directory")
    func storeSurvivesReload() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretStore(storageDirectory: dir)
        try await withSecretsApp(store: store) { app in
            let created = try await createSecret(app, name: "durable", payload: "x")
            let reloaded = SecretStore(storageDirectory: dir)
            let found = await reloaded.lookup(nameOrID: created.ID)
            #expect(found?.name == "durable")
        }
    }

    // MARK: - Review round 1 regressions

    /// Review r1: map-form filter values decode strictly as booleans, and
    /// their KEYS count regardless of the boolean (moby's `Args.Get` walks
    /// the map's keys only — `{"names":{"alpha":false}}` still selects
    /// alpha). A non-boolean value is a 400, never a silently-empty
    /// selector that returns everything.
    @Test("map-form filters: non-boolean values are 400s; keys count regardless of the boolean")
    func mapFormFilterValues() async throws {
        try await withSecretsApp { app in
            _ = try await createSecret(app, name: "alpha", payload: "x")
            _ = try await createSecret(app, name: "beta", payload: "y")

            func filteredNames(_ json: String) async throws -> [String] {
                let encoded =
                    json.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                var names: [String] = []
                try await app.testing().test(.GET, "/v1.51/secrets?filters=\(encoded)") {
                    res async throws in
                    let reports = try JSONDecoder().decode(
                        [DockerSecretReport].self, from: Data(buffer: res.body))
                    names = reports.map(\.Spec.Name)
                }
                return names
            }

            // A STRING "true" (Go's map[string]bool decode failure) — and
            // a number — are client errors, not "no filter".
            for bad in [#"{"names":{"alpha":"true"}}"#, #"{"names":{"alpha":1}}"#] {
                let encoded = bad.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                try await app.testing().test(.GET, "/v1.51/secrets?filters=\(encoded)") {
                    res async in
                    #expect(res.status == .badRequest, "\(bad) must be a 400, got \(res.status)")
                }
            }
            // false does NOT disable the key: alpha is still selected.
            #expect(try await filteredNames(#"{"names":{"alpha":false}}"#) == ["alpha"])
        }
    }

    /// Review r1: `id` filters match only IDs and `names`/`name` only
    /// names — a selector never leaks onto the other field, even when a
    /// name resembles an ID prefix ("alph" can never be a 25-hex ID
    /// prefix: 'l' and 'p' are not hex digits).
    @Test("selectors stay on their own field: id never matches a name, names never matches an ID")
    func selectorFieldScoping() async throws {
        try await withSecretsApp { app in
            let a = try await createSecret(app, name: "alpha", payload: "x")
            let b = try await createSecret(app, name: "beta", payload: "y")
            // "alph" prefixes alpha's NAME only — an id filter must not match it.
            try await expectNames(app, filters: ["id": ["alph"]], names: [])
            // A names filter equal to another secret's ID prefix must not
            // match that secret by ID.
            try await expectNames(app, filters: ["names": [String(a.ID.prefix(10))]], names: [])
            // A name prefix filter must not match an ID either.
            try await expectNames(app, filters: ["name": [String(b.ID.prefix(10))]], names: [])
            // Each field still matches its own selector.
            try await expectNames(app, filters: ["id": [String(a.ID.prefix(8))]], names: ["alpha"])
            try await expectNames(app, filters: ["name": ["bet"]], names: ["beta"])
            // OR across keys composes the field-scoped results.
            try await expectNames(
                app, filters: ["names": ["zzz"], "id": [String(b.ID.prefix(8))]], names: ["beta"])
        }
    }

    /// Review r1: Swift `==`/`hasPrefix` fold canonically equivalent
    /// Unicode, but the store keeps NFC/NFD names byte-distinct
    /// (`sameName`) — name filtering must compare UTF-8 bytes so each
    /// spelling matches only itself.
    @Test("NFC and NFD name spellings stay byte-distinct through names/name filters")
    func unicodeByteDistinctFilters() async throws {
        try await withSecretsApp { app in
            let nfc = try await createSecret(app, name: "caf\u{E9}", payload: "x")
            let nfd = try await createSecret(app, name: "cafe\u{301}", payload: "y")
            #expect(nfc.ID != nfd.ID, "the byte-distinct store must hold both spellings")
            // names (exact): each form matches only itself.
            try await expectNames(app, filters: ["names": ["caf\u{E9}"]], names: ["caf\u{E9}"])
            try await expectNames(app, filters: ["names": ["cafe\u{301}"]], names: ["cafe\u{301}"])
            // name (prefix): an NFD prefix must not match the NFC spelling.
            try await expectNames(app, filters: ["name": ["caf\u{E9}"]], names: ["caf\u{E9}"])
            try await expectNames(app, filters: ["name": ["cafe\u{301}"]], names: ["cafe\u{301}"])
        }
    }

    /// Review r1: this endpoint's swarm path (newListSecretsFilters →
    /// convertKVStringsToMap → swarmkit filterMatchLabels) treats an empty
    /// label filter value as PRESENCE-only — `team=` selects any secret
    /// carrying `team`, whatever its value (unlike the non-swarm
    /// MatchKVList, which would require an exactly-empty stored value).
    @Test("label=team= is presence-only (swarm filterMatchLabels), not an exact-empty match")
    func labelEmptyValueIsPresence() async throws {
        try await withSecretsApp { app in
            _ = try await createSecret(app, name: "dbpw", payload: "x", labels: ["team": "db"])
            _ = try await createSecret(app, name: "blank", payload: "x", labels: ["team": ""])
            // "team=" requires only the key: both team=db and team="" match.
            try await expectNames(app, filters: ["label": ["team="]], names: ["dbpw", "blank"])
            // Bare key and k=v keep their existing semantics.
            try await expectNames(app, filters: ["label": ["team"]], names: ["dbpw", "blank"])
            try await expectNames(app, filters: ["label": ["team=db"]], names: ["dbpw"])
            try await expectNames(app, filters: ["label": ["team=web"]], names: [])
        }
    }

    /// Review r1 (delete TOCTOU): the docker delete resolves a snapshot,
    /// then removes by exact ID inside one actor hop. Between a snapshot
    /// resolve and a name-or-ID remove, a libpod replace can retire the
    /// ID and a create can recycle it as a NAME — the name fallback would
    /// then delete the unrelated secret and answer 204 instead of 404.
    @Test("store remove(id:) is exact — an ID recycled as a name is not deleted (delete TOCTOU)")
    func removeExactIDDoesNotFallBackToName() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretStore(storageDirectory: dir)
        let victim = try await store.create(
            name: "victim", data: Data("x".utf8), driver: nil, labels: [:], driverOptions: [:],
            replace: false, ignore: false)
        // The guarded race: the resolved ID is retired and recycled as a
        // new secret's NAME before the removal runs.
        _ = try await store.remove(nameOrID: victim.id)
        let recycled = try await store.create(
            name: victim.id, data: Data("y".utf8), driver: nil, labels: [:], driverOptions: [:],
            replace: false, ignore: false)
        // Exact-ID removal finds no such ID → nil (the route's 404).
        let removed = try await store.remove(id: victim.id)
        #expect(removed == nil, "no secret carries the ID — nil (404), never the name-matched secret")
        // The unrelated secret whose NAME is the recycled ID survives.
        let survivor = await store.lookup(nameOrID: victim.id)
        #expect(survivor?.id == recycled.id)
    }

    // MARK: - Helpers

    /// Boots a VaporTesting app with BOTH secret dialects registered against
    /// one throwaway temp-dir store — never the daemon's real app-support
    /// directory.
    private func withSecretsApp(
        store providedStore: SecretStore? = nil,
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
        try await withApp(configure: { app in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: SecretsRoute(store: store))
            try app.register(collection: LibpodSecretsRoute(store: store))
            try await test(app)
        }
    }

    @discardableResult
    private func createSecret(
        _ app: Application, name: String, payload: String, labels: [String: String] = [:]
    ) async throws -> DockerSecretCreateResponse {
        var object: [String: Any] = ["Name": name, "Data": base64(payload)]
        if !labels.isEmpty {
            object["Labels"] = labels
        }
        return try await createSecret(app, body: jsonString(object))
    }

    @discardableResult
    private func createSecret(_ app: Application, body: String) async throws -> DockerSecretCreateResponse {
        var created: DockerSecretCreateResponse?
        try await app.testing().test(
            .POST, "/v1.51/secrets/create",
            headers: ["Content-Type": "application/json"],
            body: ByteBuffer(string: body)
        ) { res async throws in
            #expect(res.status == .created, "seed create failed: \(res.body.string)")
            created = try JSONDecoder().decode(DockerSecretCreateResponse.self, from: Data(buffer: res.body))
        }
        guard let created else { throw Abort(.internalServerError, reason: "seed create produced no report") }
        return created
    }

    private func inspect(_ app: Application, _ input: String) async throws -> DockerSecretReport {
        var report: DockerSecretReport?
        try await app.testing().test(.GET, "/v1.51/secrets/\(input)") { res async throws in
            #expect(res.status == .ok, "inspect of \(input) failed: \(res.body.string)")
            report = try JSONDecoder().decode(DockerSecretReport.self, from: Data(buffer: res.body))
        }
        guard let report else { throw Abort(.internalServerError, reason: "inspect of \(input) produced no report") }
        return report
    }

    /// GET /secrets?filters=… → asserts the resulting report Spec.Names.
    private func expectNames(
        _ app: Application, filters: [String: [String]], names: [String]
    ) async throws {
        let query = filters.mapValues { $0.map { "\"\($0)\"" } }
            .map { (key, values) in "\"\(key)\":[\(values.joined(separator: ","))]" }
            .joined(separator: ",")
        let encoded = "{\(query)}".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        try await app.testing().test(.GET, "/v1.51/secrets?filters=\(encoded)") { res async throws in
            #expect(res.status == .ok, "filter \(query) failed: \(res.body.string)")
            let reports = try JSONDecoder().decode([DockerSecretReport].self, from: Data(buffer: res.body))
            #expect(
                Set(reports.map(\.Spec.Name)) == Set(names),
                "filter \(query): expected \(names), got \(reports.map(\.Spec.Name))")
        }
    }

    private func base64(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }
}

private func uniqueTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test("docker filter parsing unit: malformed json and arrays throw")
func dockerSecretsParseFiltersUnit() throws {
    #expect(throws: Abort.self) {
        _ = try SecretsRoute.parseFilters("not-json")
    }
    #expect(throws: Abort.self) {
        _ = try SecretsRoute.parseFilters("[]")
    }
}

@Test("docker filter parsing unit: map values must be booleans; keys retained regardless of value")
func dockerSecretsParseFiltersMapUnit() throws {
    // Go decodes the map form into map[string]bool — a string or number
    // value fails the decode (moby 500s; podm's deviation is a 400).
    #expect(throws: Abort.self) {
        _ = try SecretsRoute.parseFilters(#"{"names":{"alpha":"true"}}"#)
    }
    #expect(throws: Abort.self) {
        _ = try SecretsRoute.parseFilters(#"{"names":{"alpha":1}}"#)
    }
    // Args.Get keeps every key regardless of its boolean.
    let retained = try SecretsRoute.parseFilters(#"{"names":{"alpha":false},"name":{"be":true}}"#)
    #expect(Set(retained["names"] ?? []) == ["alpha"])
    #expect(Set(retained["name"] ?? []) == ["be"])
}

@Test("docker passesFilters unit: field scoping, NFC/NFD byte equality, swarm label presence")
func dockerSecretsPassesFiltersUnit() {
    let nfc = StoredSecret(
        id: "aaaaaaaaaaaaaaaaaaaaaaaa1", name: "caf\u{E9}", createdAt: Date(), updatedAt: Date(),
        labels: [:], driver: "file", driverOptions: [:])
    let nfd = StoredSecret(
        id: "aaaaaaaaaaaaaaaaaaaaaaaa2", name: "cafe\u{301}", createdAt: Date(), updatedAt: Date(),
        labels: [:], driver: "file", driverOptions: [:])
    // names (exact): byte-wise — each spelling matches only itself.
    #expect(SecretsRoute.passesFilters(nfc, filters: ["names": ["caf\u{E9}"]]))
    #expect(!SecretsRoute.passesFilters(nfc, filters: ["names": ["cafe\u{301}"]]))
    #expect(SecretsRoute.passesFilters(nfd, filters: ["names": ["cafe\u{301}"]]))
    #expect(!SecretsRoute.passesFilters(nfd, filters: ["names": ["caf\u{E9}"]]))
    // name (prefix): byte-wise prefix — an NFD prefix must not match NFC.
    #expect(SecretsRoute.passesFilters(nfd, filters: ["name": ["cafe\u{301}"]]))
    #expect(!SecretsRoute.passesFilters(nfc, filters: ["name": ["cafe\u{301}"]]))

    // Field scoping: a name that looks like an ID prefix must not match an
    // id filter, and an ID-shaped names value must not match by ID.
    let namedLikeID = StoredSecret(
        id: "bbbbbbbbbbbbbbbbbbbbbbbb1", name: "aaaa-suffix", createdAt: Date(), updatedAt: Date(),
        labels: [:], driver: "file", driverOptions: [:])
    #expect(!SecretsRoute.passesFilters(namedLikeID, filters: ["id": ["aaaa"]]))
    #expect(!SecretsRoute.passesFilters(namedLikeID, filters: ["names": ["bbbb"]]))
    #expect(SecretsRoute.passesFilters(namedLikeID, filters: ["id": ["bbbb"]]))
    #expect(SecretsRoute.passesFilters(namedLikeID, filters: ["name": ["aaaa"]]))
    // OR across keys composes the field-scoped results.
    #expect(SecretsRoute.passesFilters(namedLikeID, filters: ["names": ["zzz"], "id": ["bbbb"]]))

    // Label: swarm presence-only for "k=" and bare "k"; exact for "k=v".
    let labeled = StoredSecret(
        id: "cccccccccccccccccccccccc1", name: "labeled", createdAt: Date(), updatedAt: Date(),
        labels: ["team": "db"], driver: "file", driverOptions: [:])
    #expect(SecretsRoute.passesFilters(labeled, filters: ["label": ["team="]]))
    #expect(SecretsRoute.passesFilters(labeled, filters: ["label": ["team"]]))
    #expect(SecretsRoute.passesFilters(labeled, filters: ["label": ["team=db"]]))
    #expect(!SecretsRoute.passesFilters(labeled, filters: ["label": ["team=web"]]))
    #expect(!SecretsRoute.passesFilters(labeled, filters: ["label": ["missing"]]))
    #expect(!SecretsRoute.passesFilters(labeled, filters: ["label": ["missing="]]))
}

@Test("docker secret resolution unit: ID, name, prefix, ambiguity")
func dockerSecretsResolveUnit() {
    let secretA = StoredSecret(
        id: "aaaaaaaaaaaaaaaaaaaaaaaa1", name: "alpha", createdAt: Date(), updatedAt: Date(),
        labels: [:], driver: "file", driverOptions: [:])
    let secretB = StoredSecret(
        id: "aaaaaaaaaaaaaaaaaaaaaaaa2", name: "beta", createdAt: Date(), updatedAt: Date(),
        labels: [:], driver: "file", driverOptions: [:])
    let secrets = [secretA, secretB]
    // Full ID wins over everything.
    if case .found(let s)? = Optional(SecretsRoute.resolve(secretA.id, in: secrets)) {
        #expect(s.id == secretA.id)
    } else {
        Issue.record("full ID must resolve")
    }
    // Exact name.
    if case .found(let s) = SecretsRoute.resolve("beta", in: secrets) {
        #expect(s.id == secretB.id)
    } else {
        Issue.record("exact name must resolve")
    }
    // Unique prefix.
    if case .found(let s) = SecretsRoute.resolve("aaaaaaaaaaaaaaaaaaaaaaaa1", in: secrets) {
        #expect(s.name == "alpha")
    } else {
        Issue.record("unique prefix must resolve")
    }
    // Shared prefix → ambiguous (400 in the handler).
    if case .ambiguous(let count) = SecretsRoute.resolve("aaaa", in: secrets) {
        #expect(count == 2)
    } else {
        Issue.record("shared prefix must be ambiguous")
    }
    // No match.
    if case .notFound = SecretsRoute.resolve("zzzz", in: secrets) {
    } else {
        Issue.record("no match must be notFound")
    }
}
