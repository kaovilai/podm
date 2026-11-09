// SPDX-License-Identifier: Apache-2.0
// Copyright © 2026 the pacman authors.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License. You may obtain a copy
// of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// License for the specific language governing permissions and limitations
// under the License.

import ContainerAPIClient
import Foundation
import Logging
import NIOCore
import Synchronization
import Vapor

// launchd on-demand lifecycle: pacmand must consume zero RAM when idle.
//
// The daemon exits after a grace period with (a) no in-flight requests, (b) no
// streaming response bodies, and (c) no running containers; the client shim
// wakes it again with `launchctl kickstart`. Configuration is
// `PACMAN_IDLE_EXIT_SECS` (default 90; `0` disables the feature entirely).
//
// Correctness constraints and how they are enforced:
//
// * NEVER exit while a container runs. Running containers depend on services
//   that live inside this process:
//   - `PacmanDNSServer` (Sources/pacmand/DNS/) is the in-process UDP DNS
//     server containers use for inter-container name resolution;
//   - `HealthCheckManager` (Sources/pacmand/Utilities/HealthCheckManager.swift)
//     runs HEALTHCHECK probe loops via in-process exec;
//   - `EventBroadcaster`, `ContainerExitCodeStore` waiters and restart-policy
//     handling likewise die with the daemon.
//   The monitor therefore polls the running-container count every 30s and
//   treats every non-zero count (including DNS sidecars, which are served by
//   the embedded DNS server) as "busy". A failed or hung poll counts as
//   "unknown", which also blocks exit — never exit on missing information.
//
// * NEVER exit while a connection is streaming. Plain requests are counted by
//   `IdleExitConnectionMiddleware` from chain entry until the handler returns
//   or throws. Streaming response bodies (docker events, logs -f, attach/exec
//   hijacks, pull/push/load/import progress, build output, stats, wait) are
//   counted at body construction via `Response.Body.idleTracked(...)`, which
//   wraps the body writer so the count stays elevated until a terminal frame
//   (`.end`/`.error`) is written. Vapor's `Response.Body` storage enum is
//   internal (Sources/Vapor/Response/Response+Body.swift), so a middleware
//   cannot detect or wrap an existing streaming body after the fact — that is
//   why stream tracking happens at the construction sites, not in middleware.
//
// * A plain `podman ps` that disconnects must NOT keep the daemon alive. Its
//   request decrements as soon as the handler returns; only bodies that are
//   still actively streaming hold a token.
//
// Known limits (documented here rather than papered over):
// - File-download responses built by `req.fileio.asyncStreamFile` (the tar
//   bodies of `docker save` / `docker export`) are constructed inside Vapor
//   and are not wrapped; a client slowly downloading a very large image for
//   longer than the grace period with zero other activity could observe the
//   daemon exiting mid-download. Local-socket downloads are fast and bounded;
//   accepted for now.
// - A streaming body whose producer dies without ever writing a terminal
//   frame leaks its token and blocks idle-exit indefinitely (safe direction —
//   the daemon stays up). Every known producer writes `.end`/`.error` on all
//   paths (`DockerProgressFrame.pipe`, the events loop, stats `defer`, …).
// - WebSocket upgrades end the HTTP middleware chain at the 101 response;
//   the attach/ws route therefore tracks its socket explicitly via
//   `ws.onClose`.

// MARK: - Configuration

/// Idle-exit configuration parsed from the environment.
///
/// `PACMAN_IDLE_EXIT_SECS` (seconds): how long the daemon must be continuously
/// idle (no requests, no streams, no running containers) before exiting.
/// `0` (or any non-positive value) disables the feature entirely. Absent or
/// unparseable values fall back to the 90s default.
struct IdleExitConfiguration: Sendable, Equatable {
    static let defaultGrace: Duration = .seconds(90)

    /// Grace period of continuous idleness before exit. `.zero` disables.
    var grace: Duration

    static let `default` = IdleExitConfiguration(grace: defaultGrace)

    var isEnabled: Bool { grace > .zero }

