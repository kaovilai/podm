// SPDX-License-Identifier: Apache-2.0
import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Vapor

/// The docker-dialect `/plugins` LOCAL-METADATA subset (issue #35), served
/// over a local `PluginStore` — the half of moby's plugin system that needs
/// no plugin runtime:
///
/// - `GET /plugins` — list (moby `api/server/router/plugin/plugin_routes.go`
///   `listPlugins`, filters `enabled`/`capability` per
///   `plugin/backend_linux.go` `Manager.List`).
/// - `GET /plugins/{name}` and `GET /plugins/{name}/json` — inspect (moby
///   `inspectPlugin` → `Store.resolvePluginID`; the bare `/{name}` form is a
///   podm-registered extra that moby does not serve — it answers moby's
///   inspect shape rather than a stub).
/// - `GET /plugins/privileges` — moby's `getPrivileges`: a remote-manifest →
///   `{devices, capabilities}` computation, no runtime involved. (NOTE: the
///   issue text calls this endpoint POST, but moby v28.5.2 registers — and
///   its v1.51 swagger documents — GET; podm follows moby.)
/// - `POST /plugins/create` — local ingest of a tar rootfs+manifest into the
///   metadata store (moby `createPlugin` → `CreateFromContext`: 204, the
///   tarball's `config.json` + `rootfs/` tree, the familiar-name rules, the
///   conflict check).
///
/// The runtime half — `pull`, `enable`, `disable`, `push`, `set`, `upgrade` —
/// stays deliberately stubbed (see RouteSupportManifest): it needs docker's
/// managed-plugin execution model (a privileged plugin container plus the
/// `/run/docker/plugins` socket), which has no mapping onto Apple's
/// microVM-per-container isolation. Ecosystem note: podman registers no
/// `/plugins` family at all (its `pkg/api/server/register_*.go` has no plugin
/// file — unregistered paths 404), so podm's local-metadata answers go beyond
/// podman parity, the same posture as the `/configs` family (issue #32).
///
/// Contract (verified against moby v28.5.2; deviations marked):
///
/// - `POST /plugins/create` — query param `name` (moby
///   `types.PluginCreateOptions.RepoName`), body the plugin context tar.
///   Name rules: `reference.ParseNormalizedNamed` + no digests + TagNameOnly
///   + FamiliarString (`PluginReferenceUtility.repoName`). The tarball must
///   carry a top-level `config.json` (moby: "config not found") and a
///   `rootfs/` tree ("no rootfs found"). The config is decoded leniently
///   (Go json zero values — moby's own `validateConfig` is a no-op TODO).
///   moby then sets `Config.rootfs = {Type: "layers", DiffIds: [rootfs blob
///   digest]}` and `Config.DockerVersion`; podm sets both (the digest is
///   computed over podm's rewrite of the same rootfs entries — see
///   `PluginTarUtility`). Answers **204 No Content**. Duplicate name → 409
///   "plugin %s already exists" (moby `alreadyExistsError`, Conflict).
///   Client-input failures are 400s (podm's standing deviation — moby serves
///   500s for unparseable refs/configs).
/// - `GET /plugins` — moby's `[]*Plugin`; an empty store answers `[]`, which
///   is the trivially-correct answer that keeps `docker plugin ls` healthy.
///   Filters: `enabled` (bool) and `capability` (a plugin is included only
///   when EVERY one of its interface types' capabilities is in the filter's
///   value set — moby's `continue next` loop). Unknown keys, malformed JSON,
///   non-boolean `enabled` values are 400s (moby's `filter.Validate` /
///   `GetBoolOrDefault` errors).
/// - `GET /plugins/{name}(/json)` — moby's resolution: full 64-hex ID first
///   (exact), then exact familiar name, then unambiguous ID prefix. 0
///   matches → 404 `plugin "<input>" not found`; ambiguous prefix → 400
///   `multiple plugins found for "<input>"` (moby errNotFound /
///   errAmbiguous, with Go's %q quoting).
/// - `GET /plugins/privileges?remote=<ref>` — the computed
///   `types.PluginPrivilege` list (see `RegistryPluginPrivilegesProvider`);
///   missing `remote` is a 400 with distribution/reference's own message.
struct PluginsRoute: RouteCollection {
    let store: PluginStore
    let privilegesProvider: PluginPrivilegesProviding

