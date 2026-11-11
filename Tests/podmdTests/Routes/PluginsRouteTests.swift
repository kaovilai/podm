// SPDX-License-Identifier: Apache-2.0
import ContainerAPIClient
import ContainerizationArchive
import ContainerizationOCI
import Crypto
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// A deterministic privileges provider — the registry fetch is unit-pinned
/// separately (computePrivileges), the route tests only need wiring.
private enum MockPrivileges: PluginPrivilegesProviding {
    case success([DockerPluginPrivilege])
    case failure(Abort)

    func privileges(remote: String, authentication: Authentication?) async throws -> [DockerPluginPrivilege] {
        switch self {
        case .success(let list): return list
        case .failure(let abort): throw abort
        }
    }
}

/// Route-level coverage for the docker-dialect `/plugins` local-metadata
/// family (issue #35; moby v28.5.2 `api/server/router/plugin/`), served over
/// a local `PluginStore`:
///
/// - `GET /plugins` — moby's `[]*Plugin` (empty store answers `[]`); the
///   `enabled`/`capability` filters with moby's semantics; unknown filter
///   keys are 400s.
/// - `GET /plugins/{name}` + `GET /plugins/{name}/json` — inspect with
///   moby's resolution order (full ID, familiar name, ID prefix) and its
///   404/400 message shapes.
/// - `GET /plugins/privileges` — moby's remote-manifest computation (GET,
///   per moby's router, not the issue text's POST); the provider is a mock —
///   the computation itself is unit-pinned below.
/// - `POST /plugins/create` — tar ingest: 204, moby's name rules, moby's
///   tar failures ("config not found" / "no rootfs found"), the 409
///   conflict, the report shape (Enabled false, initEmptySettings, rootfs
///   digest, DockerVersion).
@Suite("PluginsRoute")
struct PluginsRouteTests {

    // MARK: - List

