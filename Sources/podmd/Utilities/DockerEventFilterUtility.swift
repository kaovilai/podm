import Foundation
import Logging
import Vapor

/// Parses and applies `GET /events` filters, mirroring moby's
/// `daemon/events/filter.go` (`events.Filter.Include`).
///
/// podm emits events of Type `container`, `image`, `network`, `volume` and
/// `builder` (see the `DockerEvent.make/simpleEvent` call sites). The swarm
/// and plugin families (`node`, `service`, `secret`, `config`, `plugin`,
/// `daemon`) never occur on this single-node daemon, so their filter keys are
/// accepted — the docker CLI's valid set — but match nothing.
struct DockerEventFilterUtility {

    /// The filter keys the docker CLI accepts for `docker events --filter`.
    /// `builder` is intentionally absent: the CLI has no such key (a builder
    /// event is selected via `--filter type=builder`).
    private static let allowedKeys: Set<String> = [
        "config", "container", "daemon", "event", "image", "label",
        "network", "node", "plugin", "scope", "secret", "service",
        "type", "volume",
    ]

    /// Filter families podm never emits — accepted for CLI compatibility,
    /// never matched (single-node Apple container daemon: no swarm, no
    /// plugins, no daemon-lifecycle events).
    private static let neverMatchKeys: Set<String> = [
        "config", "daemon", "node", "plugin", "secret", "service",
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
                && matchExact(filters["event"], event.Action)
                && matchExact(filters["scope"], event.scope)
                && matchName(filters["container"], event, extraIds: idsRenamedToFilteredNames)
                && matchImage(filters["image"], event: event)
                && matchName(filters["network"], event, extraIds: [])
                && matchName(filters["volume"], event, extraIds: [])
                && matchLabels(filters["label"], event.Actor.Attributes)
                && neverMatchKeys.allSatisfy { filters[$0] == nil }
        }
    }

    // MARK: - Per-key matchers

    /// `type`, `event`, `scope`: exact match against one of the values.
    private static func matchExact(_ values: [String]?, _ field: String) -> Bool {
        guard let values, !values.isEmpty else { return true }
        return values.contains(field)
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

    /// `label` — moby's `MatchKVList`: `key=value` requires an equal
    /// attribute, a bare `key` requires the key to be present.
    private static func matchLabels(_ values: [String]?, _ attributes: [String: String]) -> Bool {
        guard let values, !values.isEmpty else { return true }
        for value in values {
            if let eq = value.firstIndex(of: "=") {
                let key = String(value[..<eq])
                let expected = String(value[value.index(after: eq)...])
                if attributes[key] == expected { return true }
            } else if attributes[value] != nil {
                return true
            }
        }
        return false
    }

    /// moby's `filters.Args.FuzzyMatch`: exact, or the field starts with the
    /// filter value (id-prefix selection).
    private static func fuzzy(_ value: String, _ field: String) -> Bool {
        field == value || field.hasPrefix(value)
    }

    /// moby's `stripTag` (reference.FamiliarName): drops the `:tag`/`:digest`
    /// suffix when it follows the last path separator, then shortens the
    /// default registry so `docker.io/library/busybox:latest` filters as
    /// `busybox`. The event side is normalized, like moby — the filter value
    /// is compared raw.
    private static func stripTag(_ image: String) -> String {
        var stripped = image
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
