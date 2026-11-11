// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The zsh completion for `podm`, shipped in-repo and written by
/// `podm install`. Podm-specific subcommands are described here; the
/// mirrored podman surface is delegated to the user's installed `_podman`
/// (the shim execs the REAL podman binary, so podman's own completion is
/// the correct source for everything else — reuse, not reimplementation).
enum CompletionScript {
    static let zsh = """
        #compdef podm
        # podm — podman/docker shim over Apple containerization (kaovilai/podm).
        #
        # Podm-specific subcommands (install/uninstall/status/doctor/serve) are
        # completed here. Everything else mirrors podman's CLI — the shim execs the
        # REAL podman binary with CONTAINER_HOST pointed at podm's socket — so the
        # rest of the surface is delegated to the podman completion (_podman).

        local -a podm_cmds
        podm_cmds=(
          'doctor:Check podm requirements and print a PASS/FAIL line'
          'install:Install the podm shims into ~/.podm/bin (and optionally a launchd on-demand daemon)'
          'serve:Run the podm daemon (podmd), forwarding all arguments'
          'status:Report the podm daemon socket, daemon liveness, and client paths'
          'uninstall:Remove the podm shims and launchd agent, keeping the socket and container stores'
        )

        # Podm-specific commands take priority; anything else belongs to podman.
        if (( CURRENT == 2 )); then
          _describe -t podm-commands 'podm command' podm_cmds
          if (( $+functions[_podman] )); then
            # Delegate the mirrored podman surface (subcommand names + descriptions)
            # to the real podman's completion: rewrite the command word so _podman
            # sees "podman" in position 1.
            words[1]=podman
            _podman
            return
          fi
          _message 'podman subcommand (install _podman completion for full coverage)'
          return
        fi

        case $words[2] in
          (install)
            _arguments \\
              '--launchd-template[launchd plist template path; __HOME__ occurrences are replaced with $HOME]:template file:_files' \\
              && return
            ;;
          (uninstall|status|doctor)
            _message 'no further arguments'
            return
            ;;
          (serve)
            # Forwards everything to podmd — fall through to default file/arg
            # completion below.
            ;;
          (*)
            # A podman-mirrored subcommand (or podm-specific handled above):
            # delegate the whole line to podman's completion.
            if (( $+functions[_podman] )); then
              words[1]=podman
              _podman
              return
            fi
            ;;
        esac

        _default
        """
}

/// Writes/removes the zsh completion. Directories are injected so the
/// install logic is testable against temp dirs; `InstallCommand` resolves
/// the defaults from `PodmPaths`.
enum CompletionInstaller {
    enum InstallError: Error, CustomStringConvertible {
        case refusingToReplaceSymlink(String)

        var description: String {
            switch self {
            case .refusingToReplaceSymlink(let path):
                return "\(path) exists and is a symlink; refusing to replace it"
            }
        }
    }

    /// Where `_podm` lands: the user's custom completions directory when it
    /// exists (the common zsh convention, usually already on fpath), else
    /// podm's own directory with fpath instructions printed by the caller.
    enum Destination: Equatable {
        case userCompletions(URL)
        case podmFallback(URL)
    }

    struct Outcome: Equatable {
        let destination: Destination
        /// False when the installed file already had exactly this content.
        let updated: Bool
    }

    static func preferredDestination(
        userCompletionsDir: URL, fallbackDir: URL, fileManager: FileManager = .default
    ) -> Destination {
        // The user dir is only honored when it exists — creating
        // ~/.zsh/completions for a zsh setup that deliberately uses another
        // location would be presumptuous.
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: userCompletionsDir.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return .userCompletions(userCompletionsDir)
        }
        return .podmFallback(fallbackDir)
    }

    @discardableResult
    static func installZsh(
        userCompletionsDir: URL, fallbackDir: URL, fileManager: FileManager = .default
    ) throws -> Outcome {
        let destination = preferredDestination(
            userCompletionsDir: userCompletionsDir, fallbackDir: fallbackDir, fileManager: fileManager)
        let targetURL: URL
        switch destination {
        case .userCompletions(let dir): targetURL = dir.appendingPathComponent("_podm")
        case .podmFallback(let dir): targetURL = dir.appendingPathComponent("_podm")
        }
        // An existing file that is not ours to manage: refuse rather than
        // clobber (same rule as the shim links).
        if fileManager.fileExists(atPath: targetURL.path) && FileSystem.isSymlink(targetURL.path) {
            throw InstallError.refusingToReplaceSymlink(targetURL.path)
        }
        let existing = try? String(contentsOf: targetURL, encoding: .utf8)
        let script = CompletionScript.zsh
        if existing == script {
            return Outcome(destination: destination, updated: false)
        }
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: targetURL, atomically: true, encoding: .utf8)
        return Outcome(destination: destination, updated: true)
    }

    /// Removes `_podm` from both possible locations. Returns the paths that
    /// were actually removed (empty when nothing was installed).
    static func uninstallZsh(
        userCompletionsDir: URL, fallbackDir: URL, fileManager: FileManager = .default
    ) -> [URL] {
        var removed: [URL] = []
        for dir in [userCompletionsDir, fallbackDir] {
            let targetURL = dir.appendingPathComponent("_podm")
            if fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.removeItem(at: targetURL)
                removed.append(targetURL)
            }
        }
        return removed
    }
}
