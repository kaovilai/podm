// SPDX-License-Identifier: Apache-2.0
import Foundation
import Vapor

/// The DOCKER-dialect `/configs` family (moby v28.5.2
/// `api/server/router/swarm/cluster.go`: `GET /configs`,
/// `POST /configs/create`, `GET /configs/{id}`, `DELETE /configs/{id}`,
/// `POST /configs/{id}/update`), served over a local `ConfigStore` — the
/// config twin of the docker-dialect `/secrets` family. A config is
/// structurally a secret without the sensitivity flag: just an immutable
/// blob with a name and labels, which needs only a local object store, not
/// an orchestrator. No ecosystem precedent exists (podman answers `/configs`
/// with 503 — it has no local config object and no `podman config` CLI, per
/// issue #32) — this is API-completeness work beyond podman parity.
///
/// Contract (verified against moby v28.5.2 and its pinned swarmkit
/// `8c1959736554`; deviations marked):
///
///   - `POST /configs/create` — body is moby's `swarm.ConfigSpec` JSON
///     (`Name`, `Labels`, `Data` base64, optional `Templating` — NO `Driver`
///     field, unlike `swarm.SecretSpec`). Answers **201 Created**
///     `{"ID": "..."}` (`swarm.ConfigCreateResponse`,
///     `cluster_routes.go` `createConfig` → `http.StatusCreated`).
///     Name rules are swarmkit's `validateConfigOrSecretAnnotations`
///     (`manager/controlapi/common.go`): non-empty, ≤64 bytes of
///     `[a-zA-Z0-9-_.]` with alphanumeric first and last character; Data
///     must be 1..<1024000 bytes — swarmkit `manager/controlapi/config.go`
///     `MaxConfigSize` (1000\*1024 — TWICE the secret limit, 500\*1024).
///     Name-in-use answers 409 (DEVIATION: moby's single-node path cannot
///     be hit without a swarm manager, and its gRPC plumbing surfaces
///     swarmkit's `AlreadyExists` as a 500 rpc-error; 409 is the
///     errdefs-correct status — the same choice the secrets family made).
///   - `GET /configs` — moby's swarm list filters
///     (`daemon/cluster/filters.go` `newListConfigsFilters`): `name`
///     (prefix) and `id` (prefix) — OR'd together, per swarmkit
///     `ListConfigs`' `store.Or` — and `label` (`k=v` exact / bare `k`
///     presence) AND'd on top. NOTE: configs have NO `names` (exact) key —
///     that key exists only in the SECRET filter set; moby's
///     `filter.Validate` rejects it here, and so does podm. Reports are
///     moby's `swarm.Config` shape, and — unlike secrets — **`Data` IS
///     returned**: swarmkit nils `Spec.Data` on every secret reply
///     (`secret.go`: "clean the actual secret data so it's never returned")
///     but never on a config reply (`config.go` has no such strip; moby's
///     `convert.ConfigFromGRPC` copies `Data` through).
///   - `GET /configs/{id}` — moby's resolution order
///     (`daemon/cluster/helpers.go` `getConfig`): full ID, exact name, then
///     ID prefix. 0 matches → 404 `config <input> not found`; >1 prefix
///     matches → 400 `config <input> is ambiguous (N matches found)`
///     (errdefs.NotFound / InvalidParameter).
///   - `DELETE /configs/{id}` — same resolution; 204 / 404
///     (`cluster_routes.go` `removeConfig` → `StatusNoContent`).
///   - `POST /configs/{id}/update` — 501 "update is not supported": a local
///     file store cannot meaningfully update-in-place (moby's real update
///     allows label-only changes via swarmkit; podm's store is
///     immutable-blob like its secrets). Stays in the deliberate-stub
///     manifest, same rationale as the secrets update stub.
///
/// ID shape: moby's swarm manager mints config IDs via swarmkit
/// `identity.NewID()` — a 25-char lowercase base36 token. The API contract
/// treats IDs as opaque strings; the store's internal 25-hex-char IDs are
/// the same length and casing class, so they are served as-is — no mapping
/// layer and no store change, the least-invasive choice (same decision the
/// secrets family made).
struct ConfigsRoute: RouteCollection {
    let store: ConfigStore

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/configs", use: Self.listHandler(store: store))
        try routes.registerVersionedRoute(.POST, pattern: "/configs/create", use: Self.createHandler(store: store))
        try routes.registerVersionedRoute(.GET, pattern: "/configs/{id}", use: Self.inspectHandler(store: store))
        try routes.registerVersionedRoute(.DELETE, pattern: "/configs/{id}", use: Self.removeHandler(store: store))
        try routes.registerVersionedRoute(.POST, pattern: "/configs/{id}/update", use: Self.updateHandler)
    }
}

