// SPDX-License-Identifier: Apache-2.0

import Foundation

/// User-visible progress for waking an idle-exited daemon.
///
/// The shim used to spend the whole wake deadline in silence: a cold start
/// looked like a hung `docker ps` / `podman ps`, and an installed-but-unloaded
/// LaunchAgent burned the full 60s before the real CLI printed its own connect
/// error. These helpers hold the decisions and messages, kept free of launchd
/// and clocks so they can be unit tested.
enum WakeProgress {
    /// A wake that completes sooner than this stays silent — most wakes are
    /// sub-second (the daemon is already warm), and a progress line on every
    /// command would be noise. Past it, the wait is real and worth a line.
    static let announceAfter: TimeInterval = 0.4

    /// Overall readiness deadline, matching the integration CI's readiness
    /// budget. A cold start runs startup housekeeping (container-apiserver
    /// bring-up, healthcheck resume) before the socket answers — up to ~30s on
    /// a slow machine.
    static let deadline: TimeInterval = 60

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
        "podm: podmd did not become ready within \(Int(deadline))s — continuing to the CLI\n"
    }

    /// Printed when launchd refuses to start the agent (typically: the plist
    /// exists but the job was never loaded, or was booted out).
    static func kickstartFailureNotice(exitStatus: Int32, plistPath: String) -> String {
        """
        podm: podmd is not running and launchd could not start it (launchctl kickstart exited \(exitStatus))
        podm: run `podm install` to reload the LaunchAgent, or `podm serve` for a foreground daemon
        podm: agent file: \(plistPath)

        """
    }
}