    @Test("an empty store lists [] — the answer that keeps docker plugin ls healthy")
    func emptyList() async throws {
        try await withPluginsApp { app in
            try await app.testing().test(.GET, "/v1.51/plugins") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "[]", "moby marshals an empty (non-nil) slice as []")
            }
        }
    }

    @Test("create answers 204 and the plugin lists and inspects with moby's Plugin shape")
    func createRoundTrip() async throws {
        try await withPluginsApp { app in
            try await createPlugin(app, name: "myteam/myplugin")

            var reports: [DockerPlugin] = []
            try await app.testing().test(.GET, "/v1.51/plugins") { res async throws in
                #expect(res.status == .ok)
                reports = try JSONDecoder().decode([DockerPlugin].self, from: Data(buffer: res.body))
            }
            #expect(reports.count == 1)
            guard let report = reports.first else {
                Issue.record("expected one plugin report")
                return
            }
            #expect(report.Id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, "stringid.GenerateRandomID shape")
            #expect(report.Name == "myteam/myplugin:latest", "TagNameOnly + FamiliarString")
            #expect(report.Enabled == false, "createPlugin never enables")
            #expect(report.PluginReference == "myteam/myplugin:latest", "CreateFromContext sets PluginReference to the name")
            #expect(report.Config.Description == "a test plugin")
            #expect(report.Config.Entrypoint == ["/bin/plugin"])
            // The interface type marshals as the STRING form.
            #expect(report.Config.Interface?.Types == [DockerPluginInterfaceType(Prefix: "docker", Capability: "volumedriver", Version: "1.0")])
            // moby's create-time adjustments.
            #expect(report.Config.rootfs?.type == "layers")
            #expect(report.Config.rootfs?.diff_ids.count == 1)
            #expect(report.Config.rootfs?.diff_ids.first?.hasPrefix("sha256:") == true)
            #expect(report.Config.DockerVersion != nil, "moby sets the daemon version on create")
            // InitEmptySettings: mounts/devices copied, env as name=value, args from Args.Value.
            #expect(report.Settings.Env == ["DEBUG=0"])
            #expect(report.Settings.Args == [])
            #expect(report.Settings.Mounts == [sampleMount()])

            // Inspect by name, both route forms.
            for path in ["/v1.51/plugins/myteam/myplugin", "/v1.51/plugins/myteam/myplugin/json"] {
                try await app.testing().test(.GET, path) { res async throws in
                    #expect(res.status == .ok, "\(path) failed: \(res.body.string)")
                    let inspected = try JSONDecoder().decode(DockerPlugin.self, from: Data(buffer: res.body))
                    #expect(inspected.Id == report.Id)
                }
            }
            // Inspect by full ID and by an unambiguous ID prefix.
            try await app.testing().test(.GET, "/v1.51/plugins/\(report.Id)") { res async in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.GET, "/v1.51/plugins/\(report.Id.prefix(16))/json") { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("inspect of an unknown name is moby's 404 with its %q-quoted message")
    func inspectNotFound() async throws {
        try await withPluginsApp { app in
            try await app.testing().test(.GET, "/v1.51/plugins/nope/json") { res async throws in
                #expect(res.status == .notFound)
                #expect(try errorMessage(res) == #"plugin "nope" not found"#)
            }
            // A garbage ref resolves to nothing (moby wraps the parse error
            // as errNotFound), not a client error.
            try await app.testing().test(.GET, "/v1.51/plugins/NOT A REF!!/json") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("an ambiguous ID prefix is moby's 400, never a silent pick")
    func ambiguousPrefix() async throws {
        try await withPluginsApp { app in
            // Random IDs rarely share a prefix; keep creating until some
            // first character is shared by two plugins, then query it.
            var firstChars: [Character: Int] = [:]
            var shared: Character?
            while shared == nil {
                let created = try await createPlugin(app, name: "p\(firstChars.count)/plugin")
                let char = created.Id.first!
                firstChars[char, default: 0] += 1
                if firstChars[char]! >= 2 {
                    shared = char
                }
            }
            try await app.testing().test(.GET, "/v1.51/plugins/\(shared!)/json") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("multiple plugins found for"))
            }
        }
    }

    @Test("list filters: enabled and capability, moby's semantics; unknown keys are 400s")
    func listFilters() async throws {
        try await withPluginsApp { app in
            try await createPlugin(app, name: "a/plugin")
            try await createPlugin(app, name: "b/plugin")

            // enabled=false → every stored plugin (create never enables).
            try await expectCount(app, filters: #"{"enabled":{"false":true}}"#, count: 2)
            try await expectCount(app, filters: #"{"enabled":["false"]}"#, count: 2)
            // enabled=true → none.
            try await expectCount(app, filters: #"{"enabled":["true"]}"#, count: 0)
            // capability: the plugin's every interface type capability must
            // be in the value set.
            try await expectCount(app, filters: #"{"capability":["volumedriver"]}"#, count: 2)
            try await expectCount(app, filters: #"{"capability":["networkdriver"]}"#, count: 0)

            for bad in [
                #"{"name":["a"]}"#, #"<not json>"#, #"{"enabled":["yes"]}"#,
                #"{"enabled":{"true":"not-a-bool"}}"#,
            ] {
                try await app.testing().test(.GET, "/v1.51/plugins?filters=\(encodeQuery(bad))") { res async in
                    #expect(res.status == .badRequest, "filter \(bad) should be a 400, got \(res.status)")
                }
            }
        }
    }

    @Test("list filters, moby's GetBoolOrDefault: whole value set, literals only, empty is invalid")
    func listFiltersEnabledSemantics() async throws {
        try await withPluginsApp { app in
            try await createPlugin(app, name: "a/plugin")
            try await createPlugin(app, name: "b/plugin")

            // GetBoolOrDefault examines the WHOLE value set — conflicting
            // truth values are invalid, not first-value-wins — and only the
            // literals "1"/"true"/"0"/"false" count (no strconv.ParseBool
            // grammar, no case folding). An empty set is invalid too.
            for bad in [
                #"{"enabled":["true","false"]}"#,
                #"{"enabled":["1","0"]}"#,
                #"{"enabled":["t"]}"#,
                #"{"enabled":["TRUE"]}"#,
                #"{"enabled":[]}"#,
                #"{"enabled":{}}"#,
                #"{"enabled":{"true":false}}"#,
            ] {
                try await app.testing().test(.GET, "/v1.51/plugins?filters=\(encodeQuery(bad))") { res async in
                    #expect(res.status == .badRequest, "filter \(bad) should be a 400, got \(res.status)")
                }
            }
            // The map form's flags are honored: flagging "false" out leaves
            // only "true", so this asks for enabled-only (none exist).
            try await expectCount(app, filters: #"{"enabled":{"true":true,"false":false}}"#, count: 0)
        }
    }

    @Test("list filters, moby's filters.Match: exact-or-regex, empty set is no restriction")
    func listFiltersCapabilitySemantics() async throws {
        try await withPluginsApp { app in
            try await createPlugin(app, name: "a/plugin")
            try await createPlugin(app, name: "b/plugin")

            // Match tries the exact value, then each value as an UNANCHORED
            // regex — "volume.*" and the substring "driver" both include the
            // volumedriver plugin.
            try await expectCount(app, filters: #"{"capability":["volume.*"]}"#, count: 2)
            try await expectCount(app, filters: #"{"capability":["driver"]}"#, count: 2)
            // An EMPTY value set is no restriction (not exclude-all).
            try await expectCount(app, filters: #"{"capability":[]}"#, count: 2)
            try await expectCount(app, filters: #"{"capability":{}}"#, count: 2)
            // A regex that matches nothing excludes; an INVALID regex is
            // skipped, so only the valid pattern counts.
            try await expectCount(app, filters: #"{"capability":["^network"]}"#, count: 0)
            try await expectCount(app, filters: #"{"capability":["[","volumedriver"]}"#, count: 2)
        }
    }

    // MARK: - Create

    @Test("create name rules: moby's familiar-name normalization and its rejections")
    func createNameRules() async throws {
        try await withPluginsApp { app in
            // TagNameOnly: an untagged name gets :latest.
            let created = try await createPlugin(app, name: "plain")
            #expect(created.Name == "plain:latest")

            // A digest ref is rejected, moby's message verbatim.
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=foo@sha256:\(String(repeating: "a", count: 64))",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(data: sampleTar())
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("canonical references are not permitted"))
            }
            // An unparseable name is a 400 (moby 500s; podm's standing
            // deviation), with moby's wrapped message shape.
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=UPPERCASE",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(data: sampleTar())
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("failed to parse reference"))
            }
            // No name at all.
            try await app.testing().test(
                .POST, "/v1.51/plugins/create",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(data: sampleTar())
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("duplicate create is moby's 409 alreadyExistsError")
    func duplicateCreate() async throws {
        try await withPluginsApp { app in
            _ = try await createPlugin(app, name: "dup/plugin")
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=dup/plugin",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(data: sampleTar())
            ) { res async throws in
                #expect(res.status == .conflict)
                #expect(try errorMessage(res) == "plugin dup/plugin:latest already exists")
            }
            // The rejected create did not leave a second entry behind.
            try await expectCount(app, filters: nil, count: 1)
        }
    }

    @Test("tar failures carry moby's messages: config not found, no rootfs found")
    func tarFailures() async throws {
        try await withPluginsApp { app in
            // No config.json.
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=no/config",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(data: sampleTar(includeConfig: false))
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("config not found"))
            }
            // No rootfs tree.
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=no/rootfs",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(data: sampleTar(includeRootfs: false))
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("no rootfs found"))
            }
            // A config.json that is not valid JSON.
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=bad/config",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(data: sampleTar(configJSON: Data("}".utf8)))
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("failed to parse config"))
            }
        }
    }

    // MARK: - Malformed entry names (moby's path.Clean posture)

    /// moby's `splitConfigRootFSFromTar` runs `path.Clean` over each entry
    /// name and then strips a leading "/". Go's Clean PRESERVES unresolved
    /// leading `..` on relative names — such entries match neither
    /// `config.json` nor the `rootfs/` prefix and are skipped, never
    /// promoted. Absolute names clamp their `..` to the root
    /// (`/../config.json` → `config.json`), which moby DOES accept.
    @Test("malformed entry names never yield config or rootfs entries")
    func malformedEntryNames() async throws {
        try await withPluginsApp { app in
            // A relative ../config.json is NOT the config entry.
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=dot/dot/config",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(
                    data: entriesTar([
                        ("../config.json", sampleConfigJSON()),
                        ("rootfs/bin/plugin", Data("#!/bin/sh\necho plugin\n".utf8)),
                    ]))
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("config not found"))
            }
            // A relative ../rootfs/... is NOT the rootfs tree either.
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=dot/dot/rootfs",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(
                    data: entriesTar([
                        ("config.json", sampleConfigJSON()),
                        ("../rootfs/bin/plugin", Data("#!/bin/sh\necho plugin\n".utf8)),
                    ]))
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("no rootfs found"))
            }
            // An ABSOLUTE /../config.json clamps to config.json — moby's
            // path.Clean("/../config.json") + name[1:] — and IS the config.
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=dot/dot/abs",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(
                    data: entriesTar([
                        ("/../config.json", sampleConfigJSON()),
                        ("rootfs/bin/plugin", Data("#!/bin/sh\necho plugin\n".utf8)),
                    ]))
            ) { res async in
                #expect(res.status == .noContent)
            }
        }
    }

    /// The rootfs digest is streamed in 1 MiB chunks — a rootfs larger than
    /// one chunk must still create and report a well-formed digest.
    @Test("create digests a rootfs larger than the hashing chunk")
    func largeRootfsCreate() async throws {
        let big = Data(repeating: 0x5A, count: 3 * 1024 * 1024 + 7)
        try await withPluginsApp { app in
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=big/rootfs",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(
                    data: entriesTar([
                        ("config.json", sampleConfigJSON()),
                        ("rootfs/blob", big),
                    ]))
            ) { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/plugins/big/rootfs/json") { res async throws in
                #expect(res.status == .ok)
                let decoded = try JSONDecoder().decode(DockerPlugin.self, from: Data(buffer: res.body))
                let digest = decoded.Config.rootfs?.diff_ids.first
                #expect(digest?.hasPrefix("sha256:") == true)
                #expect(digest?.count == "sha256:".count + 64)
            }
        }
    }

    /// The context-tar cap: an oversized body answers 413 before anything
    /// is staged (the limit is injected small; the default is 256 MiB).
    @Test("create rejects an oversized context tar with 413")
    func createRejectsOversizedBody() async throws {
        try await withPluginsApp(maximumContextBytes: 1024) { app in
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=too/big",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(data: sampleTar())
            ) { res async in
                #expect(res.status == .payloadTooLarge)
                #expect(res.body.string.contains("request body too large"))
            }
        }
    }

    @Test("create round-trips across daemon restarts (store re-instantiation)")
    func createPersists() async throws {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PluginStore(storageDirectory: dir)
        try await withPluginsApp(store: store) { app in
            let created = try await createPlugin(app, name: "persist/plugin")
            #expect(created.Name == "persist/plugin:latest")
        }
        // A NEW app over the SAME directory — the persisted plugin is still
        // there, so `docker plugin ls` survives a daemon restart.
        let reopened = PluginStore(storageDirectory: dir)
        try await withPluginsApp(store: reopened) { app in
            try await app.testing().test(.GET, "/v1.51/plugins/persist/plugin/json") { res async in
                #expect(res.status == .ok, "the plugin survived the store re-instantiation")
            }
        }
    }

    @Test("config value errors are 400s, never a crash: empty interface type, mistyped network")
    func configTypeErrors() async throws {
        try await withPluginsApp { app in
            // The empty interface type used to TRAP podmd (an out-of-bounds
            // slice); the mistyped Network values used to decode silently
            // as an empty network type.
            for bad in [
                #"{"Interface":{"Types":[""]}}"#,
                #"{"Network":{"Type":123}}"#,
                #"{"Network":"host"}"#,
            ] {
                try await app.testing().test(
                    .POST, "/v1.51/plugins/create?name=bad/values",
                    headers: ["Content-Type": "application/x-tar"],
                    body: ByteBuffer(data: sampleTar(configJSON: Data(bad.utf8)))
                ) { res async in
                    #expect(res.status == .badRequest, "\(bad): expected a 400, got \(res.status)")
                    #expect(res.body.string.contains("failed to parse config"))
                }
            }
            // podmd survived the malformed configs.
            try await expectCount(app, filters: nil, count: 0)
        }
    }

    @Test("a lowercase config.json decodes like Go's case-insensitive json.Unmarshal")
    func lowercaseConfigRoundTrip() async throws {
        try await withPluginsApp { app in
            try await app.testing().test(
                .POST, "/v1.51/plugins/create?name=lower/case",
                headers: ["Content-Type": "application/x-tar"],
                body: ByteBuffer(data: sampleTar(configJSON: lowercaseConfigJSON()))
            ) { res async in
                #expect(res.status == .noContent, "lowercase config create failed: \(res.body.string)")
            }
            try await app.testing().test(.GET, "/v1.51/plugins/lower/case/json") { res async throws in
                #expect(res.status == .ok)
                let report = try JSONDecoder().decode(DockerPlugin.self, from: Data(buffer: res.body))
                // The case-insensitively decoded data re-encodes under the
                // REPORT's capitalized keys — nothing was dropped.
                #expect(report.Config.Description == "a lowercase-keyed plugin")
                #expect(report.Config.Entrypoint == ["/bin/plugin"])
                #expect(
                    report.Config.Interface?.Types
                        == [DockerPluginInterfaceType(Prefix: "docker", Capability: "volumedriver", Version: "1.0")])
                #expect(report.Config.Linux?.Capabilities == ["CAP_SYS_ADMIN"])
                #expect(report.Config.Network?.networkType == "host")
                #expect(report.Config.User?.UID == 1000)
                #expect(report.Settings.Env == ["DEBUG=0"], "emptySettings reads the decoded env")
            }
        }
    }

    // MARK: - Privileges

    @Test("privileges: missing remote is a 400; the provider's list is served as-is")
    func privilegesRoute() async throws {
        let privileges = [
            DockerPluginPrivilege(Name: "network", Description: "permissions to access a network", Value: ["host"])
        ]
        try await withPluginsApp(privileges: MockPrivileges.success(privileges)) { app in
            try await app.testing().test(.GET, "/v1.51/plugins/privileges") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("invalid reference format"))
            }
            try await app.testing().test(.GET, "/v1.51/plugins/privileges?remote=") { res async in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.GET, "/v1.51/plugins/privileges?remote=vieux/sshfs") { res async throws in
                #expect(res.status == .ok)
                let decoded = try JSONDecoder().decode([DockerPluginPrivilege].self, from: Data(buffer: res.body))
                #expect(decoded == privileges)
            }
            // Provider failures propagate with their status.
            try await withPluginsApp(privileges: MockPrivileges.failure(Abort(.notFound, reason: "manifest unknown"))) { app2 in
                try await app2.testing().test(.GET, "/v1.51/plugins/privileges?remote=vieux/sshfs") { res async in
                    #expect(res.status == .notFound)
                }
            }
        }
    }

    // MARK: - Stubs stay stubs

    @Test("the runtime half keeps answering the deliberate stub")
    func runtimeHalfStaysStubbed() async throws {
        try await withPluginsApp { app in
            try await app.testing().test(.POST, "/v1.51/plugins/myplugin/enable?timeout=1") { res async in
                // #41 (stub compat): known-unsupported now answers 501, not 500.
                #expect(res.status == .notImplemented)
                #expect(res.body.string.contains("is not implemented by podm"))
            }
        }
    }

    // MARK: - App and helpers

    /// The error body's message/reason, decoded — the raw JSON escapes `/`
    /// and quotes, so substring assertions on the wire form are brittle.
    private func errorMessage(_ res: TestingHTTPResponse) throws -> String? {
        struct ErrorBody: Decodable {
            let message: String?
            let reason: String?
        }
        let body = try JSONDecoder().decode(ErrorBody.self, from: Data(buffer: res.body))
        return body.message ?? body.reason
    }

    private func withPluginsApp(
        store: PluginStore? = nil,
        privileges: PluginPrivilegesProviding = MockPrivileges.success([]),
        maximumContextBytes: Int = PluginsRoute.defaultMaximumContextBytes,
        _ test: (Application) async throws -> Void
    ) async throws {
        let pluginStore = store ?? PluginStore(storageDirectory: uniqueTempDir())
        try await withApp(configure: { app in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            // The production error rendering (DockerErrorMiddleware) plus
            // the still-stubbed runtime half, so the family behaves like
            // the real daemon.
            app.middleware.use(DockerErrorMiddleware(), at: .beginning)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(
                collection: PluginsRoute(
                    store: pluginStore, privilegesProvider: privileges,
                    maximumContextBytes: maximumContextBytes))
            try app.register(collection: PluginsNameEnableRoute())
            try await test(app)
        }
    }

    @discardableResult
    private func createPlugin(_ app: Application, name: String) async throws -> DockerPlugin {
        var created: DockerPlugin?
        try await app.testing().test(
            .POST, "/v1.51/plugins/create?name=\(name)",
            headers: ["Content-Type": "application/x-tar"],
            body: ByteBuffer(data: sampleTar())
        ) { res async throws in
            #expect(res.status == .noContent, "seed create of \(name) failed: \(res.body.string)")
        }
        try await app.testing().test(.GET, "/v1.51/plugins/\(name)/json") { res async throws in
            #expect(res.status == .ok)
            created = try JSONDecoder().decode(DockerPlugin.self, from: Data(buffer: res.body))
        }
        guard let created else { throw Abort(.internalServerError, reason: "seed create of \(name) produced no report") }
        return created
    }

    private func expectCount(_ app: Application, filters: String?, count: Int) async throws {
        let query = filters.map { "?filters=\(encodeQuery($0))" } ?? ""
        try await app.testing().test(.GET, "/v1.51/plugins\(query)") { res async throws in
            #expect(res.status == .ok, "filter \(filters ?? "<none>") failed: \(res.body.string)")
            let reports = try JSONDecoder().decode([DockerPlugin].self, from: Data(buffer: res.body))
            #expect(reports.count == count, "filter \(filters ?? "<none>"): expected \(count), got \(reports.count)")
        }
    }

    private func encodeQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }

    private func sampleMount() -> DockerPluginMount {
        DockerPluginMount(
            Description: "data mount", Destination: "/data", Name: "data",
            Options: ["rbind"], Settable: [], Source: "/srv/data", mountType: "bind")
    }

    /// The plugin's `config.json` — the same shape moby's own test fixtures
    /// use (description, interface, network, mounts, env, args).
    private func sampleConfigJSON() -> Data {
        let mount: [String: Any] = [
            "Description": "data mount", "Destination": "/data", "Name": "data",
            "Options": ["rbind"], "Settable": [], "Source": "/srv/data", "Type": "bind",
        ]
        let config: [String: Any] = [
            "Description": "a test plugin",
            "Documentation": "https://example.com/docs",
            "Entrypoint": ["/bin/plugin"],
            "Interface": [
                "Types": ["docker.volumedriver/1.0"], "Socket": "plugin.sock",
            ],
            "Network": ["Type": "bridge"],
            "Linux": ["AllowAllDevices": false, "Capabilities": [], "Devices": []],
            "Mounts": [mount],
            "Env": [["Name": "DEBUG", "Description": "debug", "Settable": [], "Value": "0"]],
            "Args": ["Name": "args", "Description": "arguments", "Settable": [], "Value": []],
            "IpcHost": false,
            "PidHost": false,
            "PropagatedMount": "",
            "WorkDir": "/work",
        ]
        return try! JSONSerialization.data(withJSONObject: config)
    }

    /// A plugin context tar, moby's `docker plugin create` layout: a
    /// top-level `config.json` plus a `rootfs/` tree.
    private func sampleTar(
        includeConfig: Bool = true, includeRootfs: Bool = true, configJSON: Data? = nil
    ) -> Data {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tarURL = dir.appendingPathComponent("context.tar")
        let writer = try! ArchiveWriter(format: .pax, filter: .none, file: tarURL)
        if includeConfig {
            let entry = WriteEntry()
            entry.path = "config.json"
            entry.fileType = .regular
            entry.permissions = 0o644
            let contents = configJSON ?? sampleConfigJSON()
            entry.size = Int64(contents.count)
            try! writer.writeEntry(entry: entry, data: contents)
        }
        if includeRootfs {
            let rootDir = WriteEntry()
            rootDir.path = "rootfs"
            rootDir.fileType = .directory
            rootDir.permissions = 0o755
            try! writer.writeEntry(entry: rootDir, data: nil)
            for (path, content) in [("rootfs/bin/plugin", Data("#!/bin/sh\necho plugin\n".utf8)), ("rootfs/etc/motd", Data("hello".utf8))] {
                let entry = WriteEntry()
                entry.path = path
                entry.fileType = .regular
                entry.permissions = 0o755
                entry.size = Int64(content.count)
                try! writer.writeEntry(entry: entry, data: content)
            }
        }
        try! writer.finishEncoding()
        return try! Data(contentsOf: tarURL)
    }

    /// A tar with arbitrary entry names/contents — for the malformed-name
    /// and large-rootfs regressions, where the fixed `sampleTar` shapes do
    /// not fit.
    private func entriesTar(_ entries: [(path: String, content: Data)]) -> Data {
        let dir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tarURL = dir.appendingPathComponent("context.tar")
        let writer = try! ArchiveWriter(format: .pax, filter: .none, file: tarURL)
        for entry in entries {
            let e = WriteEntry()
            e.path = entry.path
            e.fileType = .regular
            e.permissions = 0o644
            e.size = Int64(entry.content.count)
            try! writer.writeEntry(entry: e, data: entry.content)
        }
        try! writer.finishEncoding()
        return try! Data(contentsOf: tarURL)
    }
}

