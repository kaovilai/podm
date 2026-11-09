// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the pacman daemon (pacmand), forwarding all arguments to it."
    )

    @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded to pacmand.")
    var daemonArguments: [String]

    func run() throws {
        guard let daemonPath = DaemonLocator.locate() else {
            throw ValidationError("pacmand not found — build it with `make` in the pacman repository (sibling binary or on PATH)")
        }
        ProcessSpawn.execAndWait(
            executable: daemonPath,
            arguments: [daemonPath] + daemonArguments,
            environment: ProcessInfo.processInfo.environment
        )
    }
}
