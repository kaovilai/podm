// SPDX-License-Identifier: Apache-2.0
import Foundation
import Vapor
import os

/// Podman's LOCAL secret store family — `podman secret create/ls/inspect/rm/exists`
/// over the bindings client. The Docker-dialect `/secrets` surface
/// (`SecretsRoute`) shares the same store; this family stays the podman
/// bindings dialect.
///
/// Contract (verified against podman v5.4.0 — identical paths in v6, plus the
/// `ignore` create flag added there; `pkg/api/server/register_secrets.go`):
///
///   - `POST   /libpod/secrets/create`        → libpod.CreateSecret: query params
///     `name`, `driver`, `driveropts` (JSON map string), `labels` (JSON map
///     string), `replace`, `ignore`; the REQUEST BODY is the raw secret payload
///     (this is what `pkg/bindings/secrets` ToParams actually sends). Answers
///     200 `{"ID": "..."}` (`entities.SecretCreateReport`).
///   - `GET    /libpod/secrets/json`          → compat.ListSecrets: libpod
///     requests get the plain `[]entities.SecretInfoReport` (no Docker-compat
///     `Version` wrapper). Filters: `name`, `id` — regex values
///     (`pkg/domain/utils/secrets_filters.go`).
///   - `GET    /libpod/secrets/{name}/json`   → compat.InspectSecret: libpod
///     dialect plain report; `showsecret=true` (libpod-only in podman) fills
///     `SecretData` with the RAW payload string — the ONLY path that reveals
///     it (podman's `secretToReportWithData` passes `string(data)` through
///     unencoded).
///   - `GET    /libpod/secrets/{name}/exists` → libpod.SecretExists: 204 / 404.
///   - `DELETE /libpod/secrets/{name}`        → compat.RemoveSecret: 204 / 404.
///
/// One deviation from upstream: name-in-use on create answers 409 (podman's
/// compat handler does this; the libpod handler blindly maps every error to
/// 500) and unknown drivers/invalid filter keys answer 400 rather than 500 —
/// same bodies, saner statuses.
struct LibpodSecretsRoute: RouteCollection {
    let store: SecretStore

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/secrets/create", use: Self.createHandler(store: store))
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/secrets/json", use: Self.listHandler(store: store))
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/secrets/{name}/json", use: Self.inspectHandler(store: store))
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/secrets/{name}/exists", use: Self.existsHandler(store: store))
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/secrets/{name}", use: Self.removeHandler(store: store))
    }
}

// MARK: - Handlers

extension LibpodSecretsRoute {
    /// `POST /libpod/secrets/create` — body is the raw payload, options ride in
    /// the query string (podman bindings ToParams: scalars plain, maps as JSON
    /// strings).
    static func createHandler(store: SecretStore) -> @Sendable (Request) async throws -> LibpodSecretCreateReport {
        { req in
            let name = req.query[String.self, at: "name"] ?? ""
            // An explicit empty driver means "use the default" in podman
            // (cfg.Secrets.Driver fallback), not "unknown driver ''".
            let rawDriver = req.query[String.self, at: "driver"]
            let driver = rawDriver?.isEmpty == true ? nil : rawDriver
            // Malformed map params are a client error (400). This is a
            // deliberate deviation: podman's own map converter
            // (convertStringMap, pkg/api/handlers/decoder.go) LOGS and
            // swallows json.Unmarshal failures, treating them as empty maps
            // — but silently dropping labels a caller believes it set is
            // worse than a 400.
            let labels = try Self.queryMap("labels", in: req.url.query)
            let driverOpts = try Self.queryMap("driveropts", in: req.url.query)
            // Tri-state flags read from the raw query string (Vapor materializes
            // absent Bools as false); podman truthiness per
            // LibpodImageRemoveRoute.queryFlag.
            let replace = LibpodImageRemoveRoute.queryFlag("replace", in: req.url.query) ?? false
            let ignore = LibpodImageRemoveRoute.queryFlag("ignore", in: req.url.query) ?? false

            // The secret payload: the streamed body, collected explicitly (a
            // no-op when already collected). RegexRouter bypasses Vapor's
            // route-level collection, and a bare collect() caps at 16 KiB
            // (Vapor's `1 << 14` default) — a valid secret up to podman's
            // 512000-byte maxSecretSize would 413. Collect with the daemon's
            // configured cap instead; the store enforces the real size limit
            // (podman itself io.ReadAll's the body with no cap at all, so
            // this stays strictly tighter).
            _ = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get()
            let data = req.body.data.map { Data(buffer: $0) } ?? Data()

            do {
                let secret = try await store.create(
                    name: name,
                    data: data,
                    driver: driver,
                    labels: labels,
                    driverOptions: driverOpts,
                    replace: replace,
                    ignore: ignore
                )
                Self.broadcast(event: "create", secret: secret, req: req)
                return LibpodSecretCreateReport(ID: secret.id)
            } catch SecretStore.StoreError.invalidName(let name) {
                throw Abort(.badRequest, reason: "secret name \"\(name)\" can not include '=', '/', ',', or the '\\0' (NULL) and be between 1 and 253 characters")
            } catch SecretStore.StoreError.dataTooLarge {
                throw Abort(.badRequest, reason: "secret data must be larger than 0 and less than \(SecretStore.maxSecretSize) bytes")
            } catch SecretStore.StoreError.ignoreAndReplace {
                throw Abort(.badRequest, reason: "ignoreIfExists and replace cannot be used together")
            } catch SecretStore.StoreError.nameInUse(let name) {
                // Podman's error text, compat's status (see class docs).
                throw Abort(.conflict, reason: "\(name): secret name in use")
            } catch SecretStore.StoreError.unsupportedDriver(let driver) {
                throw Abort(.badRequest, reason: "unknown secrets driver \(driver): only the file driver is implemented")
            } catch SecretStore.StoreError.unsupportedDriverOption(let option) {
                throw Abort(
                    .badRequest,
                    reason: "unsupported driver option \(option): the file driver only supports its default storage location"
                )
            } catch SecretStore.StoreError.persistFailed(let reason, _) {
                // Podman maps store/persist failures to 500 too
                // (utils.InternalServerError in both the libpod and compat
                // create handlers) — a create that cannot be durably written
                // must not answer 200 and vanish on restart.
                throw Abort(.internalServerError, reason: "could not persist the secret store: \(reason)")
            } catch SecretStore.StoreError.quarantineBlocked(let reason) {
                throw Abort(.internalServerError, reason: "secret store needs operator attention: \(reason)")
            }
        }
    }

