import Foundation
import Logging
import Vapor

/// Parses and applies `GET /events` filters, mirroring moby's
/// `daemon/events/filter.go` (`events.Filter.Include`).
///
/// podm emits events of Type `container`, `image`, `network`, `volume`,
/// `builder` and `secret` (see the `DockerEvent.make/simpleEvent` call
/// sites). The remaining families (`node`, `service`, `config`, `plugin`,
/// `daemon`) use the same name matcher as moby applies to them — since podm
/// never emits those types, their filters match nothing, exactly as on a
/// daemon that has not produced such events.
struct DockerEventFilterUtility {

    /// The filter keys the docker CLI accepts for `docker events --filter`.
    /// `builder` is intentionally absent: the CLI has no such key (a builder
    /// event is selected via `--filter type=builder`).
    private static let allowedKeys: Set<String> = [
        "config", "container", "daemon", "event", "image", "label",
        "network", "node", "plugin", "scope", "secret", "service",
        "type", "volume",
    ]

    /// Parses the `filters` query parameter (JSON object, values as
    /// `{"value": true}` maps, arrays, or bare strings). Throws 400 on an
    /// unknown filter key, like the other Docker*FilterUtility parsers.
    static func parse(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        var parsedFilters: [String: [String]] = [:]
        guard
            let filtersParam,
            let data = filtersParam.data(using: .utf8),
            let filters = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            if filtersParam != nil { logger.warning("Failed to decode events filters") }
            return parsedFilters
        }

        let filterKeys = Set(filters.keys)
        if !filterKeys.isSubset(of: allowedKeys) {
            let unknown = filterKeys.subtracting(allowedKeys).sorted()
            logger.warning("Invalid filter key(s) found: \(unknown)")
            throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(unknown)")
        }