// MARK: - Handlers

extension ConfigsRoute {
    /// `POST /configs/create` — moby `swarm.ConfigSpec` body, 201 with the
    /// new ID. Data arrives base64-encoded (Go's `[]byte` JSON marshaling);
    /// a strict decode failure is a client error, matching Go's json decoder.
    static func createHandler(store: ConfigStore) -> @Sendable (Request) async throws -> Response {
        { req in
            // Collect explicitly: RegexRouter bypasses Vapor's route-level
            // collection, and a bare collect() caps at 16 KiB — a base64
            // payload near the 1024000-byte limit would 413 before the store
            // ever saw it.
            _ = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get()
            let spec: DockerConfigSpec
            do {
                spec = try req.content.decode(DockerConfigSpec.self)
            } catch {
                throw Abort(.badRequest, reason: "invalid config spec: \(error.localizedDescription)")
            }
            // Moby gates templating on API version (<1.37) but swarmkit
            // evaluates it; podm has no templating engine, and silently
            // dropping a requested behavior is worse than a loud 400.
            if spec.Templating != nil {
                throw Abort(.badRequest, reason: "config templating is not supported")
            }
            do {
                let config = try await store.create(
                    name: spec.Name ?? "",
                    data: spec.Data ?? Data(),
                    labels: spec.Labels ?? [:]
                )
                Self.broadcast(event: "create", config: config, req: req)
                // 201 Created — moby's createConfig.
                return try await DockerConfigCreateResponse(ID: config.id).encodeResponse(status: .created, for: req)
            } catch ConfigStore.StoreError.invalidName(let name) {
                // swarmkit's two messages, verbatim shape.
                if name.isEmpty {
                    throw Abort(.badRequest, reason: "name must be provided")
                }
                throw Abort(
                    .badRequest,
                    reason: "invalid name, only 64 [a-zA-Z0-9-_.] characters allowed, and the start and end character must be [a-zA-Z0-9]"
                )
            } catch ConfigStore.StoreError.dataTooLarge {
                throw Abort(.badRequest, reason: "config data must be larger than 0 and less than \(ConfigStore.maxConfigSize) bytes")
            } catch ConfigStore.StoreError.nameInUse(let name) {
                // 409 — see class docs.
                throw Abort(.conflict, reason: "config \(name) already exists")
            } catch ConfigStore.StoreError.persistFailed(let reason, _) {
                throw Abort(.internalServerError, reason: "could not persist the config store: \(reason)")
            } catch ConfigStore.StoreError.quarantineBlocked(let reason) {
                throw Abort(.internalServerError, reason: "config store needs operator attention: \(reason)")
            }
        }
    }

    /// `GET /configs` — moby's `swarm.Config` reports, WITH their `Data`
    /// (swarmkit strips only secret data, never config data — see class
    /// docs).
    static func listHandler(store: ConfigStore) -> @Sendable (Request) async throws -> [DockerConfigReport] {
        { req in
            let configs = await store.listWithPayloads()
            let filters = try Self.parseFilters(req.query[String.self, at: "filters"])
            return
                configs
                .filter { Self.passesFilters($0.config, filters: filters) }
                .map(Self.report)
        }
    }

    /// `GET /configs/{id}` — moby's getConfig resolution: full ID, exact
    /// name, then ID prefix; 0 matches 404, ambiguous prefix 400. Metadata
    /// and payload are read in ONE actor hop (`listWithPayloads`), so a
    /// concurrent remove can never interleave between resolution and the
    /// payload read.
    static func inspectHandler(store: ConfigStore) -> @Sendable (Request) async throws -> DockerConfigReport {
        { req in
            guard let input = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing config id")
            }
            let configs = await store.listWithPayloads()
            switch Self.resolve(input, in: configs.map(\.config)) {
            case .found(let config):
                guard let paired = configs.first(where: { $0.config.id == config.id }) else {
                    throw Abort(.notFound, reason: "config \(input) not found")
                }
                return Self.report(paired)
            case .notFound:
                throw Abort(.notFound, reason: "config \(input) not found")
            case .ambiguous(let count):
                throw Abort(.badRequest, reason: "config \(input) is ambiguous (\(count) matches found)")
            }
        }
    }

    /// `DELETE /configs/{id}` — 204 / 404 with moby's message shape.
    static func removeHandler(store: ConfigStore) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let input = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing config id")
            }
            let configs = await store.list()
            let resolved: StoredConfig
            switch Self.resolve(input, in: configs) {
            case .found(let config):
                resolved = config
            case .notFound:
                throw Abort(.notFound, reason: "config \(input) not found")
            case .ambiguous(let count):
                throw Abort(.badRequest, reason: "config \(input) is ambiguous (\(count) matches found)")
            }
            let removed: StoredConfig
            do {
                // Remove by the RESOLVED full ID, EXACT-ID-only: the
                // snapshot above may be stale by the time the actor runs,
                // and re-resolving by name could hit an unrelated config
                // created in between whose NAME equals the old ID. A lost
                // race is nil → 404, like moby's getConfig miss.
                guard let found = try await store.remove(id: resolved.id) else {
                    throw Abort(.notFound, reason: "config \(input) not found")
                }
                removed = found
            } catch ConfigStore.StoreError.persistFailed(let reason, _) {
                throw Abort(.internalServerError, reason: "could not persist the config store: \(reason)")
            } catch ConfigStore.StoreError.quarantineBlocked(let reason) {
                throw Abort(.internalServerError, reason: "config store needs operator attention: \(reason)")
            }
            Self.broadcast(event: "remove", config: removed, req: req)
            return Response(status: .noContent)
        }
    }

    /// `POST /configs/{id}/update` — 501; see class docs. (Still a
    /// deliberate-stub manifest entry: a 501 IS the stub signature the
    /// conformance test looks for.)
    static func updateHandler(_ req: Request) async throws -> Response {
        let json = "{\"message\": \"update is not supported\"}"
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        return Response(status: .notImplemented, headers: headers, body: .init(string: json))
    }
}

