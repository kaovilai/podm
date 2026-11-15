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
    /// Exec the real CLI for `persona` with the podm daemon socket configured,
    /// forwarding `arguments` untouched. Never returns.
    ///
    /// Only the persona's own endpoint variable is set (CONTAINER_HOST for podman,
    /// DOCKER_HOST for docker); docker contexts and podman remote connections are
    /// deliberately left alone.
    static func run(_ persona: Persona, arguments: [String]) -> Never {
        guard let cliPath = CLILocator.locate(cli: persona.rawValue, skippingRealPath: ShimLocator.selfRealPath) else {
            Stderr.write(
                "podm: real \(persona.rawValue) CLI not found — brew install \(persona.rawValue) (then podm install to record it)\n"
            )
            exit(127)
        }

        wakeDaemonIfIdle()

        var environment = ProcessInfo.processInfo.environment
        environment[persona.hostEnvironmentKey] = PodmPaths.containerHostURL

        // docker CLI precedence: an inherited DOCKER_CONTEXT environment
        // variable beats DOCKER_HOST, so a user exporting a Docker Desktop or
        // remote context would have the shim run commands against that other
        // engine while waking podm's daemon. Unset it for the docker persona
        // (an explicit `--context` flag on the command line still wins; the
        // user's configured default context does not beat DOCKER_HOST).
        if persona == .docker {
            environment.removeValue(forKey: "DOCKER_CONTEXT")
        }

        ProcessSpawn.execAndWait(executable: cliPath, arguments: [cliPath] + arguments, environment: environment)
    }

    /// The daemon idle-exits after `PODM_IDLE_EXIT_SECS` with no connections and
    /// no running containers. If the LaunchAgent is installed and the socket is
    /// gone, kickstart the agent and wait (bounded) for the socket to come back so
    /// the very next `podman ps` after an idle exit just works.
    ///
    /// The wait is no longer silent: a wake that takes longer than
    /// `WakeProgress.announceAfter` prints one line, so a cold start reads as
    /// "waking" instead of a hung CLI. A failed kickstart (plist present but the
    /// job not loaded — e.g. after `podm uninstall` kept the file, or a hand
    /// written plist) says how to reload the agent and hands over immediately
    /// instead of burning the deadline on a daemon launchd was never going to
    /// start. The hand-over stays a hand-over: `docker --help`, `podman
    /// --version` and `docker --context <remote> …` need no local daemon, so the
    /// shim never decides for them. Without a plist at all (a bare `podm serve`
    /// dev setup) the shim stays silent, exactly as before.
    private static func wakeDaemonIfIdle() {
        let socketPath = PodmPaths.socketPath
        if daemonReachable(socketPath: socketPath) { return }
        let plistPath = PodmPaths.launchAgentURL.path
        guard FileManager.default.fileExists(atPath: plistPath) else { return }

        let kickstart = ProcessSpawn.run(
            "/bin/launchctl", ["kickstart", PodmPaths.launchdServiceTarget], captureOutput: true)
        guard kickstart.exitStatus == 0 else {
            Stderr.write(
                WakeProgress.kickstartFailureNotice(
                    exitStatus: kickstart.exitStatus,
                    launchdDomain: PodmPaths.launchdDomain,
                    plistPath: plistPath))
            return
        }

        // Bounded wait for the daemon to answer after launchd spawns it; the
        // deadline and progress cadence live in `WakeProgress`. Monotonic time:
        // wall-clock adjustments must not stretch or cut the wait.
        let started = DispatchTime.now().uptimeNanoseconds
        var announced = false
        while true {
            if daemonReachable(socketPath: socketPath) { return }
            let elapsed =
                Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            switch WakeProgress.decision(elapsed: elapsed, announced: announced) {
            case .giveUp:
                Stderr.write(WakeProgress.timeoutNotice())
                return
            case .announce:
                announced = true
                Stderr.write(WakeProgress.wakeNotice())
            case .wait:
                break
            }
            usleep(100_000)  // 100ms poll
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
