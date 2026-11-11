// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Registers podm as a `podman system connection`, so the REAL podman CLI
/// can select it (`podman --connection podm ps` or
/// `podman system connection default podm`) alongside the local machine,
/// `podman machine` remotes, and SSH remotes — secondary or primary, the
/// user's choice (issue #47). The docker-side twin already exists: the
/// daemon registers the `podm` docker context on startup.
///
/// Registration shells out to the real podman CLI (the one whose path
/// `podm install` records) rather than writing containers.conf directly —
/// podman owns that file's format and merge semantics.
///
/// podman 6.1.4's subcommands (verified against the installed CLI): `add`
/// (updates an existing name IN PLACE — no remove needed, and a remove
/// would clear the user's default selection), `default`, `list` (supports
/// `--format json`), `remove`, `rename`. There is NO `show` subcommand —
/// existence checks parse `list --format json`.
enum PodmanConnectionRegistrar {
    /// The connection name podm registers. Matches the docker context name.
    static let connectionName = "podm"

    /// The spawn seam: (executable, arguments) → (exitStatus, output).
    /// Production wraps `ProcessSpawn.run`; tests inject a recorder.
    typealias Spawn = (_ executable: String, _ arguments: [String]) -> (exitStatus: Int32, output: String?)

    /// Default seam over the real process spawn. Output capture is ON and
    /// STDOUT-ONLY: the JSON listing must be readable in production
    /// (ProcessSpawn.run defaults to discarding both streams, which would
    /// make every listing parse as nil — "unknown" status and a skipped
    /// uninstall — while the injected test fixtures, which hand back
    /// strings directly, bypassed exactly that), and stderr must NOT be
    /// merged in: podman can legitimately emit a config warning to stderr
    /// while still printing a successful JSON listing, and the merged
    /// stream then fails to parse.
    static func realSpawn(_ executable: String, _ arguments: [String]) -> (
        exitStatus: Int32, output: String?
    ) {
        ProcessSpawn.runCaptureStdout(executable, arguments)
    }

    /// One entry of `podman system connection list --format json`.
    struct ConnectionEntry: Equatable {
        let name: String
        let uri: String
        let isDefault: Bool
    }

    /// Lists the registered connections. Nil when podman itself failed to
    /// answer (CLI error) — distinct from an empty list, so callers never
    /// mistake "could not ask" for "nothing registered".
    static func listConnections(
        podmanPath: String, spawn: Spawn = realSpawn
    ) -> [ConnectionEntry]? {
        let result = spawn(podmanPath, ["system", "connection", "list", "--format", "json"])
        guard result.exitStatus == 0, let output = result.output, let data = output.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return array.compactMap { entry in
            guard let name = entry["Name"] as? String, let uri = entry["URI"] as? String else {
                return nil
            }
            return ConnectionEntry(name: name, uri: uri, isDefault: (entry["Default"] as? Bool) ?? false)
        }
    }

    /// Registers (or refreshes) the connection. Idempotent WITHOUT a
    /// remove first: podman 6's `system connection add` updates an existing
    /// name in place, and removing would clear the user's default selection
    /// (remove of the default connection leaves no default; the re-add does
    /// not restore it).
    ///
    /// The DEFAULT is actively preserved: podman's add can silently change
    /// it in two situations — a clean writable profile (its `Connections ==
    /// nil` rule makes any first-ever connection the default), and a profile
    /// whose connections come entirely from a READ-ONLY layer (containers.conf
    /// supplies them; the writable connections file is empty, so the same
    /// nil rule fires and replaces the read-only default). Both are detected
    /// by comparing the default BEFORE and AFTER: a changed default with a
    /// pre-existing selection is RESTORED via `system connection default`;
    /// when there was no default at all (the clean-profile case), podman
    /// leaves no way to unset it — the result reports
    /// `becameDefaultOnCleanProfile` so the caller can say so loudly.
    ///
    /// Returns nil when registration failed entirely.
    static func register(
        podmanPath: String, uri: String, connectionName: String = connectionName,
        spawn: Spawn = realSpawn
    ) -> RegistrationResult? {
        // The destination is POSITIONAL (podman-system-connection(1):
        // "add [options] NAME DESTINATION").
        let priorDefault = listConnections(podmanPath: podmanPath, spawn: spawn)?
            .first(where: { $0.isDefault })?.name
        guard
            spawn(podmanPath, ["system", "connection", "add", connectionName, uri]).exitStatus == 0
        else { return nil }
        let postDefault = listConnections(podmanPath: podmanPath, spawn: spawn)?
            .first(where: { $0.isDefault })?.name
        if let priorDefault, priorDefault != connectionName, postDefault != priorDefault {
            // podman's add flipped an existing default (the read-only-layer
            // case) — restore the user's selection.
            _ = spawn(podmanPath, ["system", "connection", "default", priorDefault])
        }
        return RegistrationResult(
            connectionName: connectionName,
            becameDefaultOnCleanProfile: priorDefault == nil && postDefault == connectionName)
    }

    /// The outcome of a `register` call.
    struct RegistrationResult: Equatable {
        let connectionName: String
        /// True when there was no default before and podm's registration
        /// became it (podman's own first-connection rule on a clean profile;
        /// there is no command to unset a default) — the caller should tell
        /// the user loudly.
        let becameDefaultOnCleanProfile: Bool
    }

    /// Removes the connection. Returns true only when it is verifiably gone:
    /// a successful remove, or a successful listing that no longer contains
    /// it. A CLI failure (bad exit from BOTH remove and list) returns false —
    /// "could not confirm removal" must not read as success.
    @discardableResult
    static func unregister(
        podmanPath: String, connectionName: String = connectionName, spawn: Spawn = realSpawn
    ) -> Bool {
        if spawn(podmanPath, ["system", "connection", "remove", connectionName]).exitStatus == 0 {
            return true
        }
        // The remove failed: either the name was never registered (remove
        // errors, gone anyway) or podman could not run/answer at all. Only
        // a SUCCESSFUL listing that omits the name confirms the former.
        guard let entries = listConnections(podmanPath: podmanPath, spawn: spawn) else {
            return false
        }
        return !entries.contains { $0.name == connectionName }
    }

    /// Whether the connection is currently registered, parsed from
    /// `system connection list --format json` (podman has no `show`
    /// subcommand). Nil when the listing itself failed — the caller cannot
    /// know, and must not report a confident yes or no.
    static func isRegistered(
        podmanPath: String, connectionName: String = connectionName, spawn: Spawn = realSpawn
    ) -> Bool? {
        guard let entries = listConnections(podmanPath: podmanPath, spawn: spawn) else { return nil }
        return entries.contains { $0.name == connectionName }
    }
}