    /// Pure parse from an environment mapping so tests need not mutate the
    /// real process environment.
    ///
    /// Default when PACMAN_IDLE_EXIT_SECS is absent: enabled (90s) under
    /// launchd (PACMAN_LAUNCHD=1), where something restarts the daemon on
    /// demand; disabled for foreground/dev invocations (`pacman serve`, a bare
    /// `pacmand &`, CI nohup starts), where an unprompted exit would just look
    /// like a crash. Set PACMAN_IDLE_EXIT_SECS explicitly to override either
    /// way.
    static func fromEnvironment(_ env: [String: String]) -> IdleExitConfiguration {
        let fallback: IdleExitConfiguration =
            (env["PACMAN_LAUNCHD"] == "1") ? .default : IdleExitConfiguration(grace: .zero)
        guard
            let raw = env["PACMAN_IDLE_EXIT_SECS"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return fallback
        }
        guard let seconds = Double(raw) else {
            return fallback
        }
        guard seconds > 0 else {
            return IdleExitConfiguration(grace: .zero)
        }
        // Duration's .seconds factory is integer-only; go through
        // milliseconds so fractional values ("90.5") keep sub-second
        // precision.
        let graceMs = Int64((seconds * 1000).rounded())
        return IdleExitConfiguration(grace: .milliseconds(graceMs))
    }
}

// MARK: - Snapshot & decision

/// Point-in-time view of the activity the idle-exit decision depends on.
/// `runningContainers == nil` means "unknown" (startup, failed or timed-out
/// poll) and is treated as busy.
struct IdleExitSnapshot: Sendable, Equatable {
    var inFlightRequests: Int
    var activeStreams: Int
    var runningContainers: Int?
}

/// The idle-exit decision for one state-machine update.
enum IdleExitDecision: Equatable, Sendable {
    /// Some activity is present, the feature is disabled, or exit already fired.
    case active
    /// Idle, but within the grace period. Associated value: idle duration so far.
    case idle(elapsed: Duration)
    /// Idle for the full grace period. Returned exactly once.
    case exitNow
}

// MARK: - State machine

/// Pure idle-exit decision logic, kept free of I/O and clocks so it can be
/// unit-tested with synthetic instants. Fed snapshots in time order via
/// `update`; owns the "idle since" timestamp and the fired-once latch.
struct IdleExitStateMachine: Sendable {
    let grace: Duration
    private(set) var idleSince: ContinuousClock.Instant?
    private(set) var hasExited: Bool

    init(grace: Duration) {
        self.grace = grace
        self.idleSince = nil
        self.hasExited = false
    }

    mutating func update(
        _ snapshot: IdleExitSnapshot,
        now: ContinuousClock.Instant
    ) -> IdleExitDecision {
        // Disabled (grace <= .zero, i.e. PACMAN_IDLE_EXIT_SECS=0) or already
        // fired: never idle-exit.
        guard !hasExited, grace > .zero else { return .active }

        // Unknown running-container count is treated as "not idle": never
        // exit on missing information.
        let runningContainers = snapshot.runningContainers ?? 1
        let idle =
            snapshot.inFlightRequests == 0
            && snapshot.activeStreams == 0
            && runningContainers == 0

        guard idle else {
            idleSince = nil
            return .active
        }
        guard let since = idleSince else {
            idleSince = now
            return .idle(elapsed: .zero)
        }
        let elapsed = now - since
        guard elapsed >= grace else { return .idle(elapsed: elapsed) }
        hasExited = true
        return .exitNow
    }

    /// Cancel a fired-but-aborted exit: the pre-shutdown fresh poll in
    /// `IdleExitMonitor.step()` can discover running containers after the
    /// state machine already latched `hasExited`. Re-arm so a later genuine
    /// idle period can still fire.
    mutating func rearm() {
        hasExited = false
    }
}

// MARK: - Counters

/// Opaque handle for one tracked streaming body. Ending it is idempotent, so
/// the body-closure completion and the terminal-write path can both call
/// `endStream` for the same token safely.
struct IdleStreamToken: Sendable, Equatable {
    let id: UInt64
}

/// Process-wide activity counters backing the idle-exit decision.
///
/// Three producers feed it:
/// - `IdleExitConnectionMiddleware` counts every in-flight request;
/// - `Response.Body.idleTracked(...)` counts streaming response bodies from
///   construction until a terminal frame flows through the wrapped writer;
/// - the monitor's container poller caches the running-container count.
final class IdleActivityCounters: Sendable {
    static let shared = IdleActivityCounters()

