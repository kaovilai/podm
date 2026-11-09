import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import pacmand

/// `GET /libpod/containers/{name}/healthcheck` — `podman healthcheck run`: executes
/// the container's configured healthcheck test once, right now, and reports the
/// fresh result in libpod's `HealthCheckResults` shape. Real podman returns 404 for
/// an unknown container and 409 for "no defined healthcheck" / "not running".
@Suite("LibpodContainerHealthcheckRoute")
struct LibpodContainerHealthcheckRouteTests {

    // MARK: - Helpers

    /// JSON-encodes a config the way the create route persists it as a label.
    private func healthcheckLabelValue(_ config: HealthcheckConfig) throws -> String {
        String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    }

    private func makeManager(exitCode: Int32, recorder: ProbeRecorder) -> HealthCheckManager {
        HealthCheckManager(probe: { containerId, cmd, timeoutNs in
            await recorder.record(containerId: containerId, cmd: cmd, timeoutNs: timeoutNs)
            return exitCode
        })
    }

    /// Registers only the healthcheck route, with `manager` as the app's
    /// HealthCheckManager — mirroring how configure.swift wires the real daemon.
    private func withHealthcheckApp(
        client: ClientContainerProtocol,
        manager: HealthCheckManager,
        _ test: (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[HealthCheckManagerKey.self] = manager
            try app.register(collection: LibpodContainerHealthcheckRoute(client: client))
            try await test(app)
        }
    }

    /// Polls every 5ms up to ~3s for the manager to report `expected` status.
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

    // MARK: - Probe result → response mapping

