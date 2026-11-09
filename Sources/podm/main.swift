// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

// Entry point for the podm client shim.
//
// argv0 multi-call dispatch: when this binary is invoked as `podman` or `docker`
// (via the symlinks `podm install` creates in ~/.podm/bin), it transparently
// execs the real CLI with the podm daemon socket configured. Invoked as
// `podm` (or any other name), it runs podm's own subcommands when the first
// argument is one of them; every other invocation falls through to the podman
// persona so unknown flags and subcommands (e.g. `podman -v`, `podm ps -a`)
// reach the real CLI untouched — ArgumentParser never sees the passthrough path.

let arguments = CommandLine.arguments
let argv0 = URL(fileURLWithPath: arguments.first ?? "podm").lastPathComponent

switch argv0 {
case "podman":
    PersonaExec.run(.podman, arguments: Array(arguments.dropFirst()))
case "docker":
    PersonaExec.run(.docker, arguments: Array(arguments.dropFirst()))
default:
    if arguments.count > 1, PodmCommand.ownSubcommandNames.contains(arguments[1]) {
        // A podm-own subcommand: hand the rest to ArgumentParser.
        PodmCommand.main()
    } else {
        PersonaExec.run(.podman, arguments: Array(arguments.dropFirst()))
    }
}
