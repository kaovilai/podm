// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// Route-level coverage for the docker-dialect `/configs` family (moby
/// v28.5.2 `api/server/router/swarm/cluster.go`), served over a local
/// `ConfigStore`. Pins the moby contract:
///
/// - `POST /configs/create` — `swarm.ConfigSpec` JSON body (`Data`
///   base64), 201 `{"ID"}`; 409 on name-in-use; swarmkit name rules (≤64
///   `[a-zA-Z0-9-_.]`, alphanumeric anchors) and data-size rule
///   (1..<1024000 — `MaxConfigSize`, twice the secret limit); templating
///   guard.
/// - `GET /configs` — moby's `swarm.Config` reports (Version.Index 1) WITH
///   their `Data` (configs are the non-sensitive twin — swarmkit strips
///   only secret data); `name` (prefix) / `id` (prefix) OR'd, `label`
///   AND'd; NO `names` key (secret-family only — moby rejects it here);
///   unknown keys and malformed filters are 400s.
/// - `GET /configs/{id}` — moby getConfig resolution: full ID, exact name,
///   ID prefix; 0 matches → 404 `config <input> not found`; ambiguous
///   prefix → 400.
/// - `DELETE /configs/{id}` — 204 / 404 with moby's message shape.
/// - `POST /configs/{id}/update` — 501 "update is not supported".
/// - Cross-feature: the config store is disjoint from the secret store —
///   same name can exist in both namespaces, neither list sees the other.
@Suite("ConfigsRoute")
struct ConfigsRouteTests {

    // MARK: - Create