    init(store: PluginStore, privilegesProvider: PluginPrivilegesProviding) {
        self.store = store
        self.privilegesProvider = privilegesProvider
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/plugins", use: Self.listHandler(store: store))
        try routes.registerVersionedRoute(.GET, pattern: "/plugins/privileges", use: Self.privilegesHandler(provider: privilegesProvider))
        try routes.registerVersionedRoute(.GET, pattern: "/plugins/{name}", use: Self.inspectHandler(store: store))
        try routes.registerVersionedRoute(.GET, pattern: "/plugins/{name}/json", use: Self.inspectHandler(store: store))
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/create", use: Self.createHandler(store: store))
    }
}

// MARK: - Handlers

extension PluginsRoute {
    /// `GET /plugins` — moby's list with its two accepted filter keys.
    static func listHandler(store: PluginStore) -> @Sendable (Request) async throws -> [DockerPlugin] {
        { req in
            let filters = try parseListFilters(req.query[String.self, at: "filters"])
            return await store.list()
                .filter { passesFilters($0, filters: filters) }
                .map(report)
        }
    }

    /// `GET /plugins/{name}` and `GET /plugins/{name}/json` — moby's
    /// inspectPlugin over `Store.resolvePluginID`.
    static func inspectHandler(store: PluginStore) -> @Sendable (Request) async throws -> DockerPlugin {
        { req in
            guard let input = req.parameters.get("name"), !input.isEmpty else {
                throw Abort(.badRequest, reason: "Missing plugin name")
            }
            switch await store.resolve(refOrID: input) {
            case .found(let plugin):
                return report(plugin)
            case .notFound:
                throw Abort(.notFound, reason: "plugin \"\(input)\" not found")
            case .ambiguous(let count):
                _ = count
                throw Abort(.badRequest, reason: "multiple plugins found for \"\(input)\"")
            }
        }
    }

    /// `GET /plugins/privileges?remote=<ref>` — moby's getPrivileges.
    static func privilegesHandler(provider: PluginPrivilegesProviding) -> @Sendable (Request) async throws -> [DockerPluginPrivilege] {
        { req in
            guard let remote = req.query[String.self, at: "remote"], !remote.isEmpty else {
                // distribution/reference's own message for a ref that cannot
                // parse (moby surfaces the parse error from parseRemoteRef).
                throw Abort(.badRequest, reason: "invalid reference format")
            }
            return try await provider.privileges(remote: remote, authentication: registryAuth(from: req))
        }
    }