    private struct State: Sendable {
        var inFlightRequests = 0
        var activeStreamIDs: Set<UInt64> = []
        var nextStreamID: UInt64 = 1
        /// Cached running-container count. `nil` = unknown, blocks exit.
        var runningContainerCount: Int? = nil
    }

    private let state = Mutex(State())

    // MARK: Requests

    func beginRequest() {
        state.withLock { $0.inFlightRequests += 1 }
    }

    func endRequest() {
        state.withLock { $0.inFlightRequests = max($0.inFlightRequests - 1, 0) }
    }

    // MARK: Streams

    func beginStream() -> IdleStreamToken {
        let id = state.withLock { state -> UInt64 in
            let id = state.nextStreamID
            state.nextStreamID += 1
            state.activeStreamIDs.insert(id)
            return id
        }
        return IdleStreamToken(id: id)
    }

    /// Idempotent: ending an already-ended (or unknown) token is a no-op.
    func endStream(_ token: IdleStreamToken) {
        state.withLock { _ = $0.activeStreamIDs.remove(token.id) }
    }

    // MARK: Running containers

    func setRunningContainers(_ count: Int) {
        precondition(count >= 0, "running-container count must not be negative")
        state.withLock { $0.runningContainerCount = count }
    }

    func markRunningContainersUnknown() {
        state.withLock { $0.runningContainerCount = nil }
    }

    // MARK: Snapshot

    func snapshot() -> IdleExitSnapshot {
        state.withLock { state in
            IdleExitSnapshot(
                inFlightRequests: state.inFlightRequests,
                activeStreams: state.activeStreamIDs.count,
                runningContainers: state.runningContainerCount
            )
        }
    }
}

// MARK: - Clock

/// Injectable monotonic clock so tests drive time manually instead of sleeping.
protocol IdleExitClock: Sendable {
    func now() -> ContinuousClock.Instant
}

/// Production clock: `ContinuousClock` is monotonic, so wall-clock changes
/// (NTP steps, timezone changes) cannot fake or extend idleness.
struct SystemIdleExitClock: IdleExitClock {
    private let clock = ContinuousClock()

    func now() -> ContinuousClock.Instant {
        clock.now
    }
}

// MARK: - Monitor

struct IdleExitMonitorKey: StorageKey {
    typealias Value = IdleExitMonitor
}

/// Drives the idle-exit loop: refreshes the running-container count on its
/// poll interval, evaluates the state machine on every tick, and invokes
/// `onExit` exactly once when the grace period lapses.
///
/// `step()` performs one iteration and is internal so unit tests can drive it
/// with a manual clock instead of real sleeps; `start()` merely loops it.
final class IdleExitMonitor: Sendable {
    private let configuration: IdleExitConfiguration
    private let counters: IdleActivityCounters
    private let clock: any IdleExitClock
    private let runningContainersProvider: @Sendable () async -> Int?
    private let tickInterval: Duration
    private let containerPollInterval: Duration
    private let logger: Logger
    private let onExit: @Sendable () -> Void

    private struct LoopState: Sendable {
        var machine: IdleExitStateMachine
        var lastContainerPoll: ContinuousClock.Instant?
    }

    private let loopState: Mutex<LoopState>

    init(
        configuration: IdleExitConfiguration,
        counters: IdleActivityCounters,
        clock: any IdleExitClock = SystemIdleExitClock(),
        runningContainersProvider: @escaping @Sendable () async -> Int?,
        tickInterval: Duration = .seconds(5),
        containerPollInterval: Duration = .seconds(30),
        logger: Logger = Logger(label: "pacman.idleexit"),
        onExit: @escaping @Sendable () -> Void
    ) {
        self.configuration = configuration
        self.counters = counters
        self.clock = clock
        self.runningContainersProvider = runningContainersProvider
        self.tickInterval = tickInterval
        self.containerPollInterval = containerPollInterval
        self.logger = logger
        self.onExit = onExit
        self.loopState = Mutex(
            LoopState(
                machine: IdleExitStateMachine(grace: configuration.grace),
                lastContainerPoll: nil
            )
        )
    }