private func uniqueTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The same fixture shape as the suite's `sampleConfigJSON` with EVERY key
/// lowercased — Go's json.Unmarshal accepts this for the capitalized struct
/// fields, so podm's config decoders must too.
private func lowercaseConfigJSON() -> Data {
    let mount: [String: Any] = [
        "description": "data mount", "destination": "/data", "name": "data",
        "options": ["rbind"], "settable": [], "source": "/srv/data", "type": "bind",
    ]
    let config: [String: Any] = [
        "description": "a lowercase-keyed plugin",
        "documentation": "https://example.com/docs",
        "entrypoint": ["/bin/plugin"],
        "interface": [
            "types": ["docker.volumedriver/1.0"], "socket": "plugin.sock",
        ],
        "network": ["type": "host"],
        "linux": ["allowalldevices": false, "capabilities": ["CAP_SYS_ADMIN"], "devices": []],
        "mounts": [mount],
        "env": [["name": "DEBUG", "description": "debug", "settable": [], "value": "0"]],
        "args": ["name": "args", "description": "arguments", "settable": [], "value": []],
        "ipchost": false,
        "pidhost": false,
        "propagatedmount": "",
        "workdir": "/work",
        "user": ["uid": 1000, "gid": 1000],
    ]
    return try! JSONSerialization.data(withJSONObject: config)
}