// MARK: - Resolution and filters

extension ConfigsRoute {
    /// moby's `getConfig` resolution order (`daemon/cluster/helpers.go`):
    /// full ID, exact name, then ID prefix. An ambiguous prefix is a CLIENT
    /// error (400) so a short prefix can never silently pick a winner; zero
    /// matches is the 404. Name equality is byte-wise UTF-8, like Go string
    /// comparison and the store's own `sameName`.
    enum ConfigResolution {
        case found(StoredConfig)
        case notFound
        case ambiguous(Int)
    }

    static func resolve(_ input: String, in configs: [StoredConfig]) -> ConfigResolution {
        if let byID = configs.first(where: { $0.id == input }) {
            return .found(byID)
        }
        if let byName = configs.first(where: { $0.name.utf8.elementsEqual(input.utf8) }) {
            return .found(byName)
        }
        let prefixMatches = configs.filter { $0.id.hasPrefix(input) }
        switch prefixMatches.count {
        case 1: return .found(prefixMatches[0])
        case 0: return .notFound
        default: return .ambiguous(prefixMatches.count)
        }
    }

    /// Docker `filters` JSON, restricted to moby's CONFIG filter keys
    /// (`daemon/cluster/filters.go` `newListConfigsFilters`): `name`
    /// (prefix), `id` (prefix), `label` (k=v / presence). The secret
    /// family's `names` (exact) key is NOT accepted here — moby's
    /// `filter.Validate` rejects unaccepted keys for configs, and so does
    /// podm. Both the array form (`{"name": ["a"]}`) and the map form
    /// (`{"name": {"a": true}}`) are accepted — Go's `filters.FromJSON`
    /// decodes both, and its map fallback retains EVERY key regardless of
    /// the boolean. Malformed JSON, unknown keys, non-string array values,
    /// or non-boolean map values are CLIENT errors (podm-wide deviation
    /// from moby's 500s: silently treating them as "no filter" would
    /// return every config where the caller asked for a subset).
    static func parseFilters(_ filtersParam: String?) throws -> [String: [String]] {
        guard let filtersParam, !filtersParam.isEmpty else { return [:] }
        guard let data = filtersParam.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            throw Abort(.badRequest, reason: "invalid filters: expected a JSON object")
        }

        let allowedKeys: Set<String> = ["name", "id", "label"]
        let filterKeys = Set(decoded.keys)
        if !filterKeys.isSubset(of: allowedKeys) {
            throw Abort(.badRequest, reason: "unrecognized filter key \(filterKeys.subtracting(allowedKeys).sorted().joined(separator: ", "))")
        }

