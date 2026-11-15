// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import podm

@Suite("WakeProgress")
struct WakeProgressTests {

    @Test("a wake shorter than the announce threshold stays silent")
    func quietFastWake() {
        #expect(WakeProgress.decision(elapsed: 0, announced: false) == .wait)
        #expect(WakeProgress.decision(elapsed: 0.39, announced: false) == .wait)
    }

    @Test("a slow wake asks for an announcement exactly once")
    func announceOnce() {
        #expect(WakeProgress.decision(elapsed: 0.4, announced: false) == .announce)
        #expect(WakeProgress.decision(elapsed: 5, announced: false) == .announce)
        // After the caller has announced, further polls stay quiet.
        #expect(WakeProgress.decision(elapsed: 5, announced: true) == .wait)
    }

    @Test("the deadline wins over announcing")
    func deadlineWins() {
        #expect(WakeProgress.decision(elapsed: 29.9, announced: true) == .wait)
        #expect(WakeProgress.decision(elapsed: 30, announced: false) == .giveUp)
        #expect(WakeProgress.decision(elapsed: 30, announced: true) == .giveUp)
    }

    @Test("notices name the state and the fix")
    func notices() {
        #expect(WakeProgress.wakeNotice().contains("waking podmd"))
        #expect(WakeProgress.timeoutNotice().contains("30s"))
        #expect(WakeProgress.timeoutNotice().contains("podm doctor"))

        let failure = WakeProgress.kickstartFailureNotice(
            exitStatus: 113,
            launchdDomain: "gui/501",
            plistPath: "/Users/example/Library/LaunchAgents/io.github.podm.daemon.plist")
        #expect(failure.contains("exited 113"))
        #expect(failure.contains("launchctl bootstrap gui/501"))
        #expect(failure.contains("podm serve"))
        #expect(failure.contains("podm doctor"))
        #expect(failure.contains("io.github.podm.daemon.plist"))
        // stderr lines must be complete lines, or the next output runs on.
        #expect(WakeProgress.wakeNotice().hasSuffix("\n"))
        #expect(WakeProgress.timeoutNotice().hasSuffix("\n"))
        #expect(failure.hasSuffix("\n"))
    }
}
