// SPDX-License-Identifier: Apache-2.0
import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor

// MARK: - libpod stats wire models

/// podman's `entities.ContainerStatsReport` (pkg/domain/entities/types/containers.go) —
/// the top-level object this endpoint streams. The Go struct carries no json
/// tags, so Go's encoder emits the declared field names (`Error`, `Stats`) and
/// a nil `error` marshals as JSON `null`. `encode(to:)` is hand-written to keep
/// that exact `"Error":null` shape (Swift's synthesized optional encoding
/// would omit the key; Go clients decode both identically, but byte-fidelity
/// costs nothing here).
struct LibpodContainerStatsReport: Content {
    /// In-band report error. Always nil on this route's wire: failures before
    /// the stream starts become HTTP errors (404/500), matching podman's
    /// pre-stream ContainerNotFound path, and per-container sampling failures
    /// mid-stream skip that container rather than aborting the report.
    let Error: String?
    let Stats: [LibpodContainerStats]

    enum CodingKeys: String, CodingKey {
        case Error
        case Stats
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let error = Error {
            try container.encode(error, forKey: .Error)
        } else {
            try container.encodeNil(forKey: .Error)
        }
        try container.encode(Stats, forKey: .Stats)
    }
}

/// podman's `define.ContainerStats` (libpod/define/containerstate.go) — one
/// container's pre-computed stats row. No json tags in Go either, so the Swift
/// property names mirror the Go field names verbatim; podman's remote client
/// (and its Go decoders) expect these exact keys. The string forms
/// ("0.15%", "12.3MB / 1GB") that `podman stats` prints are derived
/// client-side from these numbers, never sent over the wire.
struct LibpodContainerStats: Content {
    let AvgCPU: Double
    let ContainerID: String
    let Name: String
    let CPU: Double
    let CPUNano: UInt64
    /// Kernel-mode CPU time. Apple Container reports no user/kernel split, so
    /// this is an honest 0 (the Docker-compat stats route reports the same
    /// gap in its cpu_usage fields).
    let CPUSystemNano: UInt64
    let SystemNano: UInt64
    let MemUsage: UInt64
    let MemLimit: UInt64
    let MemPerc: Double
    let Network: [String: LibpodContainerNetworkStats]?
    let BlockInput: UInt64
    let BlockOutput: UInt64
    let PIDs: UInt64
    /// podman sets this to the container's total CPU usage (cgroup
    /// total_usage) — `podman stats` prints it under the "CPU TIME" column;
    /// it is not wall-clock uptime.
    let UpTime: Int64
    /// Also the container's total CPU usage in podman (not the sampling
    /// interval); kept identical for wire fidelity.
    let Duration: UInt64
}

/// podman's `define.ContainerNetworkStats`, mapped by interface name in
/// `Network`. Apple Container reports aggregate rx/tx bytes only, so packet
/// and error counters are honest zeros (the Docker-compat route does the
/// same under `networks.eth0`).
struct LibpodContainerNetworkStats: Content {
    let RxBytes: UInt64
    let RxDropped: UInt64
    let RxErrors: UInt64
    let RxPackets: UInt64
    let TxBytes: UInt64
    let TxDropped: UInt64
    let TxErrors: UInt64
    let TxPackets: UInt64
}

// MARK: - Builders

extension LibpodContainerStats {
    /// Previous-sample CPU baseline for delta math, carried across sampling
    /// ticks the same way podman keeps its `containerStats` map in
    /// `abi.ContainerStats`.
    struct CPUBaseline: Sendable, Equatable {
        let cpuNano: UInt64
        let systemNano: UInt64
    }

    /// Wall-clock nanoseconds since the Unix epoch (podman's SystemNano is
    /// `time.Now().UnixNano()`).
    static func wallClockNano(_ date: Date) -> UInt64 {
        UInt64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
    }

    /// podman's `calculateCPUPercent` (libpod/stats_linux.go): container CPU
    /// time delta over wall-clock delta × 100 — not divided by core count, so
    /// a container using two full cores reports 200%.
    static func cpuPercent(
        currCPUNano: UInt64, prevCPUNano: UInt64,
        currSystemNano: UInt64, prevSystemNano: UInt64
    ) -> Double {
        guard currSystemNano > prevSystemNano, currCPUNano > prevCPUNano else { return 0 }
        let cpuDelta = Double(currCPUNano - prevCPUNano)
        let systemDelta = Double(currSystemNano - prevSystemNano)
        return (cpuDelta / systemDelta) * 100
    }

