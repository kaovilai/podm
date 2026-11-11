import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// GET /libpod/containers/stats — libpod's own pre-computed stats schema
/// (podman's `entities.ContainerStatsReport` / `define.ContainerStats`),
/// verified against podman's `abi.ContainerStats` and
/// `libpod/stats_linux.go` field semantics.
@Suite("LibpodContainersStatsRoute")
struct LibpodContainersStatsTests {

    // MARK: - Helpers

    private func makeSample(
        cpuUsec: UInt64 = 0,
        memUsage: UInt64? = nil,
        memLimit: UInt64? = nil,
        netRx: UInt64? = nil,
        netTx: UInt64? = nil,
        blkRead: UInt64? = nil,
        blkWrite: UInt64? = nil,
        pids: UInt64? = nil
    ) -> ContainerStats {
        ContainerStats(
            id: "test",
            memoryUsageBytes: memUsage,
            memoryLimitBytes: memLimit,
            cpuUsageUsec: cpuUsec,
            networkRxBytes: netRx,
            networkTxBytes: netTx,
            blockReadBytes: blkRead,
            blockWriteBytes: blkWrite,
            numProcesses: pids
        )
    }

    private func makeSnapshot(id: String, started: Date? = nil, status: RuntimeStatus = .running) -> ContainerSnapshot {
        let processConfig = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let imageDesc = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        let config = ContainerConfiguration(id: id, image: imageDesc, process: processConfig)
        return ContainerSnapshot(configuration: config, status: status, networks: [], startedDate: started)
    }

    // MARK: - CPU math (podman's calculateCPUPercent)

    @Test("cpuPercent is container CPU delta over wall-clock delta × 100")
    func cpuPercentDelta() {
        // 0.25s CPU over 1s wall → 25%; no core-count division.
        let percent = LibpodContainerStats.cpuPercent(
            currCPUNano: 250_000_000, prevCPUNano: 0,
            currSystemNano: 1_000_000_000_000, prevSystemNano: 999_000_000_000)
        #expect(abs(percent - 25) < 1e-9)
    }

    @Test("cpuPercent can exceed 100 (multi-core usage, like podman)")
    func cpuPercentOver100() {
        let percent = LibpodContainerStats.cpuPercent(
            currCPUNano: 3_000_000_000, prevCPUNano: 0,
            currSystemNano: 1_000_000_000_000, prevSystemNano: 999_000_000_000)
        #expect(abs(percent - 300) < 1e-9)
    }

