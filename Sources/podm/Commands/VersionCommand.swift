// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the podm client version and, when available, the daemon version."
    )

    func run() throws {
        // The client does not link BuildInfo (that target belongs to podmd),
        // so the daemon owns version reporting.
        print("podm client (see podmd --version for daemon version)")
        if let daemonPath = DaemonLocator.locate() {
            let result = ProcessSpawn.run(daemonPath, ["--version"], captureOutput: true)
            if result.exitStatus == 0,
                let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
                !output.isEmpty
            {
                print(output)
            }
        } else {
            print("podmd not found — build it with `make` in the podm repository")
        }
    }
}
