import ContainerAPIClient
import Foundation
import Logging
import Vapor

struct HealthCheckManagerKey: StorageKey {
    typealias Value = HealthCheckManager
}

/// A function that runs a healthcheck command inside a container and returns
/// its exit code. Injected so tests can stub the side-effecting exec path.
typealias HealthProbe = @Sendable (_ containerId: String, _ cmd: [String], _ timeoutNs: UInt64) async -> Int32

/// Runs Docker `HEALTHCHECK` probes inside containers and tracks their status.
///
/// Apple Container 1.0.0 has no native runtime healthcheck support, so we
/// implement it here: when a container is started, we periodically exec the
/// configured test command via `ContainerClient.createProcess` and record the
/// outcome. `GET /containers/{id}/json` reads from this manager to populate
/// `.State.Health`, which Docker clients (e.g. Supabase CLI, Compose
/// `depends_on: service_healthy`) gate on.
///
/// The probe config is persisted across `create → start` as a JSON-encoded
/// label (`podm.healthcheck`) on the container, so the manager can
/// rebuild the loop on each start without holding pre-start state itself.
actor HealthCheckManager {
    static let healthcheckLabel = "podm.healthcheck"

    // Docker's documented defaults when the field is absent from the request.
    // See https://docs.docker.com/reference/dockerfile/#healthcheck.
    static let defaultIntervalNs: UInt64 = 30 * 1_000_000_000
    static let defaultTimeoutNs: UInt64 = 30 * 1_000_000_000
    static let defaultRetries: Int = 3

    // Lower bounds applied to the user-supplied values. The interval floor is
    // overridable so tests can drive the loop at sub-second cadence; the
    // timeout floor stays fixed because there's no test scenario where we
    // want a sub-second timeout on a real exec.
    static let defaultMinimumIntervalNs: UInt64 = 1_000_000_000
    static let minimumTimeoutNs: UInt64 = 1_000_000_000

    private var statuses: [String: ContainerHealth] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var logs: [String: [HealthLogEntry]] = [:]  // ring buffer, max 5 entries per container
    /// Failing-streak counters shared by the background loop AND manual probes:
    /// a manual success must reset the streak the next background failure counts
    /// from, and a manual failure must count toward the loop's retry threshold.
    private var failingStreaks: [String: Int] = [:]
    /// Per-container generation, bumped on start/stop: a probe suspended across a
    /// stop/restart must not apply its (now-stale) result to the new incarnation.
    private var generations: [String: UInt64] = [:]
    private let log = Logger(label: "podm.healthcheck")
    private let probe: HealthProbe
    private let intervalFloorNs: UInt64
    /// Optional broadcaster for Docker `health_status` events. Nil in tests.
    private let broadcaster: EventBroadcaster?

    private static let maxLogEntries = 5

    private static func formatISO8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    init(probe: @escaping HealthProbe = HealthCheckManager.execProbe, intervalFloorNs: UInt64 = HealthCheckManager.defaultMinimumIntervalNs, broadcaster: EventBroadcaster? = nil) {
        self.probe = probe
        self.intervalFloorNs = intervalFloorNs
        self.broadcaster = broadcaster
    }

    func currentHealth(for id: String) -> ContainerHealth? {
        guard let status = statuses[id] else { return nil }
        return ContainerHealth(Status: status.Status, FailingStreak: status.FailingStreak, Log: logs[id] ?? [])
    }

    /// Start running healthchecks for a container. No-op if already running or if the
    /// test is disabled (`NONE`, empty, or bare `CMD` with no arguments).
    func start(containerId: String, config: HealthcheckConfig) {
        guard Self.parseTest(config.Test) != nil else { return }
        guard tasks[containerId] == nil else { return }
        generations[containerId, default: 0] += 1
        failingStreaks[containerId] = 0
        statuses[containerId] = ContainerHealth(Status: "starting", FailingStreak: 0, Log: [])
        let task = Task { [self] in
            await self.runLoop(containerId: containerId, config: config)
        }
        tasks[containerId] = task
        log.info("[healthcheck] started for \(containerId)")
    }

    /// Stop the healthcheck loop for a container.
    func stop(containerId: String) {
        generations[containerId, default: 0] += 1
        tasks.removeValue(forKey: containerId)?.cancel()
        statuses.removeValue(forKey: containerId)
        logs.removeValue(forKey: containerId)
        failingStreaks.removeValue(forKey: containerId)
    }

    /// Runs exactly one probe on demand — the backing for libpod's
    /// `GET /libpod/containers/{name}/healthcheck` endpoint (`podman healthcheck run`),
    /// as opposed to the background loop above. Uses the same probe path
    /// (`runCheck` → injected `HealthProbe`) and honors the configured timeout,
    /// clamped to `minimumTimeoutNs`.
    ///
    /// The exit code maps directly to the reported status (0 → "healthy",
    /// nonzero → "unhealthy"), matching real podman's manual-run semantics
    /// (`Runtime.HealthCheck` reports unhealthy for a failed on-demand run);
    /// "starting" remains a background-loop concept. On failure the streak
    /// carries over from the tracked status, so repeated manual runs (or a run
    /// alongside an active loop) accumulate like podman's persisted streak. When
    /// a background loop is active for the container, its tracked status and log
    /// are updated so `GET /containers/{id}/json` reflects the manual run; with
    /// no loop running the result is reported without being cached (a stale
    /// cached status would be worse than none).
    ///
    /// Returns nil when the config carries no runnable test (`NONE`, empty, or
    /// bare `CMD`) — the caller maps that to podman's HTTP 409
    /// "container has no defined healthcheck".
    func runProbeOnce(containerId: String, config: HealthcheckConfig) async -> ContainerHealth? {
        guard Self.parseTest(config.Test) != nil else { return nil }
        let configTimeoutNs = config.Timeout.map { UInt64(max($0, 0)) } ?? Self.defaultTimeoutNs
        let timeoutNs = max(configTimeoutNs, Self.minimumTimeoutNs)

        let generation = generations[containerId] ?? 0
        let start = Date()
        let exitCode = await runCheck(containerId: containerId, config: config, timeoutNs: timeoutNs)
        let end = Date()

        let entry = HealthLogEntry(
            Start: Self.formatISO8601(start),
            End: Self.formatISO8601(end),
            ExitCode: exitCode,
            Output: ""
        )

        // A stop/restart while the probe was suspended invalidates this result
        // for tracked state — applying it would mark the NEW incarnation
        // healthy/unhealthy based on the previous run.
        guard (generations[containerId] ?? 0) == generation else { return nil }

        // Shared streak: a manual success resets the counter the background
        // loop counts from; a manual failure counts toward its retry threshold.
        let streak: Int
        if exitCode == 0 {
            streak = 0
            failingStreaks[containerId] = 0
        } else {
            streak = (failingStreaks[containerId] ?? 0) + 1
            failingStreaks[containerId] = streak
        }
        // Immediate manual-run semantics (podman's Runtime.HealthCheck): the
        // RESPONSE reports the probe outcome directly...
        let status = exitCode == 0 ? "healthy" : "unhealthy"

        if isActive(id: containerId) {
            // ...but the PERSISTED transition respects Retries: one manual
            // failure must not mark a tracked container unhealthy before its
            // retry threshold (or during its start period, which the loop
            // owns). A manual success always heals.
            let maxRetries = config.Retries ?? Self.defaultRetries
            let persistedStatus = exitCode == 0 ? "healthy" : (streak >= maxRetries ? "unhealthy" : "starting")
            updateStatus(
                id: containerId,
                health: ContainerHealth(Status: persistedStatus, FailingStreak: streak, Log: []),
                logEntry: entry
            )
        }

        return ContainerHealth(Status: status, FailingStreak: streak, Log: [entry])
    }

    /// Parses Docker's `Test` field into a runnable command vector.
    /// Returns nil for empty input or `["NONE"]` (the disable sentinel).
    static func parseTest(_ test: [String]?) -> [String]? {
        guard let test, !test.isEmpty else { return nil }
        switch test.first {
        case "NONE":
            return nil
        case "CMD-SHELL":
            return ["/bin/sh", "-c", test.dropFirst().joined(separator: " ")]
        case "CMD":
            let args = Array(test.dropFirst())
            return args.isEmpty ? nil : args
        default:
            return test
        }
    }

    // MARK: - Private

    private func updateStatus(id: String, health: ContainerHealth, logEntry: HealthLogEntry? = nil) {
        guard tasks[id] != nil else { return }  // already stopped
        let previous = statuses[id]?.Status
        statuses[id] = health
        if let entry = logEntry {
            var entries = logs[id] ?? []
            entries.append(entry)
            if entries.count > Self.maxLogEntries {
                entries.removeFirst(entries.count - Self.maxLogEntries)
            }
            logs[id] = entries
        }
        // Emit Docker health_status event on every transition (including starting → healthy).
        if previous != health.Status, let broadcaster {
            Task {
                let event = DockerEvent.simpleEvent(
                    id: id, type: "container",
                    status: "health_status: \(health.Status)"
                )
                await broadcaster.broadcast(event)
            }
        }
    }

    private func isActive(id: String) -> Bool {
        tasks[id] != nil
    }

    private func runLoop(containerId: String, config: HealthcheckConfig) async {
        // Intervals on the Docker API are nanoseconds.
        let startPeriodNs = UInt64(max(config.StartPeriod ?? 0, 0))
        let configIntervalNs = config.Interval.map { UInt64(max($0, 0)) } ?? Self.defaultIntervalNs
        let intervalNs = max(configIntervalNs, intervalFloorNs)
        let configTimeoutNs = config.Timeout.map { UInt64(max($0, 0)) } ?? Self.defaultTimeoutNs
        let timeoutNs = max(configTimeoutNs, Self.minimumTimeoutNs)
        let maxRetries = config.Retries ?? Self.defaultRetries

        // Docker 25+ `StartInterval` (`start_interval`): while the start period
        // is open, probes fire at this cadence and their failures do not count
        // toward `Retries` (moby daemon/health.go: `monitor`'s `getInterval`
        // picks the start interval for a still-starting container inside the
        // start period, and `handleProbeResult` forgives such failures). It
        // only applies when BOTH a start interval and a start period are set —
        // moby defaults an absent StartPeriod to 0, which makes "within the
        // start period" immediately false, so a lone StartInterval is inert.
        // An absent StartInterval keeps podm's long-standing behavior of not
        // probing during the start period (moby would probe at its built-in
        // 5s default — a deliberate divergence, kept to avoid changing the
        // cadence of every existing StartPeriod-only healthcheck).
        let configStartIntervalNs = UInt64(max(config.StartInterval ?? 0, 0))
        let probesDuringStartPeriod = configStartIntervalNs > 0 && startPeriodNs > 0
        let startIntervalNs = max(configStartIntervalNs, intervalFloorNs)
        // Monotonic start-period deadline measured from loop start (≈ the
        // container's start, matching moby's comparison against StartedAt).
        let startPeriodEndNs = DispatchTime.now().uptimeNanoseconds + startPeriodNs

        // Without startup probing the start period simply delays the first
        // probe (podm's pre-Docker-25 behavior for StartPeriod-only configs).
        if startPeriodNs > 0 && !probesDuringStartPeriod {
            try? await Task.sleep(nanoseconds: startPeriodNs)
        }

        let generation = generations[containerId] ?? 0

        while !Task.isCancelled {
            guard isActive(id: containerId) else { return }

            let probeStartNs = DispatchTime.now().uptimeNanoseconds
            let start = Date()
            let exitCode = await runCheck(containerId: containerId, config: config, timeoutNs: timeoutNs)
            let end = Date()

            // Generation guard: a stop/restart while this probe was suspended
            // means the result belongs to the previous incarnation.
            guard !Task.isCancelled, generations[containerId] == generation else { return }

            let entry = HealthLogEntry(
                Start: Self.formatISO8601(start),
                End: Self.formatISO8601(end),
                ExitCode: exitCode,
                Output: ""  // stdout capture from container VMs requires pipe infrastructure
            )

            if exitCode == 0 {
                failingStreaks[containerId] = 0
                updateStatus(id: containerId, health: ContainerHealth(Status: "healthy", FailingStreak: 0, Log: []), logEntry: entry)
            } else {
                // moby handleProbeResult: a failure of a still-starting
                // container whose probe began inside the start period is
                // forgiven — the streak is not incremented, so startup
                // flakiness never eats into the Retries budget.
                let withinStartPeriod = probesDuringStartPeriod && probeStartNs < startPeriodEndNs
                let stillStarting = statuses[containerId]?.Status == "starting"
                if withinStartPeriod && stillStarting {
                    updateStatus(
                        id: containerId,
                        health: ContainerHealth(
                            Status: "starting",
                            FailingStreak: failingStreaks[containerId] ?? 0,
                            Log: []
                        ),
                        logEntry: entry
                    )
                    log.debug("[healthcheck] \(containerId) startup failure forgiven (start period, exit=\(exitCode))")
                } else {
                    let failingStreak = (failingStreaks[containerId] ?? 0) + 1
                    failingStreaks[containerId] = failingStreak
                    let status = failingStreak >= maxRetries ? "unhealthy" : "starting"
                    updateStatus(id: containerId, health: ContainerHealth(Status: status, FailingStreak: failingStreak, Log: []), logEntry: entry)
                    log.debug("[healthcheck] \(containerId) → \(status) (streak=\(failingStreak), exit=\(exitCode))")
                }
            }

            // Delay before the next probe (moby getInterval): StartInterval
            // cadence while the start period is still open and the container
            // has not turned healthy yet; regular Interval otherwise.
            let nextDelayNs: UInt64 =
                if probesDuringStartPeriod,
                    DispatchTime.now().uptimeNanoseconds < startPeriodEndNs,
                    statuses[containerId]?.Status == "starting"
                {
                    startIntervalNs
                } else {
                    intervalNs
                }
            try? await Task.sleep(nanoseconds: nextDelayNs)
        }
    }

    private func runCheck(containerId: String, config: HealthcheckConfig, timeoutNs: UInt64) async -> Int32 {
        // nil means NONE / disabled / empty — do not mark the container healthy
        guard let cmd = Self.parseTest(config.Test) else { return 1 }
        return await probe(containerId, cmd, timeoutNs)
    }

    // MARK: - Default probe (real exec)

    private enum ProbeOutcome {
        case exited(Int32)
        case timedOut
    }

    /// Runs `cmd` inside the container via `createProcess`, with a timeout race.
    /// Returns the exit code, or 1 on any failure.
    static let execProbe: HealthProbe = { containerId, cmd, timeoutNs in
        do {
            let containerClient = ContainerClient()
            guard let container = try? await containerClient.get(id: containerId) else { return 1 }

            var processConfig = container.configuration.initProcess
            processConfig.executable = cmd[0]
            processConfig.arguments = Array(cmd.dropFirst())
            processConfig.terminal = false
            // Healthchecks run as root to avoid permission issues for probes
            // that need to bind sockets, read pidfiles, etc.
            processConfig.user = .id(uid: 0, gid: 0)

            let processId = "hc-\(UUID().uuidString.lowercased())"
            let process = try await containerClient.createProcess(
                containerId: containerId,
                processId: processId,
                configuration: processConfig,
                stdio: [nil, nil, nil]
            )
            try await process.start()

            let outcome: ProbeOutcome = try await withThrowingTaskGroup(of: ProbeOutcome.self) { group in
                group.addTask { .exited(try await process.wait()) }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    return .timedOut
                }
                let result = try await group.next() ?? .timedOut
                group.cancelAll()
                return result
            }
            switch outcome {
            case .exited(let code):
                return code
            case .timedOut:
                try? await process.kill(SIGTERM)
                return 1
            }
        } catch {
            return 1
        }
    }
}
