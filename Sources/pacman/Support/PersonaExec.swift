// SPDX-License-Identifier: Apache-2.0

import Foundation

// Which real CLI this shim should front.

enum Persona: String {
    case podman
    case docker

    /// Environment variable the real CLI reads for its container host endpoint.
    var hostEnvironmentKey: String {
        switch self {
        case .podman: "CONTAINER_HOST"
        case .docker: "DOCKER_HOST"
        }
    }
}

enum PersonaExec {
    /// Exec the real CLI for `persona` with the pacman daemon socket configured,
    /// forwarding `arguments` untouched. Never returns.
    ///
    /// Only the persona's own endpoint variable is set (CONTAINER_HOST for podman,
    /// DOCKER_HOST for docker); docker contexts and podman remote connections are
    /// deliberately left alone.
    static func run(_ persona: Persona, arguments: [String]) -> Never {
        guard let cliPath = CLILocator.locate(cli: persona.rawValue, skippingRealPath: ShimLocator.selfRealPath) else {
            Stderr.write(
                "pacman: real \(persona.rawValue) CLI not found — brew install \(persona.rawValue) (then pacman install to record it)\n"
            )
            exit(127)
        }

        wakeDaemonIfIdle()

        var environment = ProcessInfo.processInfo.environment
        environment[persona.hostEnvironmentKey] = PacmanPaths.containerHostURL

        // docker CLI precedence: an inherited DOCKER_CONTEXT environment
        // variable beats DOCKER_HOST, so a user exporting a Docker Desktop or
        // remote context would have the shim run commands against that other
        // engine while waking pacman's daemon. Unset it for the docker persona
        // (an explicit `--context` flag on the command line still wins; the
        // user's configured default context does not beat DOCKER_HOST).
        if persona == .docker {
            environment.removeValue(forKey: "DOCKER_CONTEXT")
        }

        ProcessSpawn.execAndWait(executable: cliPath, arguments: [cliPath] + arguments, environment: environment)
    }

    /// The daemon idle-exits after `PACMAN_IDLE_EXIT_SECS` with no connections and
    /// no running containers. If the LaunchAgent is installed and the socket is
    /// gone, kickstart the agent and wait (bounded) for the socket to come back so
    /// the very next `podman ps` after an idle exit just works. Best effort and
    /// silent on every failure path: without the agent (or without launchd, e.g. a
    /// bare `pacman serve` dev setup) the real CLI surfaces its own connect error.
    private static func wakeDaemonIfIdle() {
        let socketPath = PacmanPaths.socketPath
        if daemonReachable(socketPath: socketPath) { return }
        let plistPath = PacmanPaths.launchAgentURL.path
        guard FileManager.default.fileExists(atPath: plistPath) else { return }

        _ = ProcessSpawn.run(
            "/bin/launchctl", ["kickstart", PacmanPaths.launchdServiceTarget], discardOutput: true)

        // Bounded wait for the daemon to answer after launchd spawns it. A
        // cold start runs startup housekeeping (container-apiserver bring-up,
        // healthcheck resume) before the socket answers — up to ~30s on a slow
        // machine — so the overall deadline is 60s, matching the integration
        // CI's readiness budget. Bail early the moment it answers.
        for _ in 0..<600 {
            if daemonReachable(socketPath: socketPath) { return }
            usleep(100_000)  // 100ms → up to 60s total
        }
    }

    /// A socket file outlives a killed daemon, so probe liveness with a real
    /// `/_ping` over the unix socket instead of checking file existence.
    private static func daemonReachable(socketPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let result = ProcessSpawn.run(
            "/usr/bin/curl",
            ["--max-time", "1", "-sf", "--unix-socket", socketPath, "http://localhost/_ping"],
            discardOutput: true)
        return result.exitStatus == 0
    }
}