    @Test("create answers 201 with an ID and round-trips through inspect, Data included")
    func createRoundTrip() async throws {
        try await withConfigsApp { app in
            let created = try await createConfig(app, name: "myconfig", payload: "not-secret")
            #expect(
                created.ID.range(of: "^[0-9a-f]{25}$", options: .regularExpression) != nil,
                "the store's 25-hex ID is served as-is (docker IDs are opaque; swarmkit's NewID is a 25-char base36 token of the same shape class)")
            let report = try await inspect(app, created.ID)
            #expect(report.ID == created.ID)
            #expect(report.Spec.Name == "myconfig")
            #expect(report.Spec.Labels.isEmpty)
            #expect(report.Spec.Data == Data("not-secret".utf8), "config Data IS returned — moby strips only secret data")
            #expect(report.Version.Index == 1, "a never-updated config carries version index 1")
        }
    }

    @Test("create with labels round-trips them into the report Spec")
    func createWithLabels() async throws {
        try await withConfigsApp { app in
            let body = #"{"Name":"labeled","Labels":{"team":"core","app":"web"},"Data":"\#(base64("x"))"}"#
            let created = try await createConfig(app, body: body)
            let report = try await inspect(app, created.ID)
            #expect(report.Spec.Labels == ["team": "core", "app": "web"])
        }
    }

    @Test("create decodes base64 Data; invalid base64 is a 400 (Go's json []byte strictness)")
    func base64DataHandling() async throws {
        try await withConfigsApp { app in
            // Binary (non-UTF8) bytes must survive the base64 round trip
            // byte-for-byte — configs are served WITH their data, so the
            // round trip is asserted directly on inspect.
            let binary = Data([0x00, 0xFF, 0x10, 0x42])
            let created = try await createConfig(app, body: #"{"Name":"binary","Data":"\#(binary.base64EncodedString())"}"#)
            let report = try await inspect(app, created.ID)
            #expect(report.Spec.Data == binary)
            // Invalid base64 in Data: a client error, not a 500.
            try await app.testing().test(
                .POST, "/v1.51/configs/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"bad64","Data":"!!not-base64!!"}"#)
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("duplicate name is 409; empty and oversize data are 400 with swarmkit's size rule")
    func createValidation() async throws {
        try await withConfigsApp { app in
            _ = try await createConfig(app, name: "dup", payload: "one")
            try await app.testing().test(
                .POST, "/v1.51/configs/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"dup","Data":"\#(base64("two"))"}"#)
            ) { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("config dup already exists"))
            }
            try await app.testing().test(
                .POST, "/v1.51/configs/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"empty","Data":""}"#)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("larger than 0"))
            }
            let oversize = Data(repeating: 0x61, count: ConfigStore.maxConfigSize).base64EncodedString()
            try await app.testing().test(
                .POST, "/v1.51/configs/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"big","Data":"\#(oversize)"}"#)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("1024000"), "swarmkit MaxConfigSize is 1000*1024 — NOT the secret store's 512000")
            }
        }
    }

    @Test("name rules are swarmkit's config charset, with moby's two messages")
    func createNameValidation() async throws {
        try await withConfigsApp { app in
            // Missing name: "name must be provided".
            try await app.testing().test(
                .POST, "/v1.51/configs/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Data":"\#(base64("x"))"}"#)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("name must be provided"))
            }
            // Bad charset: swarmkit's message.
            try await app.testing().test(
                .POST, "/v1.51/configs/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"has=equals","Data":"\#(base64("x"))"}"#)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("only 64 [a-zA-Z0-9-_.] characters allowed"))
            }
            // A name that is VALID for podman secrets (253 chars, '='
            // allowed) is INVALID for swarmkit configs — different rules.
            let longName = String(repeating: "a", count: 65)
            try await app.testing().test(
                .POST, "/v1.51/configs/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"\#(longName)","Data":"\#(base64("x"))"}"#)
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("templating is a loud 400, not a silent drop")
    func createTemplatingGuard() async throws {
        try await withConfigsApp { app in
            try await app.testing().test(
                .POST, "/v1.51/configs/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"tmpl","Data":"\#(base64("x"))","Templating":{"Name":"golang"}}"#)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("templating"))
            }
        }
    }

    @Test("a malformed spec body is a 400, not a 500")
    func malformedSpecRejected() async throws {
        try await withConfigsApp { app in
            try await app.testing().test(
                .POST, "/v1.51/configs/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: "not-json")
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - List

    @Test("list returns moby-shaped reports with Data present")
    func listReports() async throws {
        try await withConfigsApp { app in
            _ = try await createConfig(app, name: "alpha", payload: "alpha-data")
            try await app.testing().test(.GET, "/v1.51/configs") { res async throws in
                #expect(res.status == .ok)
                let reports = try JSONDecoder().decode([DockerConfigReport].self, from: Data(buffer: res.body))
                #expect(reports.count == 1)
                #expect(reports[0].Spec.Name == "alpha")
                #expect(reports[0].Spec.Data == Data("alpha-data".utf8), "config Data IS returned on list — moby never strips it")
                #expect(reports[0].Version.Index == 1)
                // RFC3339 timestamps like Go's time.Time marshaling.
                #expect(reports[0].CreatedAt.contains("T"), "CreatedAt must be RFC3339: \(reports[0].CreatedAt)")
            }
        }
    }

    @Test("list filters: name/id prefix OR'd; label AND'd; NO names key (secret-family only)")
    func listFilters() async throws {
        try await withConfigsApp { app in
            let a = try await createConfig(app, name: "app-config", payload: "x")
            let b = try await createConfig(app, name: "db-password", payload: "y", labels: ["team": "db"])
            _ = try await createConfig(app, name: "other", payload: "z", labels: ["team": "web"])
            // name: PREFIX (there is no exact-match key for configs).
            try await expectNames(app, filters: ["name": ["db-"]], names: ["db-password"])
            try await expectNames(app, filters: ["name": ["app"]], names: ["app-config"])
            // id: PREFIX.
            try await expectNames(app, filters: ["id": [String(b.ID.prefix(8))]], names: ["db-password"])
            // OR across the two keys (one store.Or in swarmkit).
            try await expectNames(
                app,
                filters: ["name": ["other"], "id": [String(a.ID.prefix(12))]],
                names: ["app-config", "other"])
            // label k=v AND presence forms.
            try await expectNames(app, filters: ["label": ["team=db"]], names: ["db-password"])
            try await expectNames(app, filters: ["label": ["team"]], names: ["db-password", "other"])
            // labels AND with an id selector.
            try await expectNames(
                app,
                filters: ["id": [String(a.ID.prefix(12))], "label": ["team=db"]],
                names: [])
            // The docker map form ({"name": {"db-": true}}) is accepted.
            let mapForm = "/v1.51/configs?filters=%7B%22name%22%3A%7B%22db-%22%3Atrue%7D%7D"
            try await app.testing().test(.GET, mapForm) { res async throws in
                #expect(res.status == .ok)
                let reports = try JSONDecoder().decode([DockerConfigReport].self, from: Data(buffer: res.body))
                #expect(reports.map(\.Spec.Name) == ["db-password"])
            }
        }
    }

    @Test("malformed filters are 400s; the secret-only names key is rejected")
    func malformedFiltersRejected() async throws {
        try await withConfigsApp { app in
            _ = try await createConfig(app, name: "somename", payload: "x")
            try await app.testing().test(.GET, "/v1.51/configs?filters=notjson") { res async in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.GET, "/v1.51/configs?filters=%5B%5D") { res async in
                #expect(res.status == .badRequest)
            }
            // moby's accepted CONFIG keys are name/id/label — the secret
            // family's `names` (exact) key does not exist for configs, and
            // moby's filter.Validate rejects it.
            try await app.testing().test(.GET, "/v1.51/configs?filters=%7B%22names%22%3A%5B%22somename%22%5D%7D") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("unrecognized filter key"))
            }
            try await app.testing().test(.GET, "/v1.51/configs?filters=%7B%22driver%22%3A%5B%22file%22%5D%7D") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("unrecognized filter key"))
            }
            try await app.testing().test(.GET, "/v1.51/configs?filters=%7B%22name%22%3A%22somename%22%7D") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Inspect

    @Test("inspect resolves full ID, exact name, and a unique ID prefix; 404 with moby's message")
    func inspectResolution() async throws {
        try await withConfigsApp { app in
            let created = try await createConfig(app, name: "resolve-me", payload: "data")
            // Full ID.
            let byID = try await inspect(app, created.ID)
            #expect(byID.Spec.Name == "resolve-me")
            #expect(byID.Spec.Data == Data("data".utf8))
            // Exact name.
            let byName = try await inspect(app, "resolve-me")
            #expect(byName.ID == created.ID)
            // Unique ID prefix.
            let byPrefix = try await inspect(app, String(created.ID.prefix(10)))
            #expect(byPrefix.ID == created.ID)
            // Not found: moby's getConfig message shape.
            try await app.testing().test(.GET, "/v1.51/configs/nope") { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("config nope not found"))
            }
        }
    }

    @Test("an ambiguous ID prefix is a 400 (moby's InvalidParameter), never a silent pick")
    func ambiguousPrefixRejected() async throws {
        try await withConfigsApp { app in
            // Create several configs, then find a prefix shared by ≥2 of
            // their 25-hex IDs (hex alphabet is small enough that a short
            // prefix over a handful of IDs usually collides; walk down
            // until one does).
            var ids: [String] = []
            for i in 0..<12 {
                ids.append(try await createConfig(app, name: "amb-\(i)", payload: "x").ID)
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
                Issue.record("no ambiguous prefix found over 12 IDs — statistically very unlikely")
                return
            }
            try await app.testing().test(.GET, "/v1.51/configs/\(ambiguous)") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("ambiguous"))
            }
        }
    }

    // MARK: - Delete

    @Test("delete answers 204 and the config is gone; 404 with moby's message")
    func deleteRoundTrip() async throws {
        try await withConfigsApp { app in
            let created = try await createConfig(app, name: "doomed", payload: "x")
            try await app.testing().test(.DELETE, "/v1.51/configs/doomed") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/configs/\(created.ID)") { res async in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.DELETE, "/v1.51/configs/doomed") { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("config doomed not found"))
            }
        }
    }

    @Test("update answers 501 with the same message shape as the secrets family")
    func updateNotSupported() async throws {
        try await withConfigsApp { app in
            let created = try await createConfig(app, name: "frozen", payload: "x")
            try await app.testing().test(.POST, "/v1.51/configs/\(created.ID)/update?version=1") { res async in
                #expect(res.status == .notImplemented)
                #expect(res.body.string.contains("update is not supported"))
            }
        }
    }

    // MARK: - Cross-feature boundaries (config store vs secret store)

    @Test("configs and secrets are disjoint stores: same name coexists, neither list sees the other")
    func configSecretStoreBoundary() async throws {
        try await withConfigsApp { app in
            // The SAME name in both namespaces.
            _ = try await createConfig(app, name: "shared", payload: "config-data")
            try await app.testing().test(
                .POST, "/v1.51/libpod/secrets/create?name=shared",
                body: ByteBuffer(string: "secret-data")
            ) { res async in
                #expect(res.status == .ok, "a secret may share a config's name — separate stores")
            }
            // The config list sees only the config.
            try await app.testing().test(.GET, "/v1.51/configs") { res async throws in
                let reports = try JSONDecoder().decode([DockerConfigReport].self, from: Data(buffer: res.body))
                #expect(reports.map(\.Spec.Name) == ["shared"])
                #expect(reports[0].Spec.Data == Data("config-data".utf8))
            }
            // The libpod secret list sees only the secret.
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/json") { res async throws in
                let reports = try JSONDecoder().decode([LibpodSecretInfoReport].self, from: Data(buffer: res.body))
                #expect(reports.map(\.Spec.Name) == ["shared"])
            }
            // Deleting the config leaves the secret untouched.
            try await app.testing().test(.DELETE, "/v1.51/configs/shared") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/shared/json") { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("the store persists across re-instantiation from the same directory")
    func storeSurvivesReload() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(storageDirectory: dir)
        try await withConfigsApp(store: store) { app in
            let created = try await createConfig(app, name: "durable", payload: "x")
            let reloaded = ConfigStore(storageDirectory: dir)
            let found = await reloaded.lookup(nameOrID: created.ID)
            #expect(found?.name == "durable")
        }
    }

    // MARK: - Helpers

    /// Boots a VaporTesting app with the configs family (and the libpod
    /// secrets family, for the boundary tests) registered against one
    /// throwaway temp-dir store — never the daemon's real app-support
    /// directory. The secret store gets its own throwaway directory: the
    /// two stores must be disjoint even in tests.
    private func withConfigsApp(
        store providedStore: ConfigStore? = nil,
        _ test: @escaping (Application) async throws -> Void
    ) async throws {
        let configDir = uniqueTempDir()
        let secretDir = uniqueTempDir()
        defer {
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: secretDir)
        }
        let store = providedStore ?? ConfigStore(storageDirectory: configDir)
        try await withApp(configure: { app in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ConfigsRoute(store: store))
            try app.register(collection: LibpodSecretsRoute(store: SecretStore(storageDirectory: secretDir)))
            try await test(app)
        }
    }

    @discardableResult
    private func createConfig(
        _ app: Application, name: String, payload: String, labels: [String: String] = [:]
    ) async throws -> DockerConfigCreateResponse {
        var object: [String: Any] = ["Name": name, "Data": base64(payload)]
        if !labels.isEmpty {
            object["Labels"] = labels
        }
        return try await createConfig(app, body: jsonString(object))
    }

    @discardableResult
    private func createConfig(_ app: Application, body: String) async throws -> DockerConfigCreateResponse {
        var created: DockerConfigCreateResponse?
        try await app.testing().test(
            .POST, "/v1.51/configs/create",
            headers: ["Content-Type": "application/json"],
            body: ByteBuffer(string: body)
        ) { res async throws in
            #expect(res.status == .created, "seed create failed: \(res.body.string)")
            created = try JSONDecoder().decode(DockerConfigCreateResponse.self, from: Data(buffer: res.body))
        }
        guard let created else { throw Abort(.internalServerError, reason: "seed create produced no report") }
        return created
    }

    private func inspect(_ app: Application, _ input: String) async throws -> DockerConfigReport {
        var report: DockerConfigReport?
        try await app.testing().test(.GET, "/v1.51/configs/\(input)") { res async throws in
            #expect(res.status == .ok, "inspect of \(input) failed: \(res.body.string)")
            report = try JSONDecoder().decode(DockerConfigReport.self, from: Data(buffer: res.body))
        }
        guard let report else { throw Abort(.internalServerError, reason: "inspect of \(input) produced no report") }
        return report
    }

    /// GET /configs?filters=… → asserts the resulting report Spec.Names.
    private func expectNames(
        _ app: Application, filters: [String: [String]], names: [String]
    ) async throws {
        let query = filters.mapValues { $0.map { "\"\($0)\"" } }
            .map { (key, values) in "\"\(key)\":[\(values.joined(separator: ","))]" }
            .joined(separator: ",")
        let encoded = "{\(query)}".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        try await app.testing().test(.GET, "/v1.51/configs?filters=\(encoded)") { res async throws in
            #expect(res.status == .ok, "filter \(query) failed: \(res.body.string)")
            let reports = try JSONDecoder().decode([DockerConfigReport].self, from: Data(buffer: res.body))
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

@Test("docker config filter parsing unit: malformed json and arrays throw")
func dockerConfigsParseFiltersUnit() throws {
    #expect(throws: Abort.self) {
        _ = try ConfigsRoute.parseFilters("not-json")
    }
    #expect(throws: Abort.self) {
        _ = try ConfigsRoute.parseFilters("[]")
    }
}

@Test("docker config resolution unit: ID, name, prefix, ambiguity")
func dockerConfigsResolveUnit() {
    let configA = StoredConfig(
        id: "aaaaaaaaaaaaaaaaaaaaaaaa1", name: "alpha", createdAt: Date(), updatedAt: Date(), labels: [:])
    let configB = StoredConfig(
        id: "aaaaaaaaaaaaaaaaaaaaaaaa2", name: "beta", createdAt: Date(), updatedAt: Date(), labels: [:])
    let configs = [configA, configB]
    // Full ID wins over everything.
    if case .found(let c)? = Optional(ConfigsRoute.resolve(configA.id, in: configs)) {
        #expect(c.id == configA.id)
    } else {
        Issue.record("full ID must resolve")
    }
    // Exact name.
    if case .found(let c) = ConfigsRoute.resolve("beta", in: configs) {
        #expect(c.id == configB.id)
    } else {
        Issue.record("exact name must resolve")
    }
    // Unique prefix.
    if case .found(let c) = ConfigsRoute.resolve("aaaaaaaaaaaaaaaaaaaaaaaa1", in: configs) {
        #expect(c.name == "alpha")
    } else {
        Issue.record("unique prefix must resolve")
    }
    // Shared prefix → ambiguous (400 in the handler).
    if case .ambiguous(let count) = ConfigsRoute.resolve("aaaa", in: configs) {
        #expect(count == 2)
    } else {
        Issue.record("shared prefix must be ambiguous")
    }
    // No match.
    if case .notFound = ConfigsRoute.resolve("zzzz", in: configs) {
    } else {
        Issue.record("no match must be notFound")
    }
}