    /// Spawns the monitor loop. No-op when the feature is disabled.
    func start() {
        guard configuration.isEnabled else { return }
        // Tick no slower than the configured interval, and no slower than a
        // quarter of the grace period, so the exit fires close to the
        // deadline even for very short configured graces.
        let tick = min(tickInterval, configuration.grace / 4)
        Task { [self] in
            while !Task.isCancelled {
                if await self.step() == .exitNow { return }
                try? await Task.sleep(for: tick)
            }
        }
    }

    /// One loop iteration: refresh the running-container count if due, then
    /// evaluate the state machine against the current counters. Invokes
    /// `onExit` exactly once, on the `.exitNow` tick. Returns the decision so
    /// the loop (and tests) can observe it.
    func step() async -> IdleExitDecision {
        let now = clock.now()

        let pollDue = loopState.withLock { state -> Bool in
            guard let lastPoll = state.lastContainerPoll else { return true }
            return now - lastPoll >= containerPollInterval
        }
        if pollDue {
            if let count = await runningContainersProvider() {
                counters.setRunningContainers(count)
            } else {
                counters.markRunningContainersUnknown()
            }
            loopState.withLock { $0.lastContainerPoll = now }
        }

        let snapshot = counters.snapshot()
        let decision = loopState.withLock { $0.machine.update(snapshot, now: now) }
        switch decision {
        case .active:
            break
        case .idle(let elapsed):
            logger.debug(
                "idle-exit: idle \(elapsed) of \(configuration.grace) (requests=\(snapshot.inFlightRequests), streams=\(snapshot.activeStreams), runningContainers=\(String(describing: snapshot.runningContainers)))"
            )
        case .exitNow:
            // The grace elapsed against possibly-stale inputs: the
            // running-container count is cached on a 30s cadence, so a
            // `docker run -d` that began just before the deadline would not
            // be seen by the cached value (tick-race). Re-poll fresh before
            // shutting down — bounded by the provider itself — and abort the
            // exit if anything is running now or the count is unknown.
            let fresh = await runningContainersProvider()
            if fresh == 0 {
                logger.info(
                    "idle-exit: no client connections and no running containers for \(configuration.grace) — shutting down (launchd restarts on demand)"
                )
                onExit()
            } else {
                if let fresh {
                    counters.setRunningContainers(fresh)
                } else {
                    counters.markRunningContainersUnknown()
                }
                // The machine latched hasExited when it returned .exitNow —
                // re-arm so a later genuine idle period can still fire, then
                // recompute against the fresh counters.
                let revised = loopState.withLock {
                    $0.machine.rearm()
                    return $0.machine.update(counters.snapshot(), now: now)
                }
                logger.info(
                    "idle-exit: aborted exit — fresh poll found \(String(describing: fresh)) running container(s)"
                )
                return revised
            }
        }
        return decision
    }
}

// MARK: - Running-container poller

/// Default running-container provider for `IdleExitMonitor`: polls Apple
/// Container over XPC.
///
/// - A fresh `ContainerClient` per poll. A long-held XPC connection goes
///   permanently stale when `com.apple.container.apiserver` restarts (see
///   `ReconnectingContainerClient`); rebuilding every 30s costs one XPC
///   connection and sidesteps that whole class of staleness bugs.
/// - Counts containers in `.running` OR `.stopping` state — a stopping
///   container's VM is still alive and its teardown may still be in flight.
///   DNS sidecars are deliberately INCLUDED: this daemon hosts the
///   inter-container DNS server (`PacmanDNSServer`) and the healthcheck
///   executor (`HealthCheckManager`) in-process, so any running container —
///   user workload or sidecar — depends on pacmand staying alive. This is the
///   "never exit while a container runs" guarantee.
/// - Bounded by a 10s deadline: XPC calls can hang indefinitely when the
///   runtime is wedged (apple/container#1884) and task cancellation cannot
///   interrupt them (see `StartupHousekeeping.runBounded`). A timed-out or
///   failed poll reports `nil` (unknown), which blocks idle-exit.
func defaultRunningContainersProvider(logger: Logger) -> @Sendable () async -> Int? {
    { @Sendable in
        let result = Mutex<Int?>(nil)
        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(10)) {
            let containers = try? await ContainerClient().list()
            result.withLock {
                $0 =
                    containers?
                    .filter { $0.status == .running || $0.status == .stopping }
                    .count
            }
        }
        if !finished {
            logger.warning(
                "idle-exit: running-container poll timed out; treating count as unknown"
            )
        }
        return result.withLock { $0 }
    }
}

