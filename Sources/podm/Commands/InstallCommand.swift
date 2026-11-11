// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the podm shims into ~/.podm/bin (and optionally a launchd on-demand daemon)."
    )

    @Option(
        name: .long,
        help: """
            Path to a launchd plist template. __HOME__ occurrences are replaced with $HOME and the result \
            is installed as ~/Library/LaunchAgents/io.github.podm.daemon.plist, then bootstrapped.
            """
    )
    var launchdTemplate: String?

    func run() throws {
        let fileManager = FileManager.default
        let selfRealPath = ShimLocator.selfRealPath

        // 1. Shims: podm -> this binary (realpath'd), podman/docker -> podm
        //    (relative links, so they keep working if ~/.podm ever moves).
        try fileManager.createDirectory(at: PodmPaths.binDir, withIntermediateDirectories: true)
        try installShimLink(name: "podm", destination: selfRealPath)
        try installShimLink(name: "podman", destination: "podm")
        try installShimLink(name: "docker", destination: "podm")
        print("Installed shims:")
        print("  \(PodmPaths.binDir.path)/podm -> \(selfRealPath)")
        print("  \(PodmPaths.binDir.path)/podman -> podm")
        print("  \(PodmPaths.binDir.path)/docker -> podm")

        // 2. Record the real CLIs for fast, PATH-order-independent lookup.
        //    Only CLIs actually found are (re)written; missing ones keep any
        //    previously recorded entry.
        var recorded: [String: String] = [:]
        for cliName in ["podman", "docker"] {
            if let cliPath = CLILocator.locate(cli: cliName, skippingRealPath: selfRealPath) {
                recorded[cliName] = cliPath
                print("Found real \(cliName) CLI: \(cliPath)")
            } else {
                print("Real \(cliName) CLI not found on PATH — kept any previously recorded entry")
            }
        }
        if !recorded.isEmpty {
            try ClientPaths.mergeAndWrite(recorded)
        }

        // 3. Zsh completion (issue #46): the user's completions dir when it
        //    exists, else podm's own with fpath instructions. A failure here
        //    is a warning, not a failed install — the shims work without it.
        do {
            let outcome = try CompletionInstaller.installZsh(
                userCompletionsDir: PodmPaths.zshCompletionsDir,
                fallbackDir: PodmPaths.completionsFallbackDir)
            switch outcome.destination {
            case .userCompletions(let dir):
                print(
                    "\(outcome.updated ? "Installed" : "Up to date") zsh completion: \(dir.path)/_podm"
                        + " (mirrored podman subcommands delegate to your _podman)")
            case .podmFallback(let dir):
                print("Installed zsh completion: \(dir.path)/_podm")
                print(
                    """
                    Add it to zsh's fpath (e.g. in ~/.zshrc, BEFORE compinit — fpath is an ARRAY):
                        fpath=("\(dir.path)" $fpath)
                    """)
            }
        } catch {
            print("warning: could not install zsh completion: \(error)")
        }

        // 4. Podman connection (issue #47): register podm as a selectable
        //    podman remote. Primacy stays the user's decision — this never
        //    changes the default connection.
        if let podmanPath = recorded["podman"] ?? ClientPaths.read()["podman"] {
            if PodmanConnectionRegistrar.register(
                podmanPath: podmanPath, uri: PodmPaths.containerHostURL)
            {
                print("Registered podman connection 'podm' -> \(PodmPaths.containerHostURL)")
            } else {
                print("warning: real podman CLI exited non-zero registering the 'podm' connection")
            }
        } else {
            print("No real podman CLI found — skipped podman connection registration")
        }

        // 5. Optional launchd on-demand daemon.
        if let templatePath = launchdTemplate {
            let templateURL = URL(fileURLWithPath: templatePath)
            guard let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
                throw ValidationError("launchd template not found or unreadable: \(templatePath)")
            }
            try installLaunchdAgent(template: template)
        } else {
            print(
                """
                Tip: launchd on-demand mode (start the daemon on first socket use) can be enabled with:
                    podm install --launchd-template <path-to-plist-template>
                """
            )
        }

        // 6. Post-install instructions (the sudo command is printed only, never run).
        print(
            """
            Add the shims to your PATH (e.g. in ~/.zshrc):
                export PATH="$HOME/.podm/bin:$PATH"
            Optional: make podm the default podman remote:
                podman system connection default podm
            Optional: switch the docker CLI to the podm context (the daemon registers it on startup):
                docker context use podm
            Optional: expose the daemon on the default Docker socket:
                sudo ln -sf ~/.podm/container.sock /var/run/docker.sock
            """
        )
    }

    /// Create a symlink at ~/.podm/bin/<name>, replacing an existing symlink.
    /// A pre-existing non-symlink file is refused rather than clobbered.
    private func installShimLink(name: String, destination: String) throws {
        let linkURL = PodmPaths.binDir.appendingPathComponent(name)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: linkURL.path) || FileSystem.isSymlink(linkURL.path) {
            guard FileSystem.isSymlink(linkURL.path) else {
                throw ValidationError("\(linkURL.path) exists and is not a symlink; refusing to replace it")
            }
            try fileManager.removeItem(at: linkURL)
        }
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: destination)
    }

    private func installLaunchdAgent(template: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: PodmPaths.launchAgentDir, withIntermediateDirectories: true)
        let plistPath = PodmPaths.launchAgentURL.path
        // Boot out any previously loaded agent first (quietly — failure just
        // means nothing was loaded yet).
        _ = ProcessSpawn.run("/bin/launchctl", ["bootout", PodmPaths.launchdServiceTarget], discardOutput: true)
        // Render every placeholder the template defines: __HOME__ and the
        // daemon binary path (__PODMD_BIN__). Leaving the latter unreplaced
        // yields a plist whose ProgramArguments is the literal placeholder —
        // bootstrap succeeds but the agent can never start the daemon.
        var rendered = template.replacingOccurrences(of: "__HOME__", with: PodmPaths.homePath)
        if let podmdPath = DaemonLocator.locate() {
            rendered = rendered.replacingOccurrences(of: "__PODMD_BIN__", with: podmdPath)
        } else if rendered.contains("__PODMD_BIN__") {
            print("warning: template contains __PODMD_BIN__ but no podmd binary was found; the agent will not start the daemon")
        }
        try rendered.write(to: PodmPaths.launchAgentURL, atomically: true, encoding: .utf8)
        let result = ProcessSpawn.run("/bin/launchctl", ["bootstrap", PodmPaths.launchdDomain, plistPath], discardOutput: true)
        if result.exitStatus == 0 {
            print("Installed launchd agent: \(plistPath)")
        } else {
            // bootstrap also fails when an equivalent service is already
            // registered — treat that as loaded, not fatal.
            print("launchctl bootstrap exited \(result.exitStatus) (agent may already be loaded): \(plistPath)")
        }
    }
}
