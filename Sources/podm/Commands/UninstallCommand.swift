// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the podm shims and launchd agent, keeping the daemon socket and container stores."
    )

    func run() throws {
        let fileManager = FileManager.default

        // 1. LaunchAgent.
        let plistPath = PodmPaths.launchAgentURL.path
        if fileManager.fileExists(atPath: plistPath) {
            _ = ProcessSpawn.run("/bin/launchctl", ["bootout", PodmPaths.launchdServiceTarget], discardOutput: true)
            try fileManager.removeItem(at: PodmPaths.launchAgentURL)
            print("Removed launchd agent: \(plistPath)")
        } else {
            print("No launchd agent installed at \(plistPath)")
        }

        // 2. Shims. Only symlinks are removed, so a stray real binary named
        //    podman/docker in ~/.podm/bin is never clobbered.
        for name in ["podm", "podman", "docker"] {
            let linkURL = PodmPaths.binDir.appendingPathComponent(name)
            if FileSystem.isSymlink(linkURL.path) {
                try fileManager.removeItem(at: linkURL)
                print("Removed shim: \(linkURL.path)")
            }
        }

        // 3. Report what deliberately stays behind.
        print(
            """
            Kept (untouched):
              \(PodmPaths.socketPath) — daemon socket
              \(PodmPaths.podmDir.path) — podm config and container stores
            Run `podm install` again to restore the shims.
            """
        )
    }
}
