// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the pacman shims and launchd agent, keeping the daemon socket and container stores."
    )

    func run() throws {
        let fileManager = FileManager.default

        // 1. LaunchAgent.
        let plistPath = PacmanPaths.launchAgentURL.path
        if fileManager.fileExists(atPath: plistPath) {
            _ = ProcessSpawn.run("/bin/launchctl", ["bootout", PacmanPaths.launchdTarget, plistPath], discardOutput: true)
            try fileManager.removeItem(at: PacmanPaths.launchAgentURL)
            print("Removed launchd agent: \(plistPath)")
        } else {
            print("No launchd agent installed at \(plistPath)")
        }

        // 2. Shims. Only symlinks are removed, so a stray real binary named
        //    podman/docker in ~/.pacman/bin is never clobbered.
        for name in ["pacman", "podman", "docker"] {
            let linkURL = PacmanPaths.binDir.appendingPathComponent(name)
            if FileSystem.isSymlink(linkURL.path) {
                try fileManager.removeItem(at: linkURL)
                print("Removed shim: \(linkURL.path)")
            }
        }

        // 3. Report what deliberately stays behind.
        print(
            """
            Kept (untouched):
              \(PacmanPaths.socketPath) — daemon socket
              \(PacmanPaths.pacmanDir.path) — pacman config and container stores
            Run `pacman install` again to restore the shims.
            """
        )
    }
}