// MARK: - Unit tests

/// moby's `computePrivileges` (`plugin/backend_linux.go`), order and
/// messages pinned.
@Test("plugin privilege computation: moby's order, values, and skip rules")
func pluginPrivilegesComputationUnit() {
    let config = DockerPluginConfig(
        Description: "d",
        Entrypoint: [],
        Env: [],
        Interface: DockerPluginConfigInterface(Socket: "s", Types: []),
        IpcHost: true,
        Linux: DockerPluginConfigLinux(
            AllowAllDevices: true,
            Capabilities: ["CAP_SYS_ADMIN", "CAP_NET_ADMIN"],
            Devices: [
                DockerPluginDevice(Name: "fuse", Path: "/dev/fuse"),
                DockerPluginDevice(Name: "unset"),
            ]),
        Mounts: [
            DockerPluginMount(Name: "data", Source: "/srv/data", mountType: "bind"),
            DockerPluginMount(Name: "anonymous"),
        ],
        Network: DockerPluginConfigNetwork(networkType: "host"),
        PidHost: true,
        WorkDir: "")
    let privileges = RegistryPluginPrivilegesProvider.computePrivileges(from: config)
    #expect(
        privileges.map(\.Name)
            == [
                "network", "host ipc namespace", "host pid namespace", "mount", "device",
                "allow-all-devices", "capabilities",
            ])
    #expect(privileges[0].Value == ["host"])
    #expect(privileges[1].Value == ["true"] && privileges[1].Description == "allow access to host ipc namespace")
    #expect(privileges[3].Value == ["/srv/data"])
    #expect(privileges[4].Value == ["/dev/fuse"], "a device without a Path is skipped, like moby's nil check")
    #expect(privileges[6].Value == ["CAP_SYS_ADMIN", "CAP_NET_ADMIN"])

    // The skip rules: null/bridge/"" networks, no ipc/pid, no caps.
    let quiet = DockerPluginConfig(
        Description: "d", Entrypoint: [], Env: [], Interface: nil,
        Linux: DockerPluginConfigLinux(Devices: [DockerPluginDevice(Name: "unset")]),
        Mounts: [DockerPluginMount(Name: "anonymous")],
        Network: DockerPluginConfigNetwork(networkType: "bridge"), WorkDir: "")
    #expect(RegistryPluginPrivilegesProvider.computePrivileges(from: quiet).isEmpty)

    for networkType in ["null", "bridge", ""] {
        let config = DockerPluginConfig(Network: DockerPluginConfigNetwork(networkType: networkType))
        #expect(
            RegistryPluginPrivilegesProvider.computePrivileges(from: config).isEmpty,
            "network type \(networkType) must not request privileges")
    }
}

