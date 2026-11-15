// SPDX-License-Identifier: Apache-2.0

import Foundation

/// User-visible progress for waking an idle-exited daemon.
///
/// The shim used to spend a long wait in silence: a cold start looked like a
/// hung `docker ps` / `podman ps`, and an installed-but-unloaded LaunchAgent
/// burned the full deadline before the real CLI printed its own connect error.
/// These helpers hold the decisions and messages, kept free of launchd and
/// clocks so they can be unit tested.
enum WakeProgress {
    /// A wake that completes sooner than this stays silent — most wakes are
    /// sub-second (the daemon is already warm), and a progress line on every
    /// command would be noise. Past it, the wait is real and worth a line.
    static let announceAfter: TimeInterval = 0.4

    /// Overall readiness deadline. A cold start runs startup housekeeping
    /// (container-apiserver bring-up, healthcheck resume) before the socket
    /// answers — up to ~30s on a slow machine — so 30s covers a healthy cold
    /// start. Waiting past it rarely helps: the real CLI keeps retrying on its
    /// own (~50s measured), and a daemon that is truly wedged is a
    /// `podm doctor` problem, not something a longer shim poll can fix.
    static let deadline: TimeInterval = 30

    enum Decision: Equatable {
        /// Keep polling quietly.
        case wait
        /// Keep polling, announcing the wake on stderr first.
        case announce
        /// Stop waiting; let the real CLI attempt the connection and report.
        case giveUp
    }

    /// `elapsed` is the time since launchd was asked to start the daemon.
    static func decision(elapsed: TimeInterval, announced: Bool) -> Decision {
        if elapsed >= deadline { return .giveUp }
        if !announced, elapsed >= announceAfter { return .announce }
        return .wait
    }

    /// Printed once, when the wake is taking long enough to notice.
    static func wakeNotice() -> String {
        "podm: waking podmd (it exits when idle)…\n"
    }

    /// Printed when the daemon never answered within `deadline`.
    static func timeoutNotice() -> String {
        "podm: podmd is still starting after \(Int(deadline))s — continuing to the CLI (run `podm doctor` if it never answers)\n"
    }

    /// Printed when launchd refuses to start the agent (typically: the plist
    /// exists but the job was never loaded, or was booted out with
    /// `launchctl bootout`). Names the exact reload command — plain
    /// `podm install` does not reload an agent (it only installs one when
    /// `--launchd-template` is passed).
    static func kickstartFailureNotice(
        exitStatus: Int32, launchdDomain: String, plistPath: String
    ) -> String {
        """
        podm: podmd is not running and launchd could not start it (launchctl kickstart exited \(exitStatus))
        podm: reload the agent: launchctl bootstrap \(launchdDomain) \(shellQuoted(plistPath))
        podm: or run `podm serve` for a foreground daemon — `podm doctor` explains the rest

        """
    }

    /// Single-quote a path for the shell, so the copied command still passes one
    /// argument when the home directory contains spaces (embedded apostrophes
    /// become `'\''`).
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