    @Test("cpuPercent guards zero deltas and reversed counters")
    func cpuPercentGuards() {
        // No wall-clock delta → 0
        #expect(
            LibpodContainerStats.cpuPercent(
                currCPUNano: 100, prevCPUNano: 0, currSystemNano: 500, prevSystemNano: 500) == 0)
        // CPU counter went backwards → 0 (restart, handled by caller too)
        #expect(
            LibpodContainerStats.cpuPercent(
                currCPUNano: 100, prevCPUNano: 200, currSystemNano: 500, prevSystemNano: 100) == 0)
    }

    // MARK: - Row builder

    @Test("first sample (no baseline) computes CPU% since container start, like podman's seeding")
    func firstSampleSinceStart() {
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = makeSnapshot(id: "c1", started: Date(timeIntervalSince1970: 990))
        let stats = LibpodContainerStats.build(
            snapshot: snapshot,
            sample: makeSample(
                cpuUsec: 500_000, memUsage: 1_000_000, memLimit: 2_000_000,
                netRx: 100, netTx: 200, blkRead: 4096, blkWrite: 8192, pids: 7),
            baseline: nil,
            now: now)

        // 0.5s CPU over the 10s since start → 5%; AvgCPU is the same on the first sample.
        #expect(abs(stats.CPU - 5) < 1e-9)
        #expect(abs(stats.AvgCPU - 5) < 1e-9)

        #expect(stats.CPUNano == 500_000_000)
        #expect(stats.CPUSystemNano == 0)  // no user/kernel split from Apple Container
        #expect(stats.SystemNano == 1_000_000_000_000)
        // podman's UpTime/Duration are the container's total CPU usage, not wall uptime.
        #expect(stats.UpTime == 500_000_000)
        #expect(stats.Duration == 500_000_000)

        #expect(stats.MemUsage == 1_000_000)
        #expect(stats.MemLimit == 2_000_000)
        #expect(abs(stats.MemPerc - 50) < 1e-9)

        #expect(stats.Network?["eth0"]?.RxBytes == 100)
        #expect(stats.Network?["eth0"]?.TxBytes == 200)
        #expect(stats.Network?["eth0"]?.RxPackets == 0)

        #expect(stats.BlockInput == 4096)
        #expect(stats.BlockOutput == 8192)
        #expect(stats.PIDs == 7)

        #expect(stats.Name == "c1")
        #expect(stats.ContainerID == DockerContainerID.hexId(for: snapshot))
    }

    @Test("baseline sample computes CPU% from the delta between ticks")
    func deltaFromBaseline() {
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = makeSnapshot(id: "c1", started: Date(timeIntervalSince1970: 990))
        let stats = LibpodContainerStats.build(
            snapshot: snapshot,
            sample: makeSample(cpuUsec: 500_000),
            baseline: LibpodContainerStats.CPUBaseline(cpuNano: 200_000_000, systemNano: 980_000_000_000),
            now: now)

        // 0.3s CPU delta over the 20s since the previous sample → 1.5%
        #expect(abs(stats.CPU - 1.5) < 1e-9)
        // AvgCPU still averages over the whole run: 0.5s over 10s → 5%
        #expect(abs(stats.AvgCPU - 5) < 1e-9)
    }

    @Test("shrinking CPU total (container restart) resets the baseline like podman")
    func restartResetsBaseline() {
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = makeSnapshot(id: "c1", started: Date(timeIntervalSince1970: 990))
        let stats = LibpodContainerStats.build(
            snapshot: snapshot,
            sample: makeSample(cpuUsec: 500_000),
            baseline: LibpodContainerStats.CPUBaseline(cpuNano: 800_000_000, systemNano: 995_000_000_000),
            now: now)

        // Baseline reset to (0, 0): 0.5s over 1000s of wall clock → 0.05%
        #expect(abs(stats.CPU - 0.05) < 1e-9)
    }

    @Test("missing memory limit falls back to host physical memory")
    func memLimitFallback() {
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = makeSnapshot(id: "c1", started: Date(timeIntervalSince1970: 990))
        let stats = LibpodContainerStats.build(
            snapshot: snapshot, sample: makeSample(memUsage: 1_000_000), baseline: nil, now: now)
        #expect(stats.MemLimit == hostPhysicalMemory())
    }

    @Test("stopped row carries only ID and Name, like podman's zero-value stats")
    func stoppedRow() {
        let stats = LibpodContainerStats.stopped(id: "hexid", name: "c1")
        #expect(stats.ContainerID == "hexid")
        #expect(stats.Name == "c1")
        #expect(stats.AvgCPU == 0 && stats.CPU == 0 && stats.MemPerc == 0)
        #expect(stats.CPUNano == 0 && stats.CPUSystemNano == 0 && stats.SystemNano == 0)
        #expect(stats.MemUsage == 0 && stats.MemLimit == 0)
        #expect(stats.BlockInput == 0 && stats.BlockOutput == 0 && stats.PIDs == 0)
        #expect(stats.UpTime == 0 && stats.Duration == 0)
        #expect(stats.Network == nil)
    }

    // MARK: - Wire shape

    @Test("report encodes with podman's Go field names and Error:null")
    func wireKeys() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = makeSnapshot(id: "c1", started: Date(timeIntervalSince1970: 990))
        let row = LibpodContainerStats.build(
            snapshot: snapshot,
            sample: makeSample(cpuUsec: 500_000, memUsage: 1, memLimit: 2, netRx: 1, netTx: 1),
            baseline: nil, now: now)
        let report = LibpodContainerStatsReport(Error: nil, Stats: [row])

        let data = try JSONEncoder().encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["Error", "Stats"])
        #expect(object["Error"] is NSNull)

        let rows = try #require(object["Stats"] as? [[String: Any]])
        let first = try #require(rows.first)
        #expect(
            Set(first.keys) == [
                "AvgCPU", "ContainerID", "Name", "CPU", "CPUNano", "CPUSystemNano", "SystemNano",
                "MemUsage", "MemLimit", "MemPerc", "Network", "BlockInput", "BlockOutput", "PIDs",
                "UpTime", "Duration",
            ])

        let eth0 = try #require((first["Network"] as? [String: Any])?["eth0"] as? [String: Any])
        #expect(
            Set(eth0.keys) == [
                "RxBytes", "RxDropped", "RxErrors", "RxPackets",
                "TxBytes", "TxDropped", "TxErrors", "TxPackets",
            ])
    }

    @Test("report round-trips through a decoder (podman remote client shape)")
    func decodeRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = makeSnapshot(id: "c1", started: Date(timeIntervalSince1970: 990))
        let row = LibpodContainerStats.build(
            snapshot: snapshot, sample: makeSample(cpuUsec: 500_000, pids: 3), baseline: nil, now: now)
        let data = try JSONEncoder().encode(LibpodContainerStatsReport(Error: nil, Stats: [row]))

        let decoded = try JSONDecoder().decode(LibpodContainerStatsReport.self, from: data)
        #expect(decoded.Error == nil)
        #expect(decoded.Stats.count == 1)
        #expect(decoded.Stats.first?.CPUNano == 500_000_000)
        #expect(decoded.Stats.first?.PIDs == 3)
    }

    @Test("non-nil Error encodes as a string")
    func errorEncoding() throws {
        let data = try JSONEncoder().encode(LibpodContainerStatsReport(Error: "boom", Stats: []))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["Error"] as? String) == "boom")
        #expect((object["Stats"] as? [[String: Any]])?.isEmpty == true)
    }

    // MARK: - Target resolution and collection

    @Test("resolveTargets defaults to running containers; all=true widens to every container")
    func resolveTargetsDefaultAndAll() async throws {
        let client = StatsMockClient(containers: [
            makeSnapshot(id: "running"),
            makeSnapshot(id: "stopped", status: .stopped),
        ])
        let running = try await LibpodContainersStatsRoute.resolveTargets(
            client: client, requested: [], all: false, strict: true)
        #expect(running.map(\.id) == ["running"])

        let every = try await LibpodContainersStatsRoute.resolveTargets(
            client: client, requested: [], all: true, strict: true)
        #expect(Set(every.map(\.id)) == ["running", "stopped"])
    }

    @Test("resolveTargets 404s an unknown requested container in strict mode, skips it otherwise")
    func resolveTargetsStrictVsLenient() async throws {
        let client = StatsMockClient(containers: [makeSnapshot(id: "known")])

        let lenient = try await LibpodContainersStatsRoute.resolveTargets(
            client: client, requested: ["gone"], all: false, strict: false)
        #expect(lenient.isEmpty)

        do {
            _ = try await LibpodContainersStatsRoute.resolveTargets(
                client: client, requested: ["gone"], all: false, strict: true)
            Issue.record("expected a 404 for an unknown requested container")
        } catch let abort as Abort {
            #expect(abort.status == .notFound)
        }
    }

    @Test("collectEntries samples running containers and records baselines for the next tick")
    func collectEntriesRecordsBaselines() async throws {
        let running = makeSnapshot(id: "c1", started: Date(timeIntervalSinceNow: -10))
        var baselines: [String: LibpodContainerStats.CPUBaseline] = [:]
        let entries = try await LibpodContainersStatsRoute.collectEntries(
            snapshots: [running], sampler: { _ in makeSample(cpuUsec: 100_000) }, baselines: &baselines)

        #expect(entries.count == 1)
        #expect(entries.first?.CPUNano == 100_000_000)
        #expect(baselines["c1"]?.cpuNano == 100_000_000)
    }

    @Test("collectEntries skips a container that vanished (notFound), propagates other failures")
    func collectEntriesSkipVsPropagate() async throws {
        let running = makeSnapshot(id: "c2")
        var baselines: [String: LibpodContainerStats.CPUBaseline] = [:]

        // Vanished container (notFound) → skipped, podman's skip-on-removal.
        do {
            let entries = try await LibpodContainersStatsRoute.collectEntries(
                snapshots: [running],
                sampler: { _ in throw ClientContainerError.notFound(id: "c2") },
                baselines: &baselines)
            #expect(entries.isEmpty)
            #expect(baselines.isEmpty)
        }

        // Runtime/permission failure → propagated, never an empty success.
        struct Boom: Error {}
        await #expect(throws: (any Error).self) {
            _ = try await LibpodContainersStatsRoute.collectEntries(
                snapshots: [running], sampler: { _ in throw Boom() }, baselines: &baselines)
        }
    }

    @Test("collectEntries emits a zero row for a stopped container in the target set")
    func collectEntriesStopped() async throws {
        let stopped = makeSnapshot(id: "c3", status: .stopped)
        var baselines: [String: LibpodContainerStats.CPUBaseline] = [:]

        let entries = try await LibpodContainersStatsRoute.collectEntries(
            snapshots: [stopped], sampler: { _ in makeSample(cpuUsec: 999) }, baselines: &baselines)

        #expect(entries.count == 1)
        #expect(entries.first?.ContainerID == DockerContainerID.hexId(for: stopped))
        #expect(entries.first?.CPU == 0)
        #expect(entries.first?.UpTime == 0)
        #expect(baselines.isEmpty)
    }

    // MARK: - Route-level error paths

    @Test("unknown explicitly requested container is a 404 before streaming")
    func unknownContainer404() async throws {
        try await withStatsRoute(containers: [makeSnapshot(id: "c1")]) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/stats?containers=nope&stream=false") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("interval < 1 is a 500, matching podman's invalid-interval error")
    func invalidInterval500() async throws {
        try await withStatsRoute(containers: []) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/stats?interval=0") { res async in
                #expect(res.status == .internalServerError)
            }
        }
    }

    @Test("repeated containers= references are all resolved (404 names the missing one)")
    func repeatedContainersParams() async throws {
        try await withStatsRoute(containers: [makeSnapshot(id: "c1")]) { app in
            try await app.testing().test(
                .GET, "/v1.51/libpod/containers/stats?containers=c1&containers=nope&stream=false"
            ) { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("nope"))
            }
        }
    }

    // MARK: - Test plumbing

    private func withStatsRoute(
        containers: [ContainerSnapshot],
        sampler: (@Sendable (String) async throws -> ContainerResource.ContainerStats)? = nil,
        test: (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            try app.register(
                collection: LibpodContainersStatsRoute(
                    client: StatsMockClient(containers: containers), statsSampler: sampler))
            try await test(app)
        }
    }
}

/// Minimal ClientContainerProtocol mock: list filters by running state like
/// ClientContainerService does, getContainer matches by native ID.
private struct StatsMockClient: ClientContainerProtocol {
    let containers: [ContainerSnapshot]

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        showAll ? containers : containers.filter { $0.status == .running }
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        containers.first { $0.id == id }
    }

    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws -> Bool { true }
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