/// moby's plugin-name grammar (`ParseNormalizedNamed` + `TagNameOnly` +
/// `FamiliarString`) and its rejections.
@Test("plugin reference normalization: moby's familiar-name rules")
func pluginReferenceNormalizationUnit() throws {
    #expect(try PluginReferenceUtility.repoName(from: "myplugin") == "myplugin:latest")
    #expect(try PluginReferenceUtility.repoName(from: "vieux/sshfs") == "vieux/sshfs:latest")
    #expect(try PluginReferenceUtility.repoName(from: "vieux/sshfs:1.0") == "vieux/sshfs:1.0")
    #expect(try PluginReferenceUtility.repoName(from: "docker.io/vieux/sshfs") == "vieux/sshfs:latest")
    #expect(try PluginReferenceUtility.repoName(from: "localhost:5000/my/plugin") == "localhost:5000/my/plugin:latest")
    #expect(PluginReferenceUtility.lookupName(from: "UPPERCASE") == nil, "Go's path grammar is lowercase-only")
    #expect(PluginReferenceUtility.lookupName(from: "") == nil)
    #expect(PluginReferenceUtility.isFullID(String(repeating: "a", count: 64)))
    #expect(!PluginReferenceUtility.isFullID(String(repeating: "A", count: 64)))
    #expect(!PluginReferenceUtility.isFullID(String(repeating: "a", count: 63)))
    #expect(throws: PluginReferenceUtility.NameError.canonical) {
        _ = try PluginReferenceUtility.repoName(
            from: "foo@sha256:\(String(repeating: "a", count: 64))")
    }
}