    @Test("Successful probe returns 200 with Status healthy, streak 0, one log entry")
    func healthyProbe() async throws {
        let recorder = ProbeRecorder()
        let config = HealthcheckConfig(
            Test: ["CMD", "true"], Interval: nil, Timeout: 5_000_000_000, Retries: 3, StartPeriod: nil
        )
        let snapshot = try makeContainerSnapshot(
            nativeId: "hc-ctr",
            networks: [],
            labels: [HealthCheckManager.healthcheckLabel: try healthcheckLabelValue(config)],
            status: .running
        )
        let manager = makeManager(exitCode: 0, recorder: recorder)

        try await withHealthcheckApp(client: HealthcheckRouteClientMock(snapshot: snapshot), manager: manager) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/some-name-or-id/healthcheck") { res async throws in
                #expect(res.status == .ok)
                let health = try res.content.decode(ContainerHealth.self)
                #expect(health.Status == "healthy")
                #expect(health.FailingStreak == 0)
                #expect(health.Log.count == 1)
                #expect(health.Log.first?.ExitCode == 0)
                #expect(health.Log.first?.Start.isEmpty == false)
                #expect(health.Log.first?.End.isEmpty == false)
            }
        }

        // The probe runs via the manager keyed by the native Apple Container id —
        // the same key the background loop and ContainerInspectRoute use — not the
        // URL reference, and honors the configured timeout and parsed command.
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.containerId == "hc-ctr")
        #expect(calls.first?.cmd == ["true"])
        #expect(calls.first?.timeoutNs == 5_000_000_000)
    }

    @Test("Failing probe reports unhealthy with FailingStreak 1")
    func failingProbe() async throws {
        let config = HealthcheckConfig(
            Test: ["CMD", "false"], Interval: nil, Timeout: nil, Retries: 3, StartPeriod: nil
        )
        let snapshot = try makeContainerSnapshot(
            nativeId: "hc-ctr",
            networks: [],
            labels: [HealthCheckManager.healthcheckLabel: try healthcheckLabelValue(config)],
            status: .running
        )
        let manager = makeManager(exitCode: 1, recorder: ProbeRecorder())

        try await withHealthcheckApp(client: HealthcheckRouteClientMock(snapshot: snapshot), manager: manager) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/hc-ctr/healthcheck") { res async throws in
                #expect(res.status == .ok)
                let health = try res.content.decode(ContainerHealth.self)
                #expect(health.Status == "unhealthy")
                #expect(health.FailingStreak == 1)
                #expect(health.Log.first?.ExitCode == 1)
            }
        }
    }

    @Test("CMD-SHELL test is parsed into /bin/sh -c for the probe")
    func cmdShellIsParsed() async throws {
        let recorder = ProbeRecorder()
        let config = HealthcheckConfig(
            Test: ["CMD-SHELL", "pg_isready -U postgres"], Interval: nil, Timeout: nil, Retries: 3, StartPeriod: nil
        )
        let snapshot = try makeContainerSnapshot(
            nativeId: "hc-ctr",
            networks: [],
            labels: [HealthCheckManager.healthcheckLabel: try healthcheckLabelValue(config)],
            status: .running
        )
        let manager = makeManager(exitCode: 0, recorder: recorder)

        try await withHealthcheckApp(client: HealthcheckRouteClientMock(snapshot: snapshot), manager: manager) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/hc-ctr/healthcheck") { res async in
                #expect(res.status == .ok)
            }
        }

        let calls = await recorder.calls
        #expect(calls.first?.cmd == ["/bin/sh", "-c", "pg_isready -U postgres"])
    }

    @Test("POST is not registered — real podman serves GET only")
    func postIsRejected() async throws {
        let config = HealthcheckConfig(
            Test: ["CMD", "true"], Interval: nil, Timeout: nil, Retries: 3, StartPeriod: nil
        )
        let snapshot = try makeContainerSnapshot(
            nativeId: "hc-ctr",
            networks: [],
            labels: [HealthCheckManager.healthcheckLabel: try healthcheckLabelValue(config)],
            status: .running
        )
        let manager = makeManager(exitCode: 0, recorder: ProbeRecorder())

        try await withHealthcheckApp(client: HealthcheckRouteClientMock(snapshot: snapshot), manager: manager) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/hc-ctr/healthcheck") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    // MARK: - Error paths

    @Test("Container without a healthcheck label is 409, matching podman's 'no defined healthcheck'")
    func noHealthcheckConfigured() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "hc-ctr", networks: [], labels: [:], status: .running)
        let manager = makeManager(exitCode: 0, recorder: ProbeRecorder())

        try await withHealthcheckApp(client: HealthcheckRouteClientMock(snapshot: snapshot), manager: manager) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/hc-ctr/healthcheck") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("no defined healthcheck"))
            }
        }
    }

    @Test("Test: NONE (disabled healthcheck) is 409, not a probe run")
    func noneTestIsRejected() async throws {
        let recorder = ProbeRecorder()
        let config = HealthcheckConfig(
            Test: ["NONE"], Interval: nil, Timeout: nil, Retries: 3, StartPeriod: nil
        )
        let snapshot = try makeContainerSnapshot(
            nativeId: "hc-ctr",
            networks: [],
            labels: [HealthCheckManager.healthcheckLabel: try healthcheckLabelValue(config)],
            status: .running
        )
        let manager = makeManager(exitCode: 0, recorder: recorder)

        try await withHealthcheckApp(client: HealthcheckRouteClientMock(snapshot: snapshot), manager: manager) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/hc-ctr/healthcheck") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("no defined healthcheck"))
            }
        }

        let calls = await recorder.calls
        #expect(calls.isEmpty, "NONE must not trigger a probe")
    }

    @Test("Unknown container is 404")
    func unknownContainer() async throws {
        let manager = makeManager(exitCode: 0, recorder: ProbeRecorder())

        try await withHealthcheckApp(client: HealthcheckRouteClientMock(snapshot: nil), manager: manager) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/no-such-ctr/healthcheck") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Stopped container is 409, matching podman's 'container is not running'")
    func stoppedContainer() async throws {
        let config = HealthcheckConfig(
            Test: ["CMD", "true"], Interval: nil, Timeout: nil, Retries: 3, StartPeriod: nil
        )
        let snapshot = try makeContainerSnapshot(
            nativeId: "hc-ctr",
            networks: [],
            labels: [HealthCheckManager.healthcheckLabel: try healthcheckLabelValue(config)],
            status: .stopped
        )
        let recorder = ProbeRecorder()
        let manager = makeManager(exitCode: 0, recorder: recorder)

        try await withHealthcheckApp(client: HealthcheckRouteClientMock(snapshot: snapshot), manager: manager) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/hc-ctr/healthcheck") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("not running"))
            }
        }

        let calls = await recorder.calls
        #expect(calls.isEmpty, "a stopped container must not be probed")
    }

    // MARK: - HealthCheckManager.runProbeOnce (on-demand probe semantics)

    @Test("runProbeOnce returns nil for NONE (no runnable test)")
    func runProbeOnceNilForNone() async throws {
        let recorder = ProbeRecorder()
        let manager = makeManager(exitCode: 0, recorder: recorder)
        let cfg = HealthcheckConfig(Test: ["NONE"], Interval: nil, Timeout: nil, Retries: 3, StartPeriod: nil)
        let result = await manager.runProbeOnce(containerId: "c1", config: cfg)
        #expect(result == nil)
        let calls = await recorder.calls
        #expect(calls.isEmpty)
    }

    @Test("runProbeOnce clamps a sub-floor timeout to minimumTimeoutNs")
    func runProbeOnceClampsTimeout() async throws {
        let recorder = ProbeRecorder()
        let manager = makeManager(exitCode: 0, recorder: recorder)
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: nil, Timeout: 100, Retries: 3, StartPeriod: nil)
        _ = await manager.runProbeOnce(containerId: "c1", config: cfg)
        let calls = await recorder.calls
        #expect(calls.first?.timeoutNs == HealthCheckManager.minimumTimeoutNs)
    }

    @Test("runProbeOnce uses the 30s Docker default when no timeout is configured")
    func runProbeOnceDefaultTimeout() async throws {
        let recorder = ProbeRecorder()
        let manager = makeManager(exitCode: 0, recorder: recorder)
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: nil, Timeout: nil, Retries: 3, StartPeriod: nil)
        _ = await manager.runProbeOnce(containerId: "c1", config: cfg)
        let calls = await recorder.calls
        #expect(calls.first?.timeoutNs == HealthCheckManager.defaultTimeoutNs)
    }

    @Test("runProbeOnce carries the failing streak from an active background loop and updates the tracked status")
    func runProbeOnceCarriesStreak() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 1 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(
            Test: ["CMD", "false"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 1, StartPeriod: nil
        )
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("unhealthy", on: mgr, id: "c1")
        let streakBefore = await mgr.currentHealth(for: "c1")?.FailingStreak ?? 0

        let result = await mgr.runProbeOnce(containerId: "c1", config: cfg)

        #expect(result?.Status == "unhealthy")
        #expect((result?.FailingStreak ?? 0) > streakBefore, "manual failure must extend the streak")
        // The tracked status is updated too (>= because the background loop may
        // have recorded another probe in between), so inspect reflects the manual run.
        let after = await mgr.currentHealth(for: "c1")
        #expect((after?.FailingStreak ?? 0) >= (result?.FailingStreak ?? 0))
        #expect(after?.Log.isEmpty == false)
        await mgr.stop(containerId: "c1")
    }
}

// MARK: - Mocks

private actor ProbeRecorder {
    private(set) var calls: [(containerId: String, cmd: [String], timeoutNs: UInt64)] = []

    func record(containerId: String, cmd: [String], timeoutNs: UInt64) {
        calls.append((containerId, cmd, timeoutNs))
    }
}

/// Returns the same fixed snapshot for every lookup (nil = "no such container").
private actor HealthcheckRouteClientMock: ClientContainerProtocol {
    private let snapshot: ContainerSnapshot?

    init(snapshot: ContainerSnapshot?) {
        self.snapshot = snapshot
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        snapshot.map { [$0] } ?? []
    }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
