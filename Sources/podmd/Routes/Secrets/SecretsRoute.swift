// SPDX-License-Identifier: Apache-2.0
import Foundation
import Vapor

/// The DOCKER-dialect `/secrets` family (moby v28.5.2
/// `api/server/router/swarm/cluster.go`: `GET /secrets`,
/// `POST /secrets/create`, `GET /secrets/{id}`, `DELETE /secrets/{id}`,
/// `POST /secrets/{id}/update`), served against the SAME local
/// `SecretStore` the libpod dialect (`LibpodSecretsRoute`) uses — one
/// on-disk store, two DTO dialects. Docker secrets need no swarm: podman
/// serves this exact family from its purely local secret store
/// (`pkg/api/handlers/compat/secrets.go`), and podm's store is that
/// facility.
///
/// Contract (verified against moby v28.5.2 sources; deviations marked):
///
///   - `POST /secrets/create` — body is moby's `swarm.SecretSpec` JSON
///     (`Name`, `Labels`, `Data` base64, optional `Driver`/`Templating`).
///     Answers **201 Created** `{"ID": "..."}` (`swarm.SecretCreateResponse`,
///     `cluster_routes.go` `createSecret` → `http.StatusCreated`; podman's
///     compat handler answers 200 — moby's status is the contract here).
///     Data must be 1..<512000 bytes after base64 decoding — swarmkit's
///     `validation.MaxSecretSize` (500*1024) and `ValidateSecretPayload`
///     match podman's `maxSecretSize` exactly, so the shared store's
///     validation stands. Name-in-use answers 409 (DEVIATION: moby's
///     single-node path cannot be hit without a swarm manager, and its
///     gRPC plumbing surfaces swarmkit's `AlreadyExists` as a 500
///     rpc-error; podman's compat handler answers 409, which is also the
///     errdefs-correct status — same choice the libpod dialect made).
///   - `GET /secrets` — moby's swarm list filters
///     (`daemon/cluster/filters.go` `newListSecretsFilters`):
///     `names` (exact), `name` (prefix), `id` (prefix) — OR'd together,
///     per swarmkit `ListSecrets`' `store.Or`, each scoped to its own field
///     — and `label` (`k=v` exact / bare `k` or `k=` presence, swarmkit
///     `filterMatchLabels`) AND'd on top. Reports are
///     moby's `swarm.Secret` shape, metadata only — `Data` is NEVER
///     returned (swarmkit nils it before responding).
///   - `GET /secrets/{id}` — moby's resolution order
///     (`daemon/cluster/helpers.go` `getSecret`): full ID, exact name,
///     then ID prefix. 0 matches → 404 `secret <input> not found`;
///     >1 prefix matches → 400 `secret <input> is ambiguous (N matches
///     found)` (errdefs.NotFound / InvalidParameter).
///   - `DELETE /secrets/{id}` — same resolution; 204 / 404
///     (`cluster_routes.go` `removeSecret` → `StatusNoContent`).
///   - `POST /secrets/{id}/update` — 501 "update is not supported",
///     podman compat parity (`UpdateSecret`): a local file store cannot
///     meaningfully update-in-place, and podm's replace semantics re-store
///     under a fresh ID anyway. Stays in the deliberate-stub manifest.
///
/// ID shape: moby's swarm manager mints secret IDs via swarmkit
/// `identity.NewID()` — a 25-char lowercase base36 token
/// (`identity/randomid.go`: 128 random bits, base36, fixed length 25).
/// The API contract treats IDs as opaque strings; the store's internal
/// 25-hex-char IDs (podman's `GenerateNonCryptoID` shape) are the same
/// length and casing class, so they are served as-is — no mapping layer
/// and no store change, the least-invasive choice. A secret created via
/// the docker API is visible via `podman secret ls` and vice versa.
struct SecretsRoute: RouteCollection {
    let store: SecretStore

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/secrets", use: Self.listHandler(store: store))
        try routes.registerVersionedRoute(.POST, pattern: "/secrets/create", use: Self.createHandler(store: store))
        try routes.registerVersionedRoute(.GET, pattern: "/secrets/{id}", use: Self.inspectHandler(store: store))
        try routes.registerVersionedRoute(.DELETE, pattern: "/secrets/{id}", use: Self.removeHandler(store: store))
        try routes.registerVersionedRoute(.POST, pattern: "/secrets/{id}/update", use: Self.updateHandler)
    }
}