    /// `POST /plugins/create?name=<repo>` — moby's createPlugin: tar body,
    /// 204 on success. The name is validated BEFORE the body is read, so a
    /// probe with no parameters fails fast at the 400.
    static func createHandler(store: PluginStore) -> @Sendable (Request) async throws -> Response {
        { req in
            let rawName = req.query[String.self, at: "name"] ?? ""
            let name: String
            do {
                name = try PluginReferenceUtility.repoName(from: rawName)
            } catch PluginReferenceUtility.NameError.canonical {
                // moby CreateFromContext, verbatim.
                throw Abort(.badRequest, reason: "canonical references are not permitted")
            } catch PluginReferenceUtility.NameError.unparseable(let input) {
                // moby wraps the parse failure; podm's standing deviation
                // makes it a 400 instead of moby's 500.
                throw Abort(.badRequest, reason: "failed to parse reference \(input)")
            }

            // Collect the tar body explicitly: the regex router bypasses
            // Vapor's route-level collection (see the configs family's note
            // on the 16 KiB default cap).
            let bodyData = try await collectBody(req)

            let workDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("podm-plugin-create-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: workDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: workDirectory) }

            // moby's splitConfigRootFSFromTar: config.json out, rootfs tree
            // re-tarred and digested.
            let split: PluginTarSplit
            do {
                split = try PluginTarUtility.split(tarData: bodyData, workDirectory: workDirectory)
            } catch PluginTarUtilityError.noRootFS {
                throw Abort(.badRequest, reason: "no rootfs found")
            } catch PluginTarUtilityError.noConfig {
                throw Abort(.badRequest, reason: "config not found")
            } catch PluginTarUtilityError.archiveReadFailed(let reason) {
                throw Abort(.badRequest, reason: "failed to read the plugin context tar: \(reason)")
            } catch PluginTarUtilityError.archiveWriteFailed(let reason) {
                throw Abort(.internalServerError, reason: "failed to re-encode the plugin rootfs: \(reason)")
            }

            // moby's CreateFromContext decodes the config with Go's json
            // (zero values, no validation — its validateConfig is a TODO).
            guard let config = try? JSONDecoder().decode(DockerPluginConfig.self, from: split.configJSON) else {
                throw Abort(.badRequest, reason: "failed to parse config")
            }
            // moby's create-time adjustments: rootfs digest blob + daemon
            // version (DockerVersion is deprecated in the API but set).
            var adjusted = config
            adjusted.rootfs = DockerPluginConfigRootfs(diff_ids: [split.rootfsDigest], type: "layers")
            adjusted.DockerVersion = getBuildVersion()
            let settings = DockerPluginSettings.emptySettings(from: config)

            let plugin: StoredPlugin
            do {
                plugin = try await store.create(
                    name: name, config: adjusted, settings: settings, pluginReference: name)
            } catch PluginStore.StoreError.nameInUse(let existing) {
                // moby alreadyExistsError — a Conflict (409).
                throw Abort(.conflict, reason: "plugin \(existing) already exists")
            } catch PluginStore.StoreError.persistFailed(let reason) {
                throw Abort(.internalServerError, reason: "could not persist the plugin store: \(reason)")
            } catch PluginStore.StoreError.quarantineBlocked(let reason) {
                throw Abort(.internalServerError, reason: "plugin store needs operator attention: \(reason)")
            }

            broadcast(event: "create", plugin: plugin, req: req)
            // 204 No Content — moby's createPlugin.
            return Response(status: .noContent)
        }
    }
}

// MARK: - Filters

extension PluginsRoute {
    /// The parsed `GET /plugins` filters — moby's two accepted keys
    /// (`plugin/backend_linux.go` `acceptedPluginFilterTags`). `enabled ==
    /// nil` means the key was absent (no filtering); a PRESENT but empty
    /// `enabled` value list is moby's `GetBoolOrDefault` default, false.
    struct PluginListFilters: Sendable, Equatable {
        var enabled: Bool?
        var capabilities: [String]?
    }

    /// Docker `filters` JSON, restricted to moby's PLUGIN filter keys:
    /// `enabled` (bool) and `capability` (exact). Both the array form and
    /// the map form are accepted — Go's `filters.FromJSON` decodes both, and
    /// its map fallback retains EVERY key regardless of the boolean.
    /// Malformed JSON, unknown keys, or non-string array values are CLIENT
    /// errors (podm-wide deviation from moby's 500s).
    static func parseListFilters(_ filtersParam: String?) throws -> PluginListFilters {
        guard let filtersParam, !filtersParam.isEmpty else { return PluginListFilters() }
        guard let data = filtersParam.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            throw Abort(.badRequest, reason: "invalid filters: expected a JSON object")
        }

