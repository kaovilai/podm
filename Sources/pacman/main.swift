// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

// Entry point for the pacman client shim.
//
// argv0 multi-call dispatch: when this binary is invoked as `podman` or `docker`
// (via the symlinks `pacman install` creates in ~/.pacman/bin), it transparently
// execs the real CLI with the pacman daemon socket configured. Invoked as
// `pacman` (or any other name), it runs pacman's own subcommands when the first
// argument is one of them; every other invocation falls through to the podman
// persona so unknown flags and subcommands (e.g. `podman -v`, `pacman ps -a`)
// reach the real CLI untouched — ArgumentParser never sees the passthrough path.

let arguments = CommandLine.arguments
let argv0 = URL(fileURLWithPath: arguments.first ?? "pacman").lastPathComponent

switch argv0 {
case "podman":
    PersonaExec.run(.podman, arguments: Array(arguments.dropFirst()))
case "docker":
    PersonaExec.run(.docker, arguments: Array(arguments.dropFirst()))
default:
    if arguments.count > 1, PacmanCommand.ownSubcommandNames.contains(arguments[1]) {
        // A pacman-own subcommand: hand the rest to ArgumentParser.
        PacmanCommand.main()
    } else {
        PersonaExec.run(.podman, arguments: Array(arguments.dropFirst()))
    }
}