/// The registry-side repository path for a privileges lookup — moby's
/// `ParseNormalizedNamed` dominant-registry rule (`library/` for
/// single-component Docker Hub refs), applied to untagged, tagged, AND
/// digested refs alike. ContainerizationOCI's `normalize()` alone misses
/// the absent-domain case (`myplugin`) and podm used to skip it entirely
/// for tagged/digested refs (`docker.io/myplugin:latest`) — both looked up
/// the bare repository, which Docker Hub answers with 404.
@Test("plugin registry lookup path: library/ familiarization for Hub refs")
func pluginRegistryLookupPathUnit() throws {
    func lookupPath(_ raw: String) throws -> String {
        PluginReferenceUtility.registryLookupPath(of: try Reference.parse(raw))
    }
    #expect(try lookupPath("myplugin") == "library/myplugin")
    #expect(try lookupPath("myplugin:latest") == "library/myplugin")
    #expect(try lookupPath("docker.io/myplugin") == "library/myplugin")
    #expect(try lookupPath("docker.io/myplugin:latest") == "library/myplugin")
    #expect(
        try lookupPath("docker.io/myplugin@sha256:\(String(repeating: "a", count: 64))")
            == "library/myplugin")
    #expect(try lookupPath("registry-1.docker.io/myplugin") == "library/myplugin")
    // Multi-component paths and other registries are untouched.
    #expect(try lookupPath("vieux/sshfs") == "vieux/sshfs")
    #expect(try lookupPath("example.com/myplugin") == "myplugin")
    #expect(try lookupPath("example.com/foo/bar:1.0") == "foo/bar")
}