    /// Builds one stats row from an Apple Container sample. With no baseline
    /// (first tick) podman seeds the previous sample with the container's
    /// start time and zero CPU, so the first report's CPU% is the average
    /// since start — `podman stats` shows meaningful numbers immediately.
    static func build(
        snapshot: ContainerSnapshot,
        sample: ContainerResource.ContainerStats,
        baseline: CPUBaseline?,
        now: Date
    ) -> LibpodContainerStats {
        let nowNano = wallClockNano(now)
        let cpuNano = (sample.cpuUsageUsec ?? 0) * 1000
        let startedNano = snapshot.startedDate.map { wallClockNano($0) }

        // A shrinking CPU total means the container restarted under fresh
        // accounting; podman resets the whole baseline (prev CPU and prev
        // system time both to zero).
        var prev = baseline ?? CPUBaseline(cpuNano: 0, systemNano: startedNano ?? nowNano)
        if prev.cpuNano > cpuNano {
            prev = CPUBaseline(cpuNano: 0, systemNano: 0)
        }

        let avgCPU: Double
        if let startedNano {
            avgCPU = cpuPercent(currCPUNano: cpuNano, prevCPUNano: 0, currSystemNano: nowNano, prevSystemNano: startedNano)
        } else {
            avgCPU = 0
        }

        let memUsage = sample.memoryUsageBytes ?? 0
        let memLimit = sample.memoryLimitBytes ?? hostPhysicalMemory()
        let memPerc = memLimit > 0 ? (Double(memUsage) / Double(memLimit)) * 100 : 0

        let network: [String: LibpodContainerNetworkStats]?
        if sample.networkRxBytes != nil || sample.networkTxBytes != nil {
            network = [
                "eth0": LibpodContainerNetworkStats(
                    RxBytes: sample.networkRxBytes ?? 0,
                    RxDropped: 0,
                    RxErrors: 0,
                    RxPackets: 0,
                    TxBytes: sample.networkTxBytes ?? 0,
                    TxDropped: 0,
                    TxErrors: 0,
                    TxPackets: 0
                )
            ]
        } else {
            network = nil
        }

        return LibpodContainerStats(
            AvgCPU: avgCPU,
            ContainerID: DockerContainerID.hexId(for: snapshot),
            Name: snapshot.id,
            CPU: cpuPercent(currCPUNano: cpuNano, prevCPUNano: prev.cpuNano, currSystemNano: nowNano, prevSystemNano: prev.systemNano),
            CPUNano: cpuNano,
            CPUSystemNano: 0,
            SystemNano: nowNano,
            MemUsage: memUsage,
            MemLimit: memLimit,
            MemPerc: memPerc,
            Network: network,
            BlockInput: sample.blockReadBytes ?? 0,
            BlockOutput: sample.blockWriteBytes ?? 0,
            PIDs: sample.numProcesses ?? 0,
            UpTime: Int64(clamping: cpuNano),
            Duration: cpuNano
        )
    }

    /// Zero-value row for a non-running container in the target set — podman's
    /// `GetContainerStats` returns early with only ContainerID and Name set
    /// when the container isn't running (reached via all=true or an explicit
    /// containers= reference; the default target set is running-only).
    static func stopped(id: String, name: String) -> LibpodContainerStats {
        LibpodContainerStats(
            AvgCPU: 0,
            ContainerID: id,
            Name: name,
            CPU: 0,
            CPUNano: 0,
            CPUSystemNano: 0,
            SystemNano: 0,
            MemUsage: 0,
            MemLimit: 0,
            MemPerc: 0,
            Network: nil,
            BlockInput: 0,
            BlockOutput: 0,
            PIDs: 0,
            UpTime: 0,
            Duration: 0
        )
    }
}

// MARK: - Route

/// GET /libpod/containers/stats — podman's all-container stats endpoint,
/// consumed by `podman stats` (no args) through the remote client. Distinct
/// from the deprecated per-container `/libpod/containers/{name}/stats`, which
/// reuses the Docker-compat handler: this endpoint speaks libpod's own
/// pre-computed ContainerStats schema and streams one
/// `entities.ContainerStatsReport` per interval as newline-delimited JSON
/// (matching podman's json.Encoder output), or a single report for
/// stream=false.
struct LibpodContainersStatsRoute: RouteCollection {
    let client: ClientContainerProtocol
    /// Samples Apple Container resource stats for a native container ID.
    /// Injectable so tests can drive the route without the container runtime.
    let statsSampler: (@Sendable (String) async throws -> ContainerResource.ContainerStats)?