// MARK: - Handlers

extension SecretsRoute {
    /// `POST /secrets/create` — moby `swarm.SecretSpec` body, 201 with the
    /// new ID. Data arrives base64-encoded (Go's `[]byte` JSON marshaling);
    /// a strict decode failure is a client error, matching Go's json decoder.
    static func createHandler(store: SecretStore) -> @Sendable (Request) async throws -> Response {
        { req in
            // Collect explicitly: RegexRouter bypasses Vapor's route-level
            // collection, and a bare collect() caps at 16 KiB — a base64
            // payload near the 512000-byte limit would 413 before the store
            // ever saw it.
            _ = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get()
            let spec: DockerSecretSpec
            do {
                spec = try req.content.decode(DockerSecretSpec.self)
            } catch {
                throw Abort(.badRequest, reason: "invalid secret spec: \(error.localizedDescription)")
            }
            // Moby gates templating on API version (<1.37) but swarmkit
            // evaluates it; podm has no templating engine, and silently
            // dropping a requested behavior is worse than a loud 400.
            if spec.Templating != nil {
                throw Abort(.badRequest, reason: "secret templating is not supported")
            }
            // swarmkit requires a driver NAME when a driver is set
            // (validateSecretSpec); the store rejects anything but "file".
            if let driver = spec.Driver, driver.Name == nil || driver.Name?.isEmpty == true {
                throw Abort(.badRequest, reason: "secret driver must have a name")
            }
            do {
                let secret = try await store.create(
                    name: spec.Name ?? "",
                    data: spec.Data ?? Data(),
                    driver: spec.Driver?.Name,
                    labels: spec.Labels ?? [:],
                    driverOptions: spec.Driver?.Options ?? [:],
                    replace: false,
                    ignore: false
                )
                Self.broadcast(event: "create", secret: secret, req: req)
                // 201 Created — moby's createSecret (podman compat answers
                // 200; moby is the dialect contract).
                return try await DockerSecretCreateResponse(ID: secret.id).encodeResponse(status: .created, for: req)
            } catch SecretStore.StoreError.invalidName(let name) {
                throw Abort(.badRequest, reason: "secret name \"\(name)\" can not include '=', '/', ',', or the '\\0' (NULL) and be between 1 and 253 characters")
            } catch SecretStore.StoreError.dataTooLarge {
                throw Abort(.badRequest, reason: "secret data must be larger than 0 and less than \(SecretStore.maxSecretSize) bytes")
            } catch SecretStore.StoreError.nameInUse(let name) {
                // 409 per podman's compat handler — see class docs.
                throw Abort(.conflict, reason: "secret \(name) already exists")
            } catch SecretStore.StoreError.unsupportedDriver(let driver) {
                throw Abort(.badRequest, reason: "unknown secrets driver \(driver): only the file driver is implemented")
            } catch SecretStore.StoreError.unsupportedDriverOption(let option) {
                throw Abort(
                    .badRequest,
                    reason: "unsupported driver option \(option): the file driver only supports its default storage location"
                )
            } catch SecretStore.StoreError.persistFailed(let reason, _) {
                throw Abort(.internalServerError, reason: "could not persist the secret store: \(reason)")
            } catch SecretStore.StoreError.quarantineBlocked(let reason) {
                throw Abort(.internalServerError, reason: "secret store needs operator attention: \(reason)")
            }
        }
    }

    /// `GET /secrets` — metadata-only reports; `Data` never leaves the
    /// store (swarmkit nils `Spec.Data` before every list/inspect reply).
    static func listHandler(store: SecretStore) -> @Sendable (Request) async throws -> [DockerSecretReport] {
        { req in
            let secrets = await store.list()
            let filters = try Self.parseFilters(req.query[String.self, at: "filters"])
            return
                secrets
                .filter { Self.passesFilters($0, filters: filters) }
                .map(Self.report)
        }
    }