    /// `GET /libpod/secrets/json` — metadata only; the payload is never included.
    static func listHandler(store: SecretStore) -> @Sendable (Request) async throws -> [LibpodSecretInfoReport] {
        { req in
            let secrets = await store.list()
            let filters = try Self.parseFilters(req.query[String.self, at: "filters"])
            // passesFilters is async (time-boxed regex matching — see its
            // doc comment), so the filter loop cannot be a `filter` closure.
            var reports: [LibpodSecretInfoReport] = []
            for secret in secrets where try await Self.passesFilters(secret, filters: filters) {
                reports.append(Self.report(secret))
            }
            return reports
        }
    }

    /// `GET /libpod/secrets/{name}/json` — `showsecret=true` is the only reveal
    /// path (podman gates it on the request being libpod, which this route is).
    /// Metadata and payload are fetched in ONE store hop so a concurrent
    /// replace/remove cannot interleave between the two reads.
    static func inspectHandler(store: SecretStore) -> @Sendable (Request) async throws -> LibpodSecretInfoReport {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing secret name")
            }
            let showSecret = LibpodImageRemoveRoute.queryFlag("showsecret", in: req.url.query) ?? false
            guard let found = await store.inspect(nameOrID: name, showSecret: showSecret) else {
                throw Abort(.notFound, reason: "no such secret")
            }
            if let payload = found.payload {
                // RAW payload, not base64: podman's secretToReportWithData
                // passes string(data) straight through
                // (pkg/domain/infra/abi/secrets.go) and the bindings decode
                // SecretData as a plain string, so encoding here would make
                // `podman secret inspect --showsecret` print ciphertext.
                // String(decoding:as:) maps invalid UTF-8 to U+FFFD — the
                // same thing Go's json.Marshal does to an invalid-UTF-8
                // string.
                return Self.report(found.secret, secretData: String(decoding: payload, as: UTF8.self))
            }
            return Self.report(found.secret)
        }
    }

    /// `GET /libpod/secrets/{name}/exists` — 204 / 404, no body on success.
    static func existsHandler(store: SecretStore) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing secret name")
            }
            guard await store.lookup(nameOrID: name) != nil else {
                throw Abort(.notFound, reason: "no such secret")
            }
            return Response(status: .noContent)
        }
    }

    /// `DELETE /libpod/secrets/{name}` — 204 / 404.
    static func removeHandler(store: SecretStore) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing secret name")
            }
            let removed: StoredSecret
            do {
                guard let found = try await store.remove(nameOrID: name) else {
                    throw Abort(.notFound, reason: "no such secret")
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
}

// MARK: - Query helpers

extension LibpodSecretsRoute {
    /// Decodes a map-valued query param the way podman's bindings client sends
    /// it: `labels={"a":"b"}` (ToParams JSON-marshals maps into a plain
    /// string, QueryEscape'd). A present-but-unparseable value is a client
    /// error, not an empty map — silently dropping labels a caller believes
    /// it set would be worse (see the deviation note in `createHandler`).
    static func queryMap(_ name: String, in query: String?) throws -> [String: String] {
        guard let query, !query.isEmpty else { return [:] }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.first == Substring(name), let raw = parts.dropFirst().first else { continue }
            // Form-encoding semantics (Go's url.ParseQuery / moby's
            // httputils.ParseForm, which podman shares via net/http): a
            // literal '+' in the raw query means SPACE — podman's bindings
            // QueryEscape every space into one. Rewriting '+' to '%20'
            // before percent-decoding keeps a client's '%2B' a literal '+',
            // exactly like Vapor's own query parser.
            let plusDecoded = raw.replacingOccurrences(of: "+", with: "%20")
            guard let decoded = plusDecoded.removingPercentEncoding, !decoded.isEmpty else { return [:] }
            guard let map = try? JSONDecoder().decode([String: String].self, from: Data(decoded.utf8)) else {
                throw Abort(.badRequest, reason: "invalid JSON in \(name) query parameter")
            }
            return map
        }
        return [:]
    }

    /// Docker-style `filters` JSON (`{"name": ["..."], "id": ["..."]}`).
    /// Podman accepts only the `name` and `id` keys (`IfPassesSecretsFilter`).
    static func parseFilters(_ filtersParam: String?) throws -> [String: [String]] {
        guard let filtersParam, !filtersParam.isEmpty else { return [:] }
        guard let data = filtersParam.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            // Malformed or non-object filters (not-json, `[]`) are CLIENT
            // errors — silently treating them as "no filter" returns every
            // secret where the caller asked for a subset.
            throw Abort(.badRequest, reason: "invalid filters: expected a JSON object")
        }

        let allowedKeys: Set<String> = ["name", "id"]
        let filterKeys = Set(decoded.keys)
        if !filterKeys.isSubset(of: allowedKeys) {
            throw Abort(.badRequest, reason: "invalid filter \(filterKeys.subtracting(allowedKeys).sorted().joined(separator: ", "))")
        }

        var filters: [String: [String]] = [:]
        for (key, value) in decoded {
            if let arr = value as? [String] {
                filters[key] = arr
            } else if let dict = value as? [String: Any] {
                // Docker-style {"name": {"mysecret": true}} object form.
                filters[key] = dict.compactMap { (key, value) in (value as? Bool == true) ? key : nil }
            } else {
                // A value that is neither an array of strings nor the
                // object form ("db-password", [123], true) is a client
                // error: Go decodes filters into map[string][]string and
                // fails the whole request on such a value — and silently
                // dropping it would return every secret where the caller
                // asked for a subset.
                throw Abort(
                    .badRequest,
                    reason: "invalid filter value for \(key): expected an array of strings"
                )
            }
        }
        return filters
    }

    /// Regex matching per podman's `util.StringMatchRegexSlice`: a value
    /// matches when its regex is found anywhere in the target string. An
    /// invalid pattern is a client error.
    ///
    /// NSRegularExpression (ICU) is a BACKTRACKING engine with no
    /// cancellation: a pathological pattern such as `(a+)+b` against a run
    /// of a's runs exponentially and would hang the event loop — podman is
    /// immune by construction because Go's regexp package is RE2 (linear
    /// time, no backtracking). Every match therefore runs off the event
    /// loop under a deadline; a pattern that exceeds the budget is a client
    /// error, and blown matches are capped (`maxBlownFilterMatches`) so
    /// repeated hostile filters cannot accumulate runaway threads — at
    /// saturation, filter matching is refused until the daemon restarts. A
    /// blown match keeps spinning on its Dispatch thread (NSRegularExpression
    /// cannot be interrupted), but the daemon stays responsive and the
    /// damage stays bounded.
    static func passesFilters(_ secret: StoredSecret, filters: [String: [String]]) async throws -> Bool {
        for (key, values) in filters {
            let target = key == "name" ? secret.name : secret.id
            var matched = false
            for value in values {
                // A malformed pattern is a CLIENT error (400 with the
                // diagnostic), not a Foundation error the error middleware
                // would render as a 500.
                let regex: NSRegularExpression
                do {
                    regex = try NSRegularExpression(pattern: value)
                } catch {
                    throw Abort(.badRequest, reason: "invalid filter pattern \(key)=\(value): \(error.localizedDescription)")
                }
                if try await Self.timedMatch(regex, in: target) {
                    matched = true
                    break
                }
            }
            if !matched {
                return false
            }
        }
        return true
    }

    /// Per-match wall-clock budget. Generous for honest patterns (subjects
    /// are secret names, ≤253 bytes), far below the first doubling step of
    /// an exponential blowup.
    private static let matchBudgetMs = 200

    /// Admission control for filter matching: ICU cannot be interrupted, so
    /// a blown match keeps spinning on its Dispatch thread until it
    /// finishes — for an exponential pattern, effectively never. Bounding
    /// the damage therefore means bounding how many blown matches are
    /// tolerated: once this many have blown their budget, filter matching
    /// is refused outright until the daemon restarts. Honest patterns are
    /// unaffected until saturation (podman avoids the entire class: Go's
    /// regexp is RE2, linear time, no backtracking).
    static let maxBlownFilterMatches = 8
    private static let blownFilterMatches = OSAllocatedUnfairLock(initialState: 0)

    /// Tests only: the blown-match accounting is process-global and every
    /// blown test match burns a real slot — reset it so suites stay
    /// independent.
    static func resetFilterMatcherAccounting() {
        blownFilterMatches.withLock { $0 = 0 }
    }

    /// Runs one regex match on a Dispatch global queue, racing a deadline:
    /// whichever finishes first resumes the continuation (exactly once).
    /// A blown match is accounted for PERMANENTLY (see
    /// `maxBlownFilterMatches`) — ICU offers no way to stop it.
    private static func timedMatch(_ regex: NSRegularExpression, in target: String) async throws -> Bool {
        if blownFilterMatches.withLock({ $0 >= maxBlownFilterMatches }) {
            throw Abort(
                .badRequest,
                reason: "filter matching is saturated by pathological patterns — refusing further matches until the daemon restarts"
            )
        }
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            once.install(continuation)
            let range = NSRange(location: 0, length: target.utf16.count)
            DispatchQueue.global().async {
                once.resume(.success(regex.firstMatch(in: target, range: range) != nil))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Self.matchBudgetMs)) {
                // The match is presumed still spinning (ICU cannot be
                // interrupted) — account for it permanently.
                blownFilterMatches.withLock { $0 += 1 }
                once.resume(
                    .failure(
                        Abort(
                            .badRequest,
                            reason: "filter pattern exceeded its matching budget (podman uses the linear-time RE2 engine; a pathological backtracking pattern is rejected here)"
                        )))
            }
        }
    }

    /// Resumes a continuation exactly once — whichever of the match or the
    /// deadline gets there first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Error>?

        func install(_ continuation: CheckedContinuation<Bool, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ result: Result<Bool, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    /// Podman emits `Type: "secret"` events on create/remove
    /// (`libpod.NewSecretEvent`); the actor carries the secret's name attribute.
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

    /// `entities.SecretInfoReport` — plain libpod dialect (no Docker-compat
    /// `Version` wrapper; see class docs). Field names are Go-marshaled
    /// (SecretInfoReport has no json tags), so they must stay capitalized.
    private static func report(_ secret: StoredSecret, secretData: String? = nil) -> LibpodSecretInfoReport {
        LibpodSecretInfoReport(
            ID: secret.id,
            CreatedAt: Self.iso8601.string(from: secret.createdAt),
            UpdatedAt: Self.iso8601.string(from: secret.updatedAt),
            Spec: LibpodSecretSpec(
                Name: secret.name,
                Driver: LibpodSecretDriverSpec(Name: secret.driver, Options: secret.driverOptions),
                Labels: secret.labels
            ),
            SecretData: secretData
        )
    }

    /// RFC3339 timestamps like Go's `time.Time` marshaling; podman's bindings
    /// decode either with or without fractional seconds.
    private nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()
}

// MARK: - Wire types

/// `entities.SecretCreateReport` — just the new secret's ID.
struct LibpodSecretCreateReport: Content {
    let ID: String
}

/// `entities.SecretDriverSpec`.
struct LibpodSecretDriverSpec: Content {
    let Name: String
    let Options: [String: String]
}

/// `entities.SecretSpec`.
struct LibpodSecretSpec: Content {
    let Name: String
    let Driver: LibpodSecretDriverSpec
    let Labels: [String: String]
}

/// `entities.SecretInfoReport`. `SecretData` is `omitempty` in podman — only
/// present on an inspect that passed `showsecret`, as the RAW payload string
/// (podman serves `string(data)` unencoded; base64 here would garble
/// `podman secret inspect --showsecret`).
struct LibpodSecretInfoReport: Content {
    let ID: String
    let CreatedAt: String
    let UpdatedAt: String
    let Spec: LibpodSecretSpec
    let SecretData: String?
}