    init(
        client: ClientContainerProtocol,
        statsSampler: (@Sendable (String) async throws -> ContainerResource.ContainerStats)? = nil
    ) {
        self.client = client
        self.statsSampler = statsSampler
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/libpod/containers/stats",
            use: Self.handler(client: client, statsSampler: statsSampler))
    }

    static func handler(
        client: ClientContainerProtocol,
        statsSampler: (@Sendable (String) async throws -> ContainerResource.ContainerStats)? = nil
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            // podman's defaults (pkg/api/handlers/libpod/containers_stats.go):
            // stream=true, interval=5s, running containers only unless all=true.
            let stream = MobyBool.queryValue(req.query["stream"] as String?, defaultingTo: true)
            let all = MobyBool.queryValue(req.query["all"] as String?, defaultingTo: false)
            let interval = req.query[Int.self, at: "interval"] ?? 5
            guard interval >= 1 else {
                throw Abort(
                    .internalServerError,
                    reason: "invalid interval, must be a positive number greater zero")
            }
            let requested = Self.requestedContainers(req)

            // Resolve targets before streaming so an unknown explicitly
            // requested container fails with 404 up front, like podman's
            // GetContainersByList error path.
            let initial = try await Self.resolveTargets(client: client, requested: requested, all: all, strict: true)

            // One Apple Container client per request, shared by every sample —
            // same lifetime as the Docker-compat stats route's client.
            let statsClient = ContainerClient()
            let sampler: @Sendable (String) async throws -> ContainerResource.ContainerStats =
                statsSampler ?? { try await statsClient.stats(id: $0) }

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")

            // asyncStream variant of idleTracked (like /events): the sync
            // writer used by the Docker-compat stats route cannot observe
            // client disconnects, but `try await writer.write` throws once the
            // connection is gone, ending the loop and releasing the idle-exit
            // activity token within one interval.
            let body = Response.Body.idleTracked(asyncStream: { writer in
                do {
                    var snapshots = initial
                    var baselines: [String: LibpodContainerStats.CPUBaseline] = [:]
                    while true {
                        let entries = await Self.collectEntries(
                            snapshots: snapshots, sampler: sampler, baselines: &baselines)
                        let report = LibpodContainerStatsReport(Error: nil, Stats: entries)
                        if let data = try? JSONEncoder().encode(report) {
                            var buf = sharedAllocator.buffer(capacity: data.count + 1)
                            buf.writeBytes(data)
                            buf.writeString("\n")
                            try await writer.write(.buffer(buf))
                        }
                        if !stream { break }
                        try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                        // Re-resolve the target set each tick — containers may
                        // start or stop while the stream is open (podman
                        // re-lists every interval too). Best-effort: on
                        // failure keep the previous set.
                        if let refreshed = try? await Self.resolveTargets(
                            client: client, requested: requested, all: all, strict: false)
                        {
                            snapshots = refreshed
                        }
                    }
                    _ = try? await writer.write(.end)
                } catch {
                    // Client disconnected (write threw) or the task was
                    // cancelled — idleTracked releases its token on throw.
                }
            })

            return Response(status: .ok, headers: headers, body: body)
        }
    }

    /// Parses the repeatable `containers` query parameter
    /// (`containers=a&containers=b`, as podman's remote client sends it).
    /// Vapor's typed query subscripts surface only one value for repeated
    /// keys, so this walks the raw query string.
    static func requestedContainers(_ req: Request) -> [String] {
        guard let query = req.url.query, !query.isEmpty else { return [] }
        var requested: [String] = []
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "containers" else { continue }
            let raw = String(parts[1]).replacingOccurrences(of: "+", with: " ")
            let value = raw.removingPercentEncoding ?? raw
            if !value.isEmpty { requested.append(value) }
        }
        return requested
    }

    /// Resolves the target container set. Explicitly named containers are
    /// included regardless of state; an unknown name is a hard 404 before any
    /// bytes are streamed (strict=true). Mid-stream re-resolution
    /// (strict=false) skips names that vanished instead, mirroring podman's
    /// skip-on-removal behavior. With no names, running containers are the
    /// default target set and all=true widens it to every container.
    static func resolveTargets(
        client: ClientContainerProtocol,
        requested: [String],
        all: Bool,
        strict: Bool
    ) async throws -> [ContainerSnapshot] {
        guard !requested.isEmpty else {
            return try await client.list(showAll: all, filters: [:])
        }
        var resolved: [ContainerSnapshot] = []
        for reference in requested {
            if let snapshot = try await client.getContainer(id: reference) {
                resolved.append(snapshot)
            } else if strict {
                throw Abort(.notFound, reason: "No such container: \(reference)")
            }
        }
        return resolved
    }

    /// Samples every target container once and folds the results into report
    /// rows, updating `baselines` for the next tick's CPU deltas.
    static func collectEntries(
        snapshots: [ContainerSnapshot],
        sampler: @Sendable (String) async throws -> ContainerResource.ContainerStats,
        baselines: inout [String: LibpodContainerStats.CPUBaseline]
    ) async -> [LibpodContainerStats] {
        let now = Date()
        var entries: [LibpodContainerStats] = []
        for snapshot in snapshots {
            guard snapshot.status == .running else {
                entries.append(
                    LibpodContainerStats.stopped(
                        id: DockerContainerID.hexId(for: snapshot), name: snapshot.id))
                continue
            }
            do {
                let sample = try await sampler(snapshot.id)
                entries.append(
                    LibpodContainerStats.build(
                        snapshot: snapshot, sample: sample,
                        baseline: baselines[snapshot.id], now: now))
                baselines[snapshot.id] = LibpodContainerStats.CPUBaseline(
                    cpuNano: (sample.cpuUsageUsec ?? 0) * 1000,
                    systemNano: LibpodContainerStats.wallClockNano(now))
            } catch {
                // Stats unavailable — the container most likely exited between
                // listing and sampling. podman skips such containers in its
                // query-all path; keep the previous baseline so the next
                // successful sample still yields a real delta.
            }
        }
        return entries
    }
}