    /// `GET /secrets/{id}` — moby's getSecret resolution: full ID, exact
    /// name, then ID prefix; 0 matches 404, ambiguous prefix 400.
    static func inspectHandler(store: SecretStore) -> @Sendable (Request) async throws -> DockerSecretReport {
        { req in
            guard let input = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing secret id")
            }
            let secrets = await store.list()
            switch Self.resolve(input, in: secrets) {
            case .found(let secret):
                return Self.report(secret)
            case .notFound:
                throw Abort(.notFound, reason: "secret \(input) not found")
            case .ambiguous(let count):
                throw Abort(.badRequest, reason: "secret \(input) is ambiguous (\(count) matches found)")
            }
        }
    }

    /// `DELETE /secrets/{id}` — 204 / 404 with moby's message shape.
    static func removeHandler(store: SecretStore) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let input = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing secret id")
            }
            let secrets = await store.list()
            let resolved: StoredSecret
            switch Self.resolve(input, in: secrets) {
            case .found(let secret):
                resolved = secret
            case .notFound:
                throw Abort(.notFound, reason: "secret \(input) not found")
            case .ambiguous(let count):
                throw Abort(.badRequest, reason: "secret \(input) is ambiguous (\(count) matches found)")
            }
            let removed: StoredSecret
            do {
                // Remove by EXACT ID, atomically inside the store: between
                // the snapshot above and this actor hop a libpod replacement
                // can retire the resolved ID and a create can recycle it as
                // a NAME, which remove(nameOrID:)'s name fallback would then
                // delete (the unrelated secret, 204 instead of 404).
                // remove(id:) never falls back to a name; nil → 404, exactly
                // like podman's ErrNoSuchSecret on a lost race.
                guard let found = try await store.remove(id: resolved.id) else {
                    throw Abort(.notFound, reason: "secret \(input) not found")
                }
                removed = found
            } catch SecretStore.StoreError.persistFailed(let reason, _) {
                throw Abort(.internalServerError, reason: "could not persist the secret store: \(reason)")
            } catch SecretStore.StoreError.quarantineBlocked(let reason) {
                throw Abort(.internalServerError, reason: "secret store needs operator attention: \(reason)")
            }
            Self.broadcast(event: "remove", secret: removed, req: req)
            return Response(status: .noContent)
        }
    }

    /// `POST /secrets/{id}/update` — 501, podman compat parity; see class
    /// docs. (Still a deliberate-stub manifest entry: a 501 IS the stub
    /// signature the conformance test looks for.)
    static func updateHandler(_ req: Request) async throws -> Response {
        let json = "{\"message\": \"update is not supported\"}"
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        return Response(status: .notImplemented, headers: headers, body: .init(string: json))
    }
}

// MARK: - Resolution and filters

extension SecretsRoute {
    /// moby's `getSecret` resolution order (`daemon/cluster/helpers.go`):
    /// full ID, exact name, then ID prefix. An ambiguous prefix is a CLIENT
    /// error (400) so a short prefix can never silently pick a winner; zero
    /// matches is the 404. Name equality is byte-wise UTF-8, like Go string
    /// comparison and the store's own `sameName`.
    enum SecretResolution {
        case found(StoredSecret)
        case notFound
        case ambiguous(Int)
    }

    static func resolve(_ input: String, in secrets: [StoredSecret]) -> SecretResolution {
        if let byID = secrets.first(where: { $0.id == input }) {
            return .found(byID)
        }
        if let byName = secrets.first(where: { $0.name.utf8.elementsEqual(input.utf8) }) {
            return .found(byName)
        }
        let prefixMatches = secrets.filter { $0.id.hasPrefix(input) }
        switch prefixMatches.count {
        case 1: return .found(prefixMatches[0])
        case 0: return .notFound
        default: return .ambiguous(prefixMatches.count)
        }
    }

