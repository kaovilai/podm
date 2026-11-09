// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the podm daemon (podmd), forwarding all arguments to it."
    )

    @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded to podmd.")
    var daemonArguments: [String]

    func run() throws {
        guard let daemonPath = DaemonLocator.locate() else {
            throw ValidationError("podmd not found — build it with `make` in the podm repository (sibling binary or on PATH)")
        }
        ProcessSpawn.execAndWait(
            executable: daemonPath,
            arguments: [daemonPath] + daemonArguments,
            environment: ProcessInfo.processInfo.environment
        )
    }
}
