import Foundation
import Testing

@testable import podmd

@Suite("HealthCheckManager")
struct HealthCheckManagerTests {

    // MARK: - Test parsing (pure, no actor)

    @Test("CMD-SHELL wraps args in /bin/sh -c")
    func parseCmdShell() {
        #expect(HealthCheckManager.parseTest(["CMD-SHELL", "pg_isready -U postgres"]) == ["/bin/sh", "-c", "pg_isready -U postgres"])
    }

    @Test("CMD passes args through directly")
    func parseCmd() {
        #expect(HealthCheckManager.parseTest(["CMD", "pg_isready", "-U", "postgres"]) == ["pg_isready", "-U", "postgres"])
    }

    @Test("NONE disables the check")
    func parseNone() {
        #expect(HealthCheckManager.parseTest(["NONE"]) == nil)
    }

    @Test("Bare test (no CMD prefix) runs as-is")
    func parseBare() {
        #expect(HealthCheckManager.parseTest(["pg_isready"]) == ["pg_isready"])
    }

    @Test("Empty or nil test returns nil")
    func parseEmpty() {
        #expect(HealthCheckManager.parseTest(nil) == nil)
        #expect(HealthCheckManager.parseTest([]) == nil)
    }

    @Test("CMD with no following args returns nil (avoids exec of empty cmd)")
    func parseCmdWithoutArgs() {
        #expect(HealthCheckManager.parseTest(["CMD"]) == nil)
    }

    // MARK: - Lifecycle

    @Test("currentHealth is nil before start")
    func notRunningInitially() async {
        let mgr = HealthCheckManager()
        let h = await mgr.currentHealth(for: "c1")
        #expect(h == nil)
    }

    @Test("stop clears status")
    func stopClearsStatus() async {
        // Probe never returns within the test window — we just want a quick
        // start-then-stop to validate state is wiped.
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        #expect(await mgr.currentHealth(for: "c1") != nil)
        await mgr.stop(containerId: "c1")
        #expect(await mgr.currentHealth(for: "c1") == nil)
    }

    @Test("start is idempotent")
    func startIdempotent() async {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        let firstStatus = await mgr.currentHealth(for: "c1")
        await mgr.start(containerId: "c1", config: cfg)  // second call no-ops
        let secondStatus = await mgr.currentHealth(for: "c1")
        #expect(firstStatus?.Status == "starting")
        #expect(secondStatus?.Status == "starting")
        await mgr.stop(containerId: "c1")
    }

    // MARK: - State transitions