/// moby's `splitConfigRootFSFromTar` entry-name cleaning: `path.Clean`,
/// then the leading "/" of an absolute result is stripped. Relative names
/// keep their unresolved leading `..`; absolute ones clamp theirs.
@Test("plugin tar entry-name cleaning: moby's path.Clean + absolute strip")
func pluginTarPathCleaningUnit() {
    // Relative parents are preserved — the entry is then skipped, never
    // promoted to a valid config/rootfs name.
    #expect(PluginTarUtility.cleaned("../config.json") == "../config.json")
    #expect(PluginTarUtility.cleaned("../rootfs/bin/plugin") == "../rootfs/bin/plugin")
    #expect(PluginTarUtility.cleaned("../../config.json") == "../../config.json")
    #expect(PluginTarUtility.cleaned("a/../../x") == "../x")
    // Absolute parents clamp to the root, then the "/" is stripped.
    #expect(PluginTarUtility.cleaned("/../config.json") == "config.json")
    #expect(PluginTarUtility.cleaned("/rootfs/bin/plugin") == "rootfs/bin/plugin")
    // Ordinary cleaning: "//", ".", and resolved mid-path "..".
    #expect(PluginTarUtility.cleaned("./config.json") == "config.json")
    #expect(PluginTarUtility.cleaned("//rootfs//bin") == "rootfs/bin")
    #expect(PluginTarUtility.cleaned("rootfs/../config.json") == "config.json")
}