        var filters: [String: [String]] = [:]
        for (key, value) in decoded {
            if let arr = value as? [String] {
                filters[key] = arr
            } else if let dict = value as? [String: Any] {
                // Go's fallback decode is map[string]map[string]bool: EVERY
                // key becomes a filter value regardless of its bool, and a
                // non-bool value fails the decode (moby 500s there; podm's
                // standing deviation makes client-input errors 400s).
                var values: [String] = []
                for (filterValue, flag) in dict {
                    guard flag is Bool else {
                        throw Abort(
                            .badRequest,
                            reason: "invalid filter value for \(key): expected a boolean"
                        )
                    }
                    values.append(filterValue)
                }
                filters[key] = values
            } else {
                throw Abort(
                    .badRequest,
                    reason: "invalid filter value for \(key): expected an array of strings"
                )
            }
        }
        return filters
    }

    /// moby/swarmkit list semantics (`manager/controlapi/config.go`
    /// `ListConfigs`): `name`/`id` are OR'd together (one `store.Or` of
    /// name-prefix and ID-prefix lookups — a config matching ANY value
    /// qualifies when either key is present), each prefix applied to its
    /// OWN field only (`ByNamePrefix` for `name`, `ByIDPrefix` for `id` —
    /// a name filter must never match an ID and vice versa, or
    /// `docker config ls -f name=… -q | xargs docker config rm` would
    /// delete configs the user did not select), and `label` entries are
    /// AND'd on top (`filterMatchLabels`: every filter label must be
    /// present; a value requires an exact match, an empty value only
    /// presence).
    static func passesFilters(_ config: StoredConfig, filters: [String: [String]]) -> Bool {
        let namePrefixes = filters["name"] ?? []
        let idPrefixes = filters["id"] ?? []
        if !namePrefixes.isEmpty || !idPrefixes.isEmpty {
            let matched =
                namePrefixes.contains { config.name.hasPrefix($0) }
                || idPrefixes.contains { config.id.hasPrefix($0) }
            if !matched { return false }
        }
        for entry in filters["label"] ?? [] {
            // convertKVStringsToMap: "k=v" → exact value, bare "k" (or
            // "k=") → presence only.
            if let eq = entry.firstIndex(of: "=") {
                let key = String(entry[entry.startIndex..<eq])
                let value = String(entry[entry.index(after: eq)...])
                guard let actual = config.labels[key] else { return false }
                if !value.isEmpty, actual != value { return false }
            } else {
                guard config.labels[entry] != nil else { return false }
            }
        }
        return true
    }

    /// Docker daemon events for configs (`docker events`: config
    /// create/remove) — same broadcast pattern the secrets family uses.
    private static func broadcast(event: String, config: StoredConfig, req: Request) {
        guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else { return }
        let dockerEvent = DockerEvent.make(
            type: "config",
            action: event,
            actorID: config.id,
            attributes: ["name": config.name]
        )
        Task {
            await broadcaster.broadcast(dockerEvent)
        }
    }

    /// moby `swarm.Config` report. `Version.Index` is constant 1 — a
    /// never-updated swarm object carries index 1, and podm's store never
    /// updates. `Spec.Data` IS included (base64 on the wire) — configs are
    /// the non-sensitive twin; only when the payload is missing from a
    /// hand-mangled store is the key omitted (Go's `omitempty`).
    static func report(_ stored: StoredConfigWithPayload) -> DockerConfigReport {
        DockerConfigReport(
            ID: stored.config.id,
            Version: DockerConfigVersion(Index: 1),
            CreatedAt: Self.iso8601.string(from: stored.config.createdAt),
            UpdatedAt: Self.iso8601.string(from: stored.config.updatedAt),
            Spec: DockerConfigReportSpec(
                Name: stored.config.name,
                Labels: stored.config.labels,
                Data: stored.data
            )
        )
    }

    /// RFC3339 with fractional seconds, like Go's `time.Time` marshaling
    /// (RFC3339Nano) that moby's CreatedAt/UpdatedAt fields use.
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Wire types

/// moby `swarm.ConfigCreateResponse`.
struct DockerConfigCreateResponse: Content {
    let ID: String
}

/// moby `swarm.Version` (via `Meta`) — always `{"Index": 1}` here.
struct DockerConfigVersion: Content {
    let Index: UInt64
}

/// The report `Spec` — moby's `swarm.ConfigSpec` on read: `Templating` is
/// omitempty-and-never-set server-side, and `Data` is included (unlike
/// secrets — see `ConfigsRoute`'s class docs).
struct DockerConfigReportSpec: Content {
    let Name: String
    let Labels: [String: String]
    let Data: Data?
}

/// moby `swarm.Config` — the list element and inspect body.
struct DockerConfigReport: Content {
    let ID: String
    let Version: DockerConfigVersion
    let CreatedAt: String
    let UpdatedAt: String
    let Spec: DockerConfigReportSpec
}

/// moby `swarm.Driver` — reused only as the `Templating` reference here
/// (`swarm.ConfigSpec` has no `Driver`, unlike `swarm.SecretSpec`).
struct DockerConfigDriverSpec: Content, Decodable {
    let Name: String?
    let Options: [String: String]?
}

/// moby `swarm.ConfigSpec` — the POST /configs/create body. `Data` is
/// base64 on the wire (Go `[]byte` marshaling); Swift's Codable decodes
/// base64 into `Data` with the same strictness Go's json package applies.
struct DockerConfigSpec: Content, Decodable {
    let Name: String?
    let Labels: [String: String]?
    let Data: Data?
    let Templating: DockerConfigDriverSpec?
}