    @Test("First successful probe transitions to healthy")
    func healthyOnFirstSuccess() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect(h?.Status == "healthy")
        #expect(h?.FailingStreak == 0)
        await mgr.stop(containerId: "c1")
    }

    @Test("Persistent failures transition to unhealthy after Retries")
    func unhealthyAfterRetries() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 1 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "false"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 2, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("unhealthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect(h?.Status == "unhealthy")
        #expect((h?.FailingStreak ?? 0) >= 2)
        await mgr.stop(containerId: "c1")
    }

    // MARK: - Health log entries

    @Test("Log entries are recorded after each probe")
    func logEntriesRecorded() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.Log.count ?? 0) > 0)
        #expect(h?.Log.first?.ExitCode == 0)
        #expect(h?.Log.first?.Start.isEmpty == false)
        await mgr.stop(containerId: "c1")
    }

    @Test("Log is capped at 5 entries")
    func logCappedAt5() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        // Wait long enough for >5 probe calls at 1ms interval
        try await Task.sleep(nanoseconds: 30_000_000)
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.Log.count ?? 0) <= 5)
        await mgr.stop(containerId: "c1")
    }

    // MARK: - health_status events

    @Test("health_status events are emitted on status transition to healthy")
    func healthStatusEventsEmitted() async throws {
        actor Collector {
            var statuses: [String] = []
            func append(_ s: String) { statuses.append(s) }
        }
        let collector = Collector()
        let broadcaster = EventBroadcaster()

        let collectTask = Task { @Sendable in
            for await event in await broadcaster.stream() {
                if event.status.hasPrefix("health_status:") {
                    await collector.append(event.status)
                }
                if await collector.statuses.count >= 1 { break }
            }
        }

        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000,
            broadcaster: broadcaster
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        try await Task.sleep(nanoseconds: 20_000_000)
        collectTask.cancel()
        await mgr.stop(containerId: "c1")

        let received = await collector.statuses
        #expect(received.contains("health_status: healthy"))
    }

    // MARK: - Log entry detail for failing probe

    @Test("Log entry records non-zero exit code on failure")
    func logEntryForFailingProbe() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 1 },  // always fail
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "false"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 1, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("unhealthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.Log.count ?? 0) > 0)
        #expect(h?.Log.first?.ExitCode == 1)
        await mgr.stop(containerId: "c1")
    }

    @Test("Log entry Start and End are non-empty ISO8601 strings")
    func logEntryTimestampsAreISO8601() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        guard let entry = h?.Log.first else {
            Issue.record("No log entries")
            return
        }
        // ISO8601 with fractional seconds: e.g. "2026-06-13T01:23:45.678Z"
        #expect(entry.Start.contains("T"))
        #expect(entry.Start.contains("Z"))
        #expect(entry.End.contains("T"))
        // End must be >= Start (both valid timestamps)
        let start = ISO8601DateFormatter().date(from: entry.Start)
        let end = ISO8601DateFormatter().date(from: entry.End)
        if let s = start, let e = end {
            #expect(e >= s)
        }
        await mgr.stop(containerId: "c1")
    }

    // MARK: - Helpers

    /// Polls every 5ms up to ~3s for the manager to report `expected` status.
    /// Fails the test if the status is never reached.
    private static func waitForStatus(_ expected: String, on mgr: HealthCheckManager, id: String) async throws {
        for _ in 0..<600 {
            if await mgr.currentHealth(for: id)?.Status == expected {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let actual = await mgr.currentHealth(for: id)?.Status
        Issue.record("waitForStatus timed out: expected '\(expected)' but got '\(actual ?? "nil")' for container '\(id)'")
        struct TimeoutError: Error {}
        throw TimeoutError()
    }
}

/// Records the (monotonic) time of every probe call, so tests can observe the
/// loop's cadence without relying on the capped health log.
private actor ProbeTimeline {
    private(set) var timestamps: [UInt64] = []

    func record() {
        timestamps.append(DispatchTime.now().uptimeNanoseconds)
    }
}

/// Docker 25+ `StartInterval` (`start_interval`) startup semantics, mirroring
/// moby's `daemon/health.go` (v28.5.2 — the version podm's API level targets):
///
/// - while the start period is open and the container is still `starting`,
///   probes fire at `StartInterval` cadence instead of `Interval`
///   (`monitor`'s `getInterval`);
/// - failures of such probes do not increment the failing streak
///   (`handleProbeResult` forgives failures that began within the start
///   period of a still-starting container);
/// - a success still marks the container healthy immediately, and a healthy
///   container probes at `Interval` even inside the start period;
/// - a `StartInterval` without a `StartPeriod` is inert (moby defaults
///   StartPeriod to 0, making "within the start period" immediately false).
@Suite("HealthCheckManager — StartInterval startup semantics")
struct HealthCheckManagerStartIntervalTests {

    /// Polls every 5ms up to ~6s for the manager to report `expected` status —
    /// the generous budget rides out contention from the parallel test suite.
    private static func waitForStatus(_ expected: String, on mgr: HealthCheckManager, id: String) async throws {
        for _ in 0..<1200 {
            if await mgr.currentHealth(for: id)?.Status == expected {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let actual = await mgr.currentHealth(for: id)?.Status
        Issue.record("waitForStatus timed out: expected '\(expected)' but got '\(actual ?? "nil")' for container '\(id)'")
        struct TimeoutError: Error {}
        throw TimeoutError()
    }

    @Test("probes fire at StartInterval cadence during the start period, then at Interval")
    func startIntervalCadenceDuringStartPeriod() async throws {
        let timeline = ProbeTimeline()
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                await timeline.record()
                return 1  // never healthy: the loop stays "starting", keeping the startup cadence
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(
            Test: ["CMD", "false"],
            Interval: 500_000_000,  // 500ms regular cadence
            Timeout: 1_000_000_000,
            Retries: 100,  // never unhealthy during the test window
            StartPeriod: 4_000_000_000,  // 4s startup window — long enough to ride out
            // contention from the parallel test suite
            StartInterval: 1_000_000  // 1ms startup cadence (allowed by the test floor)
        )
        let loopStartNs = DispatchTime.now().uptimeNanoseconds
        await mgr.start(containerId: "cadence", config: cfg)

        // While the start period is open, probes must fire at StartInterval
        // cadence: at the 500ms Interval, ten probes would need ≥ 4.5s (a
        // Task.sleep never returns early), far beyond this 3.5s poll budget.
        // At the ~1ms startup cadence ten probes accumulate in milliseconds,
        // even with heavy contention stretching each iteration.
        var earlyCount = 0
        for _ in 0..<140 {
            earlyCount = await timeline.timestamps.count
            if earlyCount >= 10 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(earlyCount >= 10, "expected StartInterval startup cadence, saw only \(earlyCount) probes in 3.5s")

        // After the start period ends the cadence must drop to Interval: wait
        // out the window, then poll for a ≥ 300ms gap between consecutive
        // probes ending past the period — impossible at the 1ms startup
        // cadence once the suite's parallel load has subsided, and guaranteed
        // at the 500ms Interval (the first post-period sleep alone is ≥ 500ms).
        let settleDeadlineNs = loopStartNs + 4_200_000_000
        let settleNowNs = DispatchTime.now().uptimeNanoseconds
        if settleNowNs < settleDeadlineNs {
            try await Task.sleep(nanoseconds: settleDeadlineNs - settleNowNs)
        }
        let periodEndNs = loopStartNs + 4_050_000_000
        var sawIntervalGap = false
        for _ in 0..<120 {
            let times = await timeline.timestamps
            if zip(times, times.dropFirst()).contains(where: { $1 > periodEndNs && $1 - $0 >= 300_000_000 }) {
                sawIntervalGap = true
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(sawIntervalGap, "cadence never switched from StartInterval to Interval after the start period")
        await mgr.stop(containerId: "cadence")
    }

    @Test("failures during the start period do not count toward Retries")
    func startupFailuresAreForgiven() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 1 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(
            Test: ["CMD", "false"],
            Interval: 1_000_000,
            Timeout: 1_000_000_000,
            Retries: 1,  // a single counted failure must flip the container unhealthy
            StartPeriod: 300_000_000,
            StartInterval: 1_000_000
        )
        await mgr.start(containerId: "forgiven", config: cfg)

        // ~150ms into a 300ms start period: dozens of failed probes have run,
        // none of which may count — with Retries=1 the container would have
        // gone unhealthy on the very first counted failure.
        try await Task.sleep(nanoseconds: 150_000_000)
        let midHealth = await mgr.currentHealth(for: "forgiven")
        #expect(midHealth?.Status == "starting", "startup failures must not mark the container unhealthy")
        #expect(midHealth?.FailingStreak == 0, "startup failures must not count toward the retry budget")

        // Once the start period ends, the next failure counts normally.
        try await Self.waitForStatus("unhealthy", on: mgr, id: "forgiven")
        let endHealth = await mgr.currentHealth(for: "forgiven")
        #expect((endHealth?.FailingStreak ?? 0) >= 1)
        await mgr.stop(containerId: "forgiven")
    }

    @Test("StartInterval without a StartPeriod is inert — no startup cadence, no forgiveness")
    func startIntervalWithoutStartPeriodIsIgnored() async throws {
        let timeline = ProbeTimeline()
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                await timeline.record()
                return 1
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(
            Test: ["CMD", "false"],
            Interval: 300_000_000,  // 300ms regular cadence
            Timeout: 1_000_000_000,
            Retries: 3,
            StartPeriod: nil,
            StartInterval: 1_000_000  // must be ignored: no start period
        )
        await mgr.start(containerId: "no-period", config: cfg)

        // 700ms in: at the 300ms Interval cadence at most three probes can
        // have fired (a Task.sleep never returns early, so the count has a
        // hard ceiling); at the 1ms StartInterval cadence there would be
        // hundreds on an idle machine.
        try await Task.sleep(nanoseconds: 700_000_000)
        let count = await timeline.timestamps.count
        #expect(count <= 5, "StartInterval must not set the cadence without a StartPeriod, saw \(count) probes in 700ms")

        // Failures count from the first probe (no startup grace window).
        try await Self.waitForStatus("unhealthy", on: mgr, id: "no-period")
        await mgr.stop(containerId: "no-period")
    }

    @Test("the podm.healthcheck label round-trips StartInterval (container inspect surface)")
    func labelRoundTripsStartInterval() throws {
        // The create route persists the resolved healthcheck as a JSON label;
        // the start route and `GET /containers/{id}/json` (Config.Healthcheck)
        // decode it back. StartInterval must survive that round-trip…
        let config = HealthcheckConfig(
            Test: ["CMD", "true"],
            Interval: 30_000_000_000,
            Timeout: 5_000_000_000,
            Retries: 3,
            StartPeriod: 10_000_000_000,
            StartInterval: 5_000_000_000
        )
        let decoded = try JSONDecoder().decode(
            HealthcheckConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.StartInterval == 5_000_000_000)

        // …and labels written before the field existed (no StartInterval key)
        // must keep decoding — inspect of pre-upgrade containers can't fail.
        let legacy = try JSONDecoder().decode(
            HealthcheckConfig.self,
            from: Data(#"{"Test":["CMD","true"],"Interval":1000000000}"#.utf8))
        #expect(legacy.Test == ["CMD", "true"])
        #expect(legacy.Interval == 1_000_000_000)
        #expect(legacy.StartInterval == nil)
    }

    @Test("a success during the start period marks healthy immediately and drops to Interval cadence")
    func successDuringStartPeriodMarksHealthy() async throws {
        let timeline = ProbeTimeline()
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                await timeline.record()
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(
            Test: ["CMD", "true"],
            Interval: 300_000_000,
            Timeout: 1_000_000_000,
            Retries: 3,
            StartPeriod: 1_000_000_000,  // window still open long after the first success
            StartInterval: 1_000_000
        )
        await mgr.start(containerId: "early-healthy", config: cfg)

        try await Self.waitForStatus("healthy", on: mgr, id: "early-healthy")

        // moby's getInterval: a non-starting container probes at Interval even
        // inside the start period. 150ms after the healthy transition the
        // 300ms Interval cannot have fired a second probe yet — at the 1ms
        // StartInterval cadence there would be ~150.
        try await Task.sleep(nanoseconds: 150_000_000)
        let count = await timeline.timestamps.count
        #expect(count <= 1, "healthy container must probe at Interval, not StartInterval cadence, saw \(count) probes")
        await mgr.stop(containerId: "early-healthy")
    }
}