/// The rewritten-rootfs digest is computed by streaming 1 MiB chunks — the
/// result must equal a single-shot hash of the same bytes, including for
/// files spanning several chunks plus a remainder.
@Test("plugin rootfs digest: streaming hash equals whole-file hash")
func pluginRootfsStreamingDigestUnit() throws {
    let dir = uniqueTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fileURL = dir.appendingPathComponent("rootfs.tar.gz")
    var content = Data()
    let block = Data(repeating: 0xA5, count: 256 * 1024)
    for _ in 0..<14 { content.append(block) }  // 3.5 MiB — several chunks
    try content.write(to: fileURL)
    let expected = "sha256:" + SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    #expect(try PluginTarUtility.sha256Hex(of: fileURL) == expected)
}

/// The interface-type string coder, moby's parse rules (last '.' before
/// first '/').
@Test("plugin interface type string coding: moby's prefix/capability/version split")
func pluginInterfaceTypeCodingUnit() throws {
    let decoded = try JSONDecoder().decode(
        [DockerPluginInterfaceType].self, from: Data(#"["docker.volumedriver/1.0","logdriver"]"#.utf8))
    #expect(decoded[0] == DockerPluginInterfaceType(Prefix: "docker", Capability: "volumedriver", Version: "1.0"))
    // moby's quirk, reproduced verbatim: a dotless string leaves prefixIndex
    // at 0, so the capability span starts at byte 1 ("logdriver" →
    // "ogdriver") and re-marshals as ".ogdriver/".
    #expect(decoded[1] == DockerPluginInterfaceType(Prefix: "", Capability: "ogdriver", Version: ""))
    let encoded = try JSONEncoder().encode(decoded)
    let strings = try JSONDecoder().decode([String].self, from: encoded)
    #expect(strings == ["docker.volumedriver/1.0", ".ogdriver/"])
}

/// The lenient config decode: missing keys become Go zero values, never
/// decode errors (moby's json.Unmarshal + no-op validateConfig).
@Test("plugin config decode is lenient like Go's json zero values")
func pluginConfigLenientDecodeUnit() throws {
    let config = try JSONDecoder().decode(DockerPluginConfig.self, from: Data("{}".utf8))
    #expect(config.Description == "")
    #expect(config.Entrypoint == [])
    #expect(config.IpcHost == false)
    #expect(config.Network == nil)
    #expect(config.rootfs == nil)
}

/// Go's json.Unmarshal matches struct fields case-insensitively — a
/// lowercase config must decode identically (and feed privileges).
@Test("plugin config decode is case-insensitive like Go, and privileges survive it")
func pluginConfigCaseInsensitiveUnit() throws {
    let config = try JSONDecoder().decode(DockerPluginConfig.self, from: lowercaseConfigJSON())
    #expect(config.Description == "a lowercase-keyed plugin")
    #expect(config.Entrypoint == ["/bin/plugin"])
    #expect(
        config.Interface?.Types
            == [DockerPluginInterfaceType(Prefix: "docker", Capability: "volumedriver", Version: "1.0")])
    #expect(config.Linux?.Capabilities == ["CAP_SYS_ADMIN"])
    #expect(config.Network?.networkType == "host")
    #expect(config.User?.UID == 1000)
    // The privilege computation sees the same inputs as for the capitalized
    // form: network=host, the mount source, and the capabilities.
    let privileges = RegistryPluginPrivilegesProvider.computePrivileges(from: config)
    #expect(privileges.map(\.Name) == ["network", "mount", "capabilities"])
    #expect(privileges[0].Value == ["host"])
    #expect(privileges[1].Value == ["/srv/data"])
    #expect(privileges[2].Value == ["CAP_SYS_ADMIN"])
}

/// The interface-type string coder rejects the empty string with a decoding
/// error — its span arithmetic would otherwise index out of bounds and trap
/// the daemon (finding: `{"Interface":{"Types":[""]}}`).
@Test("plugin interface type: the empty string is a decoding error, not a crash")
func pluginInterfaceTypeEmptyStringUnit() throws {
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(
            [DockerPluginInterfaceType].self, from: Data(#"[""]"#.utf8))
    }
}

/// The config's Network decoder propagates type errors like the other
/// config decoders — only an absent or null `Type` is the Go zero value "".
@Test("plugin config network: type errors propagate, absent/null Type stays the zero value")
func pluginConfigNetworkTypeErrorsUnit() throws {
    for bad in [
        Data(#"{"Network":{"Type":123}}"#.utf8),
        Data(#"{"Network":"host"}"#.utf8),
    ] {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(DockerPluginConfig.self, from: bad)
        }
    }
    let nullType = try JSONDecoder().decode(
        DockerPluginConfig.self, from: Data(#"{"Network":{"Type":null}}"#.utf8))
    #expect(nullType.Network?.networkType == "")
}