    /// Docker `filters` JSON, restricted to moby's secret filter keys
    /// (`daemon/cluster/filters.go` `newListSecretsFilters`): `names`
    /// (exact), `name` (prefix), `id` (prefix), `label` (k=v / presence).
    /// Both the array form (`{"names": ["a"]}`) and the map form
    /// (`{"names": {"a": true}}`) are accepted — Go's `filters.FromJSON`
    /// decodes both. Malformed JSON, unknown keys, or non-string values are
    /// CLIENT errors (podm-wide deviation from moby's 500s: silently
    /// treating them as "no filter" would return every secret where the
    /// caller asked for a subset).
    static func parseFilters(_ filtersParam: String?) throws -> [String: [String]] {
        guard let filtersParam, !filtersParam.isEmpty else { return [:] }
        guard let data = filtersParam.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            throw Abort(.badRequest, reason: "invalid filters: expected a JSON object")
        }

        let allowedKeys: Set<String> = ["names", "name", "id", "label"]
        let filterKeys = Set(decoded.keys)
        if !filterKeys.isSubset(of: allowedKeys) {
            throw Abort(.badRequest, reason: "unrecognized filter key \(filterKeys.subtracting(allowedKeys).sorted().joined(separator: ", "))")
        }

        var filters: [String: [String]] = [:]
        for (key, value) in decoded {
            if let arr = value as? [String] {
                filters[key] = arr
            } else if let dict = value as? [String: Any] {
                // Go's map form decodes into map[string]bool, so a
                // non-boolean value (e.g. the STRING "true") fails the
                // decode — a client error here, like the array form's
                // non-string elements. Keys are retained regardless of
                // their boolean: moby's `Args.Get` walks the map's keys
                // only, so {"names":{"alpha":false}} still selects alpha.
                // The bool check uses CFBoolean identity: JSONSerialization
                // hands back NSNumber for BOTH JSON booleans and numbers,
                // and Swift's NSNumber→Bool bridge makes even `1 is Bool`
                // true — only the CFBoolean-backed singletons discriminate.
                for mapValue in dict.values {
                    guard Self.isJSONBoolean(mapValue) else {
                        throw Abort(
                            .badRequest,
                            reason: "invalid filter value for \(key): map values must be booleans"
                        )
                    }
                }
                filters[key] = Array(dict.keys)
            } else {
                throw Abort(
                    .badRequest,
                    reason: "invalid filter value for \(key): expected an array of strings"
                )
            }
        }
        return filters
    }

    /// True only for a JSONSerialization-produced JSON boolean. JSON booleans
    /// arrive as NSNumber backed by the CFBoolean singletons; JSON numbers
    /// are CFNumber-backed NSNumbers that Swift's `is Bool` / `as? Bool`
    /// bridge happily accepts (an `NSNumber(value: 1)` answers `is Bool`),
    /// so identity against `kCFBooleanTrue`/`kCFBooleanFalse` is the only
    /// reliable discriminator. Non-NSNumber values (strings, arrays…) fail
    /// the cast and report false.
    private static func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return number === kCFBooleanTrue || number === kCFBooleanFalse
    }

    /// moby/swarmkit list semantics (`manager/controlapi/secret.go`
    /// `ListSecrets`): `names`/`name`/`id` are OR'd together (one
    /// `store.Or` of exact-name, name-prefix, and ID-prefix lookups), and
    /// `label` entries are AND'd on top. Each selector applies to its OWN
    /// field only — `names`/`name` against `secret.name`, `id` against
    /// `secret.id` — so an `id` filter that happens to equal (or prefix) a
    /// secret's NAME must not match it, and vice versa.
    static func passesFilters(_ secret: StoredSecret, filters: [String: [String]]) -> Bool {
        let exactNames = filters["names"] ?? []
        let namePrefixes = filters["name"] ?? []
        let idPrefixes = filters["id"] ?? []
        if !(exactNames.isEmpty && namePrefixes.isEmpty && idPrefixes.isEmpty) {
            // Name comparisons are byte-wise UTF-8 (Go string semantics,
            // like the store's sameName): Swift's == / hasPrefix fold
            // canonically equivalent Unicode, which would conflate the
            // byte-distinct NFC/NFD names the store deliberately keeps
            // separate.
            let nameMatch =
                exactNames.contains { secret.name.utf8.elementsEqual($0.utf8) }
                || namePrefixes.contains { secret.name.utf8.starts(with: $0.utf8) }
            let idMatch = idPrefixes.contains { secret.id.utf8.starts(with: $0.utf8) }
            if !nameMatch && !idMatch {
                return false
            }
        }
        for entry in filters["label"] ?? [] {
            // This endpoint's swarm path (moby's newListSecretsFilters →
            // convertKVStringsToMap → swarmkit's filterMatchLabels): "k=v"
            // requires an exact value; bare "k" or "k=" (an empty map
            // value) is PRESENCE-only — a secret labeled team=db matches
            // "team=" (note: NOT filters.MatchKVList, which the non-swarm
            // endpoints use and which treats "k=" as an exact empty value).
            if let eq = entry.firstIndex(of: "=") {
                let key = String(entry[entry.startIndex..<eq])
                let value = String(entry[entry.index(after: eq)...])
                guard let actual = secret.labels[key] else { return false }
                if !value.isEmpty, actual != value { return false }
            } else {
                guard secret.labels[entry] != nil else { return false }
            }
        }
        return true
    }

    /// Docker daemon events for secrets (`docker events`: secret
    /// create/remove) — same broadcast the libpod dialect emits, so both
    /// dialects' mutations are visible on ONE event stream.
    private static func broadcast(event: String, secret: StoredSecret, req: Request) {
        guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else { return }
        let dockerEvent = DockerEvent.make(
            type: "secret",
            action: event,
            actorID: secret.id,
            attributes: ["name": secret.name]
        )
        Task {
            await broadcaster.broadcast(dockerEvent)
        }
    }

    /// moby `swarm.Secret` report. `Version.Index` is constant 1 — podman's
    /// compat reports do the same ("we currently can't update a secret, so
    /// we default the version to 1"), and a never-updated swarm object also
    /// carries index 1. `Data` is NEVER part of the report shape.
    static func report(_ secret: StoredSecret) -> DockerSecretReport {
        DockerSecretReport(
            ID: secret.id,
            Version: DockerSecretVersion(Index: 1),
            CreatedAt: Self.iso8601.string(from: secret.createdAt),
            UpdatedAt: Self.iso8601.string(from: secret.updatedAt),
            Spec: DockerSecretReportSpec(Name: secret.name, Labels: secret.labels)
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

/// moby `swarm.SecretCreateResponse`.
struct DockerSecretCreateResponse: Content {
    let ID: String
}

/// moby `swarm.Version` (via `Meta`) — always `{"Index": 1}` here.
struct DockerSecretVersion: Content {
    let Index: UInt64
}

/// The report `Spec` — moby's `swarm.SecretSpec` on read: `Data`,
/// `Driver`, and `Templating` are all omitempty-and-never-set server-side,
/// so only `Name` and `Labels` ever appear.
struct DockerSecretReportSpec: Content {
    let Name: String
    let Labels: [String: String]
}

/// moby `swarm.Secret` — the list element and inspect body.
struct DockerSecretReport: Content {
    let ID: String
    let Version: DockerSecretVersion
    let CreatedAt: String
    let UpdatedAt: String
    let Spec: DockerSecretReportSpec
}

/// moby `swarm.Driver` — a driver reference (`Name` + `Options`).
struct DockerSecretDriverSpec: Content, Decodable {
    let Name: String?
    let Options: [String: String]?
}

/// moby `swarm.SecretSpec` — the POST /secrets/create body. `Data` is
/// base64 on the wire (Go `[]byte` marshaling); Swift's Codable decodes
/// base64 into `Data` with the same strictness Go's json package applies.
struct DockerSecretSpec: Content, Decodable {
    let Name: String?
    let Labels: [String: String]?
    let Data: Data?
    let Driver: DockerSecretDriverSpec?
    let Templating: DockerSecretDriverSpec?
}
