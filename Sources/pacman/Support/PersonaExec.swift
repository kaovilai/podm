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

        var environment = ProcessInfo.processInfo.environment
        environment[persona.hostEnvironmentKey] = PacmanPaths.containerHostURL

        ProcessSpawn.execAndWait(executable: cliPath, arguments: [cliPath] + arguments, environment: environment)
    }
}