// MARK: - Request counting middleware

/// Counts in-flight requests for the idle-exit monitor.
///
/// Limits: the middleware's view of a request ends when the handler RETURNS a
/// response (or throws). A streaming body outlives that return, which is why
/// streams are tracked at body construction via `Response.Body.idleTracked`
/// with wrapped writers instead of here; WebSocket upgrades are tracked at
/// their route via `ws.onClose`.
struct IdleExitConnectionMiddleware: AsyncMiddleware {
    let counters: IdleActivityCounters

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        counters.beginRequest()
        do {
            let response = try await next.respond(to: request)
            counters.endRequest()
            return response
        } catch {
            counters.endRequest()
            throw error
        }
    }
}

// MARK: - Stream counting

extension BodyStreamResult {
    /// `.end` and `.error` are terminal: once one of them is written, the
    /// response body stream is finished.
    var isTerminal: Bool {
        switch self {
        case .end, .error: return true
        default: return false
        }
    }
}

/// Forwards writes to the real writer and releases the idle-exit stream token
/// when a terminal frame flows through. Used for `Response.Body(stream:)`
/// bodies whose callbacks typically spawn detached tasks and return early —
/// the token must live until the LAST write, not until the callback returns.
private struct IdleTrackedBodyStreamWriter: BodyStreamWriter {
    let upstream: BodyStreamWriter
    let counters: IdleActivityCounters
    let token: IdleStreamToken

    var eventLoop: EventLoop { upstream.eventLoop }

    func write(_ result: BodyStreamResult, promise: EventLoopPromise<Void>?) {
        if result.isTerminal { counters.endStream(token) }
        upstream.write(result, promise: promise)
    }
}

/// Async counterpart for `Response.Body(asyncStream:)` bodies.
private struct IdleTrackedAsyncBodyStreamWriter: AsyncBodyStreamWriter {
    let upstream: AsyncBodyStreamWriter
    let counters: IdleActivityCounters
    let token: IdleStreamToken

    func write(_ result: BodyStreamResult) async throws {
        if result.isTerminal { counters.endStream(token) }
        try await upstream.write(result)
    }
}

extension Response.Body {
    /// `Response.Body(stream:)` variant that keeps the idle-exit "active
    /// stream" count elevated until the body finishes.
    ///
    /// The wrapped writer releases the token on the first terminal frame
    /// (`.end` / `.error`), so detached-task producers (pull/push/load/import
    /// progress, attach/exec hijacks) are tracked for their full lifetime, not
    /// just until the body callback returns. Token release is idempotent.
    ///
    /// If the producer dies without writing a terminal frame the token leaks
    /// and blocks idle-exit (safe direction — the daemon stays up); every
    /// known producer writes one on all paths.
    static func idleTracked(
        counters: IdleActivityCounters = .shared,
        stream: @escaping @Sendable (BodyStreamWriter) -> Void
    ) -> Response.Body {
        .init(stream: { writer in
            let token = counters.beginStream()
            stream(IdleTrackedBodyStreamWriter(upstream: writer, counters: counters, token: token))
        })
    }

    /// `Response.Body(asyncStream:)` variant with the same tracking. Belt and
    /// braces: the token is released by whichever happens first — the closure
    /// completing/throwing or a terminal frame through the wrapped writer.
    static func idleTracked(
        counters: IdleActivityCounters = .shared,
        asyncStream: @escaping @Sendable (AsyncBodyStreamWriter) async throws -> Void
    ) -> Response.Body {
        .init(asyncStream: { writer in
            let token = counters.beginStream()
            do {
                try await asyncStream(
                    IdleTrackedAsyncBodyStreamWriter(upstream: writer, counters: counters, token: token))
            } catch {
                counters.endStream(token)
                throw error
            }
            counters.endStream(token)
        })
    }
}