        let allowedKeys: Set<String> = ["enabled", "capability"]
        let filterKeys = Set(decoded.keys)
        if !filterKeys.isSubset(of: allowedKeys) {
            throw Abort(.badRequest, reason: "unrecognized filter key \(filterKeys.subtracting(allowedKeys).sorted().joined(separator: ", "))")
        }

        var values: [String: [String]] = [:]
        for (key, value) in decoded {
            if let arr = value as? [String] {
                values[key] = arr
            } else if let dict = value as? [String: Any] {
                var entries: [String] = []
                for (filterValue, flag) in dict {
                    guard flag is Bool else {
                        throw Abort(
                            .badRequest,
                            reason: "invalid filter value for \(key): expected a boolean")
                    }
                    entries.append(filterValue)
                }
                values[key] = entries
            } else {
                throw Abort(
                    .badRequest,
                    reason: "invalid filter value for \(key): expected an array of strings")
            }
        }

        var filters = PluginListFilters()
        // moby's `filters.GetBoolOrDefault("enabled", false)` — Go's
        // `strconv.ParseBool` grammar; an invalid value is moby's
        // "invalid filter value" error (a 500 there, a 400 here).
        if let enabledValues = values["enabled"] {
            filters.enabled = false
            if let first = enabledValues.first {
                switch first.lowercased() {
                case "1", "t", "true": filters.enabled = true
                case "0", "f", "false": filters.enabled = false
                default:
                    throw Abort(.badRequest, reason: "invalid filter value for enabled: expected a boolean")
                }
            }
        }
        filters.capabilities = values["capability"]
        return filters
    }

    /// moby `Manager.List`: `enabled` selects enabled-only/disabled-only;
    /// `capability` includes a plugin only when EVERY one of its interface
    /// types' capabilities is in the filter's value set (the `continue next`
    /// loop — a plugin advertising a capability the filter did not list is
    /// excluded; a plugin with NO types passes vacuously).
    static func passesFilters(_ plugin: StoredPlugin, filters: PluginListFilters) -> Bool {
        if let wantEnabled = filters.enabled, plugin.enabled != wantEnabled {
            return false
        }
        if let capabilities = filters.capabilities {
            let wanted = Set(capabilities)
            let types = plugin.config.Interface?.Types ?? []
            if !types.allSatisfy({ wanted.contains($0.Capability) }) {
                return false
            }
        }
        return true
    }
}

// MARK: - Shared helpers

extension PluginsRoute {
    /// moby's X-Registry-Auth header, the same decode the distribution
    /// inspect route uses.
    static func registryAuth(from req: Request) -> Authentication? {
        DistributionJsonRoute.registryAuth(from: req)
    }

    /// Collects the raw request body — the same dual-path collection the
    /// image load route uses (already-collected buffer, else streaming).
    static func collectBody(_ req: Request) async throws -> Data {
        if let data = req.body.data {
            return Data(buffer: data)
        }
        var data = Data()
        for try await chunk in req.body {
            data.append(contentsOf: chunk.readableBytesView)
        }
        return data
    }

    /// Docker daemon events for plugins (`docker events`: plugin create) —
    /// the same broadcast pattern the configs family uses. moby's
    /// `LogPluginEvent(id, name, events.ActionCreate)`.
    private static func broadcast(event: String, plugin: StoredPlugin, req: Request) {
        guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else { return }
        let dockerEvent = DockerEvent.make(
            type: "plugin",
            action: event,
            actorID: plugin.id,
            attributes: ["name": plugin.name]
        )
        Task {
            await broadcaster.broadcast(dockerEvent)
        }
    }

    /// The `types.Plugin` report for a stored plugin.
    static func report(_ stored: StoredPlugin) -> DockerPlugin {
        DockerPlugin(
            Id: stored.id,
            Name: stored.name,
            Enabled: stored.enabled,
            PluginReference: stored.pluginReference.isEmpty ? nil : stored.pluginReference,
            Config: stored.config,
            Settings: stored.settings)
    }
}
