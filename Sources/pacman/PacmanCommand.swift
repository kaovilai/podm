// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

// Root command for pacman's own subcommands. Only reachable when argv0 is not
// podman/docker and the first argument is listed in `ownSubcommandNames`; see
// main.swift for the dispatch that guards this.

struct PacmanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pacman",
        abstract: "Client shim that lets the stock podman and docker CLIs manage pacman containers on macOS.",
        discussion: """
            When symlinked as `podman` or `docker` (see `pacman install`), this shim execs the real CLI \
            with CONTAINER_HOST / DOCKER_HOST pointed at the pacman daemon's unix socket \
            (~/.pacman/container.sock), so containers run natively via Apple containerization — \
            no podman machine, no remote connection setup.
            """,
        subcommands: [
            InstallCommand.self,
            UninstallCommand.self,
            StatusCommand.self,
            DoctorCommand.self,
            ServeCommand.self,
            VersionCommand.self,
        ]
    )

    /// Subcommands owned by pacman itself. Anything else passed as the first
    /// argument (including flags like -v / --version) is forwarded to the real
    /// podman CLI by main.swift before ArgumentParser runs.
    static let ownSubcommandNames: Set<String> = ["install", "uninstall", "status", "doctor", "version", "help", "serve"]
}
