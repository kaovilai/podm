// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

// Canonical filesystem locations for the pacman client.

enum PacmanPaths {
    /// $HOME without a trailing slash (NSHomeDirectory can return one in sandboxed contexts).
    static var homePath: String {
        let raw = NSHomeDirectory()
        return raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    static var pacmanDir: URL {
        URL(fileURLWithPath: homePath, isDirectory: true).appendingPathComponent(".pacman", isDirectory: true)
    }

    static var binDir: URL {
        pacmanDir.appendingPathComponent("bin", isDirectory: true)
    }

    static var socketURL: URL {
        pacmanDir.appendingPathComponent("container.sock")
    }

    static var clientPathsURL: URL {
        pacmanDir.appendingPathComponent("client-paths.json")
    }

    static var launchAgentDir: URL {
        URL(fileURLWithPath: homePath, isDirectory: true).appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var launchAgentURL: URL {
        launchAgentDir.appendingPathComponent(Self.launchdLabel + ".plist")
    }

    /// launchd label of the daemon agent.
    static let launchdLabel = "io.github.pacman.daemon"

    static var socketPath: String {
        socketURL.path
    }

    /// Endpoint URL handed to the real CLIs via CONTAINER_HOST / DOCKER_HOST.
    static var containerHostURL: String {
        "unix://" + socketPath
    }

    /// launchd domain for the current GUI login session, e.g. "gui/501" — what
    /// `launchctl bootstrap <domain> <plist>` wants.
    static var launchdDomain: String {
        "gui/\(getuid())"
    }

    /// Fully-qualified launchd service target, e.g.
    /// "gui/501/io.github.pacman.daemon" — what `launchctl kickstart <target>`
    /// and `launchctl bootout <target>` want (the bare domain is invalid there).
    static var launchdServiceTarget: String {
        launchdDomain + "/" + launchdLabel
    }
}
