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
///   `{"ID"}`; 409 on name-in-use; podman's data-size/name validation.
/// - `GET /libpod/secrets/json` — metadata only, never payloads; `name`/`id`
///   regex filters; unknown filter keys rejected.
/// - `GET /libpod/secrets/{name}/json` — plain libpod dialect (no Docker-compat
///   `Version` wrapper); `showsecret=true` is the ONLY payload reveal, base64.
/// - `GET /libpod/secrets/{name}/exists` — 204/404.
/// - `DELETE /libpod/secrets/{name}` — 204/404.
/// - The store survives re-instantiation from the same directory, with 0600
///   payload files (podman filedriver parity).
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
                #expect(report.SecretData == Data("v2".utf8).base64EncodedString())
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
                #expect(report.SecretData == Data("v2".utf8).base64EncodedString())
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

    @Test("showsecret is the only reveal path, base64-encoded")
    func showSecretRevealsBase64() async throws {
        try await withSecretsApp { app in
            _ = try await createSecret(app, name: "reveal", payload: "seekrit")
            try await app.testing().test(.GET, "/v1.51/libpod/secrets/reveal/json?showsecret=true") { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(LibpodSecretInfoReport.self, from: Data(buffer: res.body))
                #expect(report.SecretData == Data("seekrit".utf8).base64EncodedString())
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

    // MARK: - Helpers

    /// Boots a VaporTesting app with ONLY the libpod secrets collection
    /// registered, backed by a throwaway temp-dir store — never the daemon's
    /// real app-support directory.
    private func withSecretsApp(_ test: @escaping (Application) async throws -> Void) async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretStore(storageDirectory: dir)
        try await withApp(configure: { _ in }) { app in
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
}

private func uniqueTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
