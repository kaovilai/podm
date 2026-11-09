// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report the podm daemon socket, daemon liveness, and Apple Container status."
    )

    func run() throws {
        var healthy = true

        let socketPath = PodmPaths.socketPath
        let socketPresent = FileSystem.isSocket(socketPath)
        print("socket: \(socketPresent ? "present at \(socketPath)" : "MISSING at \(socketPath)")")

        // Daemon ping via curl's unix-socket support (-sf: silent, fail on HTTP errors).
        let ping = ProcessSpawn.run(
            "/usr/bin/curl",
            ["--max-time", "2", "-sf", "--unix-socket", socketPath, "http://localhost/_ping"]
        )
        if ping.exitStatus == 0 {
            print("daemon: reachable (/_ping OK)")
        } else {
            healthy = false
            print("daemon: unreachable (/_ping failed\(socketPresent ? "" : " — no socket"))")
        }

        if let containerCLI = CLILocator.locate(cli: "container") {
            let result = ProcessSpawn.run(containerCLI, ["system", "status"], captureOutput: true)
            if let firstLine = result.output?.split(separator: "\n").first, !firstLine.isEmpty {
                print("apple containers: \(firstLine)")
            } else {
                print("apple containers: `container system status` returned no output (exit \(result.exitStatus))")
            }
        } else {
            print("apple containers: `container` CLI not found")
        }

        if !healthy {
            throw ExitCode(1)
        }
    }
}
