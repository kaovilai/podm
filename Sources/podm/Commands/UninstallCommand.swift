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

        // 3. Zsh completion, from either install location.
        let removedCompletions = CompletionInstaller.uninstallZsh(
            userCompletionsDir: PodmPaths.zshCompletionsDir,
            fallbackDir: PodmPaths.completionsFallbackDir)
        for path in removedCompletions {
            print("Removed zsh completion: \(path.path)")
        }

        // 4. Podman connection (issue #47). Uses the recorded real CLI;
        //    without it there is nothing registered to remove. The result is
        //    checked — a failed removal must not print success while the
        //    connection stays behind.
        if let podmanPath = ClientPaths.read()["podman"],
            PodmanConnectionRegistrar.isRegistered(podmanPath: podmanPath) == true
        {
            if PodmanConnectionRegistrar.unregister(podmanPath: podmanPath) {
                print("Removed podman connection '\(PodmanConnectionRegistrar.connectionName)'")
            } else {
                print(
                    "warning: could not remove the '\(PodmanConnectionRegistrar.connectionName)' podman connection (podman CLI failed; remove it with: podman system connection remove \(PodmanConnectionRegistrar.connectionName))"
                )
            }
        }

        // 5. Report what deliberately stays behind.
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
