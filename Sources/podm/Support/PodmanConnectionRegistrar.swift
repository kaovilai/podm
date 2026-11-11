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
enum PodmanConnectionRegistrar {
    /// The connection name podm registers. Matches the docker context name.
    static let connectionName = "podm"

    /// The spawn seam: (executable, arguments) → (exitStatus, output).
    /// Production wraps `ProcessSpawn.run`; tests inject a recorder.
    typealias Spawn = (_ executable: String, _ arguments: [String]) -> (exitStatus: Int32, output: String?)

    /// Default seam over the real process spawn.
    private static func realSpawn(_ executable: String, _ arguments: [String]) -> (
        exitStatus: Int32, output: String?
    ) {
        ProcessSpawn.run(executable, arguments)
    }

    /// Registers (or refreshes) the connection. Idempotent: an existing
    /// `podm` connection is removed first — `system connection add` refuses
    /// duplicate names, and a stale URI must be replaced, not reported as
    /// an error. Does NOT change the default connection: primacy stays the
    /// user's decision (`podman system connection default podm`).
    ///
    /// Returns true when the connection is registered after the call.
    @discardableResult
    static func register(
        podmanPath: String, uri: String, connectionName: String = connectionName,
        spawn: Spawn = realSpawn
    ) -> Bool {
        // remove-then-add: a failure to remove (nothing registered yet) is
        // expected and ignored.
        _ = spawn(podmanPath, ["system", "connection", "remove", connectionName])
        // podman's syntax takes the destination POSITIONALLY
        // (podman-system-connection(1): "add [options] NAME DESTINATION").
        let add = spawn(podmanPath, ["system", "connection", "add", connectionName, uri])
        return add.exitStatus == 0
    }

    /// Removes the connection (idempotent — removing an unregistered name
    /// is not an error). Returns true when it is gone after the call.
    @discardableResult
    static func unregister(
        podmanPath: String, connectionName: String = connectionName, spawn: Spawn = realSpawn
    ) -> Bool {
        let remove = spawn(podmanPath, ["system", "connection", "remove", connectionName])
        return remove.exitStatus == 0
            || !isRegistered(
                podmanPath: podmanPath, connectionName: connectionName, spawn: spawn)
    }

    /// Whether the connection is currently registered, via
    /// `podman system connection show <name>` (exit 0 = exists).
    static func isRegistered(
        podmanPath: String, connectionName: String = connectionName, spawn: Spawn = realSpawn
    ) -> Bool {
        spawn(podmanPath, ["system", "connection", "show", connectionName]).exitStatus == 0
    }
}