        for (key, value) in filters {
            if let dict = value as? [String: Any] {
                let keys = dict.compactMap { (k, v) in (v as? Bool == true) ? k : nil }
                if !keys.isEmpty { parsedFilters[key] = keys }
            } else if let arr = value as? [String] {
                parsedFilters[key] = arr
            } else if let str = value as? String {
                parsedFilters[key] = [str]
            }
        }
        logger.debug("Decoded events filters: \(parsedFilters)")
        return parsedFilters
    }

    /// Builds the include-predicate (moby's `Filter.Include`): every present
    /// key must match (AND); within a key, any value may match (OR). Returns
    /// nil when there is nothing to filter so callers keep the unfiltered
    /// fast path.
    ///
    /// `nameOverrides` maps Docker hex id → effective (renamed) container
    /// name, so a `container=<name>` filter keeps matching events recorded
    /// before the rename under the old name — the events themselves are
    /// immutable, the override resolves the *current* name back to its id.
    static func makeMatcher(
        _ filters: [String: [String]],
        nameOverrides: [String: String] = [:]
    ) -> (@Sendable (DockerEvent) -> Bool)? {
        guard !filters.isEmpty else { return nil }

        // ids that currently resolve to one of the filtered names
        let idsRenamedToFilteredNames: Set<String> = {
            guard let wanted = filters["container"], !wanted.isEmpty else { return [] }
            let wantedSet = Set(wanted)
            return Set(nameOverrides.filter { wantedSet.contains($0.value) }.keys)
        }()

        return { event in
            matchExact(filters["type"], event.Type)
                && matchEvent(filters["event"], event.Action)
                && matchExact(filters["scope"], event.scope)
                && matchName(filters["container"], event, extraIds: idsRenamedToFilteredNames)
                && matchImage(filters["image"], event: event)
                && matchName(filters["network"], event, extraIds: [])
                && matchName(filters["volume"], event, extraIds: [])
                // moby applies the same fuzzyMatchName to every remaining
                // family (secret, config, daemon, node, plugin, service);
                // podm only ever emits `secret` among them, but the matcher
                // is uniform — an unemitted family matches nothing because
                // there are no events, not because the filter is refused.
                && matchName(filters["secret"], event, extraIds: [])
                && matchName(filters["config"], event, extraIds: [])
                && matchName(filters["daemon"], event, extraIds: [])
                && matchName(filters["node"], event, extraIds: [])
                && matchName(filters["plugin"], event, extraIds: [])
                && matchName(filters["service"], event, extraIds: [])
                && matchLabels(filters["label"], event.Actor.Attributes)
        }
    }

    // MARK: - Per-key matchers

    /// `type`, `scope`: exact match against one of the values.
    private static func matchExact(_ values: [String]?, _ field: String) -> Bool {
        guard let values, !values.isEmpty else { return true }
        return values.contains(field)
    }

    /// `event` — moby's `matchEvent` (#25798): exact, EXCEPT when the filter
    /// contains any of `health_status`, `exec_create`, `exec_start` without
    /// a colon — those actions carry a `: detail` suffix in the event
    // (`health_status: healthy`, `exec_create: bash`), so the whole key
    /// switches to fuzzy (prefix) matching.
    private static func matchEvent(_ values: [String]?, _ action: String) -> Bool {
        guard let values, !values.isEmpty else { return true }
        let fuzzyActions: Set<String> = ["health_status", "exec_create", "exec_start"]
        let fuzzy = values.contains { fuzzyActions.contains($0) }
        return values.contains { value in
            fuzzy ? action.hasPrefix(value) : action == value
        }
    }

    /// `container`/`network`/`volume` — moby's `fuzzyMatchName`: the filter
    /// value matches `Actor.ID` or `Actor.Attributes["name"]` exactly or as a
    /// prefix (id-prefix matching, like `docker events --filter container=abc123`).
    private static func matchName(_ values: [String]?, _ event: DockerEvent, extraIds: Set<String>) -> Bool {
        guard let values, !values.isEmpty else { return true }
        let name = event.Actor.Attributes["name"] ?? ""
        return values.contains { value in
            fuzzy(value, event.Actor.ID) || fuzzy(value, name)
                // renamed container: the filter names the current name, the
                // event records the pre-rename id
                || extraIds.contains(event.Actor.ID)
        }
    }

    /// `image` — moby's `matchImage`: matches `Actor.ID` and the image
    /// attribute (`Attributes["image"]`, or `Attributes["name"]` for
    /// image-typed events), each also compared with the tag stripped.
    private static func matchImage(_ values: [String]?, event: DockerEvent) -> Bool {
        guard let values, !values.isEmpty else { return true }
        let nameAttr = event.Type == "image" ? "name" : "image"
        let imageName = event.Actor.Attributes[nameAttr] ?? ""
        return values.contains { value in
            value == event.Actor.ID || value == imageName
                || value == stripTag(event.Actor.ID) || value == stripTag(imageName)
        }
    }

    /// `label` — moby's `MatchKVList`: EVERY requested label must match —
    /// `key=value` requires an equal attribute, a bare `key` requires the
    /// key to be present. (An any-match here would let
    /// `--filter label=env=prod --filter label=team=api` select events
    /// carrying only `env=prod`.)
    private static func matchLabels(_ values: [String]?, _ attributes: [String: String]) -> Bool {
        guard let values, !values.isEmpty else { return true }
        for value in values {
            if let eq = value.firstIndex(of: "=") {
                let key = String(value[..<eq])
                let expected = String(value[value.index(after: eq)...])
                if attributes[key] != expected { return false }
            } else if attributes[value] == nil {
                return false
            }
        }
        return true
    }

    /// moby's `filters.Args.FuzzyMatch`: exact, or the field starts with the
    /// filter value (id-prefix selection).
    private static func fuzzy(_ value: String, _ field: String) -> Bool {
        field == value || field.hasPrefix(value)
    }

    /// moby's `stripTag` (reference.FamiliarName): drops the `@digest`
    /// suffix FIRST (moby parses the reference, and a digest reference's
    /// familiar name is digest-less), then the `:tag` suffix when it follows
    /// the last path separator, then shortens the default registry so
    /// `docker.io/library/busybox@sha256:…` filters as `busybox`. The event
    /// side is normalized, like moby — the filter value is compared raw.
    private static func stripTag(_ image: String) -> String {
        var stripped = image
        if let at = stripped.firstIndex(of: "@") {
            stripped = String(stripped[..<at])
        }
        if let colon = stripped.lastIndex(of: ":") {
            let lastSlash = stripped.lastIndex(of: "/") ?? stripped.startIndex
            if colon > lastSlash {
                stripped = String(stripped[..<colon])
            }
        }
        if stripped.hasPrefix("docker.io/library/") {
            stripped.removeFirst("docker.io/library/".count)
        } else if stripped.hasPrefix("docker.io/") {
            stripped.removeFirst("docker.io/".count)
        }
        return stripped
    }
}
