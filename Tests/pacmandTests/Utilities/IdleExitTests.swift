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

import Logging
import Synchronization
import Testing

@testable import pacmand

@Suite("IdleExit")
struct IdleExitTests {

    // MARK: - Helpers

    private func snapshot(
        requests: Int = 0,
        streams: Int = 0,
        containers: Int? = 0
    ) -> IdleExitSnapshot {
        IdleExitSnapshot(
            inFlightRequests: requests, activeStreams: streams, runningContainers: containers)
    }

    /// Monotonic clock the test advances by hand.
    private final class ManualClock: IdleExitClock, Sendable {
        private let current = Mutex(ContinuousClock().now)

        func now() -> ContinuousClock.Instant {
            current.withLock { $0 }
        }

        func advance(by duration: Duration) {
            current.withLock { $0 += duration }
        }
    }

    /// Sendable counter for observing provider/onExit invocations from
    /// @Sendable closures.
    private final class AtomicCounter: Sendable {
        private let value = Mutex(0)

        func increment() {
            value.withLock { $0 += 1 }
        }

        var current: Int {
            value.withLock { $0 }
        }
    }

    // MARK: - Configuration

    @Test("default grace is 90 seconds under launchd (PACMAN_LAUNCHD=1) when the env var is absent")
    func configurationDefault() {
        let config = IdleExitConfiguration.fromEnvironment(["PACMAN_LAUNCHD": "1"])
        #expect(config == .default)
        #expect(config.grace == .seconds(90))
        #expect(config.isEnabled)
    }

    @Test("idle-exit is disabled by default outside launchd (foreground/dev/CI starts)")
    func configurationDefaultForegroundDisabled() {
        let config = IdleExitConfiguration.fromEnvironment([:])
        #expect(config.grace == .zero)
        #expect(!config.isEnabled)
    }

    @Test("PACMAN_LAUNCHD only matters when PACMAN_IDLE_EXIT_SECS is absent")
    func configurationExplicitOverridesLaunchd() {
        let config = IdleExitConfiguration.fromEnvironment(["PACMAN_LAUNCHD": "0", "PACMAN_IDLE_EXIT_SECS": "45"])
        #expect(config.grace == .seconds(45))
        #expect(config.isEnabled)
    }

    @Test("PACMAN_IDLE_EXIT_SECS=0 disables the feature entirely")
    func configurationZeroDisables() {
        let config = IdleExitConfiguration.fromEnvironment(["PACMAN_IDLE_EXIT_SECS": "0"])
        #expect(config.grace == .zero)
        #expect(!config.isEnabled)
    }

    @Test("negative values also disable")
    func configurationNegativeDisables() {
        let config = IdleExitConfiguration.fromEnvironment(["PACMAN_IDLE_EXIT_SECS": "-5"])
        #expect(!config.isEnabled)
    }

    @Test("custom grace is parsed")
    func configurationCustomGrace() {
        let config = IdleExitConfiguration.fromEnvironment(["PACMAN_IDLE_EXIT_SECS": "45"])
        #expect(config.grace == .seconds(45))
        #expect(config.isEnabled)
    }

    @Test("absent, empty, whitespace, and unparseable values fall back to the launchd-aware default")
    func configurationInvalidFallsBack() {
        for launchd in ["0", "1"] {
            for raw in [nil, "", "   ", "abc", "1.2.3"] {
                var env: [String: String] = ["PACMAN_LAUNCHD": launchd]
                if let raw {
                    env["PACMAN_IDLE_EXIT_SECS"] = raw
                }
                #expect(
                    IdleExitConfiguration.fromEnvironment(env)
                        == (launchd == "1" ? .default : IdleExitConfiguration(grace: .zero)))
            }
        }
    }

    // MARK: - State machine

    @Test("busy while a request is in flight, idle only once it finishes")
    func activeWhileRequestsInFlight() {
        var machine = IdleExitStateMachine(grace: .seconds(90))
        let t0 = ContinuousClock().now

        #expect(machine.update(snapshot(requests: 1), now: t0) == .active)
        #expect(machine.update(snapshot(requests: 1), now: t0 + .seconds(1000)) == .active)

        // Request finishes: grace window starts now, not at t0.
        #expect(machine.update(snapshot(), now: t0 + .seconds(1000)) == .idle(elapsed: .zero))
        #expect(
            machine.update(snapshot(), now: t0 + .seconds(1089)) == .idle(elapsed: .seconds(89)))
        #expect(machine.update(snapshot(), now: t0 + .seconds(1090)) == .exitNow)
    }

    @Test("busy while a stream is open")
    func activeWhileStreamsOpen() {
        var machine = IdleExitStateMachine(grace: .seconds(10))
        let t0 = ContinuousClock().now

        #expect(machine.update(snapshot(streams: 1), now: t0) == .active)
        #expect(machine.update(snapshot(streams: 2), now: t0 + .seconds(60)) == .active)
    }

    @Test("busy while containers are running — the daemon hosts their DNS and healthchecks")
    func activeWhileContainersRunning() {
        var machine = IdleExitStateMachine(grace: .seconds(10))
        let t0 = ContinuousClock().now

        #expect(machine.update(snapshot(containers: 1), now: t0) == .active)
        #expect(machine.update(snapshot(containers: 3), now: t0 + .seconds(60)) == .active)
        // DNS sidecars count as running containers too (containers: nil means
        // unknown, covered separately below).
    }

    @Test("unknown container count (failed or hung poll) blocks exit")
    func unknownContainersBlockExit() {
        var machine = IdleExitStateMachine(grace: .seconds(10))
        let t0 = ContinuousClock().now

        // A fresh counters instance reports nil until the first poll lands —
        // the startup-safety property: never exit before knowing the state.
        #expect(IdleActivityCounters().snapshot().runningContainers == nil)

        #expect(machine.update(snapshot(containers: nil), now: t0) == .active)
        #expect(machine.update(snapshot(containers: nil), now: t0 + .seconds(1000)) == .active)
    }

    @Test("exit fires exactly once")
    func exitFiresOnce() {
        var machine = IdleExitStateMachine(grace: .seconds(5))
        let t0 = ContinuousClock().now

        #expect(machine.update(snapshot(), now: t0) == .idle(elapsed: .zero))
        #expect(machine.update(snapshot(), now: t0 + .seconds(5)) == .exitNow)
        #expect(machine.update(snapshot(), now: t0 + .seconds(50)) == .active)
    }

    @Test("new activity resets the grace window")
    func activityResetsGrace() {
        var machine = IdleExitStateMachine(grace: .seconds(90))
        let t0 = ContinuousClock().now

        // Idle from t0…
        #expect(machine.update(snapshot(), now: t0) == .idle(elapsed: .zero))
        #expect(machine.update(snapshot(), now: t0 + .seconds(50)) == .idle(elapsed: .seconds(50)))

        // …a request arrives at t0+60, cancelling the window…
        #expect(machine.update(snapshot(requests: 1), now: t0 + .seconds(60)) == .active)

        // …idle again from t0+60: the earlier 50s of idleness must not count.
        #expect(machine.update(snapshot(), now: t0 + .seconds(60)) == .idle(elapsed: .zero))
        #expect(
            machine.update(snapshot(), now: t0 + .seconds(149)) == .idle(elapsed: .seconds(89)))
        #expect(machine.update(snapshot(), now: t0 + .seconds(150)) == .exitNow)
    }

    @Test("idle just short of the grace period does not exit")
    func partialGraceDoesNotExit() {
        var machine = IdleExitStateMachine(grace: .seconds(90))
        let t0 = ContinuousClock().now

        machine.update(snapshot(), now: t0)
        #expect(
            machine.update(snapshot(), now: t0 + .seconds(89)) == .idle(elapsed: .seconds(89)))
    }

    @Test("disabled machine (grace zero) never exits")
    func disabledNeverExits() {
        var machine = IdleExitStateMachine(grace: .zero)
        let t0 = ContinuousClock().now

        for offset in [Duration.zero, .seconds(1), .seconds(1000)] {
            #expect(machine.update(snapshot(), now: t0 + offset) == .active)
        }
    }

    // MARK: - Counters

    @Test("request counting is balanced and a finished request does not pin the daemon")
    func requestCountingBalanced() {
        let counters = IdleActivityCounters()

        counters.beginRequest()
        #expect(counters.snapshot().inFlightRequests == 1)

        counters.beginRequest()
        counters.endRequest()
        #expect(counters.snapshot().inFlightRequests == 1)

        counters.endRequest()
        #expect(counters.snapshot().inFlightRequests == 0)
    }

    @Test("stream tokens are counted independently and ending is idempotent")
    func streamTokensIndependentAndIdempotent() {
        let counters = IdleActivityCounters()

        let a = counters.beginStream()
        let b = counters.beginStream()
        #expect(counters.snapshot().activeStreams == 2)

        // Double-ending the same token must not steal from the other stream.
        counters.endStream(a)
        counters.endStream(a)
        #expect(counters.snapshot().activeStreams == 1)

        counters.endStream(b)
        #expect(counters.snapshot().activeStreams == 0)

        // Ending an already-ended token stays a no-op.
        counters.endStream(b)
        #expect(counters.snapshot().activeStreams == 0)
    }

    @Test("running-container count is cached and can be marked unknown")
    func runningContainerCountCache() {
        let counters = IdleActivityCounters()
        #expect(counters.snapshot().runningContainers == nil)

        counters.setRunningContainers(2)
        #expect(counters.snapshot().runningContainers == 2)

        counters.markRunningContainersUnknown()
        #expect(counters.snapshot().runningContainers == nil)
    }

    // MARK: - Monitor loop

    @Test("a container that started after the last cached poll aborts the exit, and a later genuine idle still fires")
    func monitorAbortsExitOnFreshPollFindingContainers() async {
        final class Box: @unchecked Sendable {
            var value = 0
        }
        let clock = ManualClock()
        let counters = IdleActivityCounters()
        let running = Box()
        let exits = AtomicCounter()
        let monitor = IdleExitMonitor(
            configuration: IdleExitConfiguration(grace: .seconds(3)),
            counters: counters,
            clock: clock,
            // Every poll reads the live value: the startup poll sees 0 running;
            // the fresh pre-shutdown re-poll sees the container that started
            // just after the cached poll (the tick race).
            runningContainersProvider: { running.value },
            tickInterval: .seconds(1),
            containerPollInterval: .seconds(30),
            logger: Logger(label: "test.idleexit"),
            onExit: { exits.increment() }
        )

        let first = await monitor.step()
        #expect(first == .idle(elapsed: .zero))

        // `docker run -d` completes after the cached poll, before the grace
        // deadline. The grace then elapses against the stale count; the fresh
        // re-poll finds the running container and aborts the exit.
        running.value = 1
        clock.advance(by: .seconds(3))
        let decision = await monitor.step()
        #expect(decision == .active)
        #expect(exits.current == 0)

        // The container goes away and a fresh idle period still fires: the
        // abort re-armed the state machine's exit latch.
        running.value = 0
        clock.advance(by: .seconds(30))
        counters.setRunningContainers(0)
        let idleAgain = await monitor.step()
        #expect(idleAgain == .idle(elapsed: .zero))
        clock.advance(by: .seconds(3))
        let fired = await monitor.step()
        #expect(fired == .exitNow)
        #expect(exits.current == 1)
    }

    @Test("an unknown fresh poll result also aborts the exit (never exit on missing information)")
    func monitorAbortsExitOnUnknownFreshPoll() async {
        let clock = ManualClock()
        let counters = IdleActivityCounters()
        let polls = AtomicCounter()
        let exits = AtomicCounter()
        let monitor = IdleExitMonitor(
            configuration: IdleExitConfiguration(grace: .seconds(2)),
            counters: counters,
            clock: clock,
            runningContainersProvider: {
                polls.increment()
                return polls.current == 1 ? 0 : nil
            },
            tickInterval: .seconds(1),
            containerPollInterval: .seconds(30),
            logger: Logger(label: "test.idleexit"),
            onExit: { exits.increment() }
        )

        _ = await monitor.step()
        clock.advance(by: .seconds(2))
        let decision = await monitor.step()
        #expect(decision == .active)
        #expect(exits.current == 0)
    }

    @Test("monitor polls once up front, honors the poll interval, and exits exactly once after grace")
    func monitorExitsAfterGrace() async {
        let clock = ManualClock()
        let counters = IdleActivityCounters()
        let polls = AtomicCounter()
        let exits = AtomicCounter()
        let monitor = IdleExitMonitor(
            configuration: IdleExitConfiguration(grace: .seconds(3)),
            counters: counters,
            clock: clock,
            runningContainersProvider: {
                polls.increment()
                return 0
            },
            tickInterval: .seconds(1),
            containerPollInterval: .seconds(30),
            logger: Logger(label: "test.idleexit"),
            onExit: { exits.increment() }
        )

        // First step polls immediately (startup safety: count before deciding).
        let first = await monitor.step()
        #expect(first == .idle(elapsed: .zero))
        #expect(polls.current == 1)

        clock.advance(by: .seconds(2))
        let second = await monitor.step()
        #expect(second == .idle(elapsed: .seconds(2)))
        #expect(polls.current == 1)  // within the 30s container poll interval

        clock.advance(by: .seconds(1))
        let third = await monitor.step()
        #expect(third == .exitNow)
        #expect(exits.current == 1)

        // Already fired: never again.
        let fourth = await monitor.step()
        #expect(fourth == .active)
        #expect(exits.current == 1)
    }

    @Test("monitor re-polls containers once the poll interval has elapsed")
    func monitorRepollsAfterInterval() async {
        let clock = ManualClock()
        let polls = AtomicCounter()
        let monitor = IdleExitMonitor(
            configuration: IdleExitConfiguration(grace: .seconds(1000)),
            counters: IdleActivityCounters(),
            clock: clock,
            runningContainersProvider: {
                polls.increment()
                return 0
            },
            tickInterval: .seconds(1),
            containerPollInterval: .seconds(30),
            logger: Logger(label: "test.idleexit"),
            onExit: {}
        )

        _ = await monitor.step()
        #expect(polls.current == 1)

        clock.advance(by: .seconds(29))
        _ = await monitor.step()
        #expect(polls.current == 1)

        clock.advance(by: .seconds(1))  // 30s since the last poll
        _ = await monitor.step()
        #expect(polls.current == 2)
    }

    @Test("monitor does not exit while containers are running")
    func monitorBlockedByRunningContainers() async {
        let clock = ManualClock()
        let exits = AtomicCounter()
        let monitor = IdleExitMonitor(
            configuration: IdleExitConfiguration(grace: .seconds(3)),
            counters: IdleActivityCounters(),
            clock: clock,
            runningContainersProvider: { 2 },
            tickInterval: .seconds(1),
            containerPollInterval: .seconds(30),
            logger: Logger(label: "test.idleexit"),
            onExit: { exits.increment() }
        )

        #expect(await monitor.step() == .active)
        clock.advance(by: .seconds(100))
        #expect(await monitor.step() == .active)
        #expect(exits.current == 0)
    }

    @Test("monitor treats a failed poll as unknown and blocks exit")
    func monitorBlockedByUnknownContainers() async {
        let clock = ManualClock()
        let exits = AtomicCounter()
        let monitor = IdleExitMonitor(
            configuration: IdleExitConfiguration(grace: .seconds(3)),
            counters: IdleActivityCounters(),
            clock: clock,
            runningContainersProvider: { nil },
            tickInterval: .seconds(1),
            containerPollInterval: .seconds(30),
            logger: Logger(label: "test.idleexit"),
            onExit: { exits.increment() }
        )

        #expect(await monitor.step() == .active)
        clock.advance(by: .seconds(100))
        #expect(await monitor.step() == .active)
        #expect(exits.current == 0)
    }

    @Test("monitor with a disabled configuration is a no-op on start")
    func monitorDisabledStartsNothing() {
        let exits = AtomicCounter()
        let monitor = IdleExitMonitor(
            configuration: IdleExitConfiguration(grace: .zero),
            counters: IdleActivityCounters(),
            clock: ManualClock(),
            runningContainersProvider: { 0 },
            logger: Logger(label: "test.idleexit"),
            onExit: { exits.increment() }
        )
        monitor.start()
        #expect(exits.current == 0)
    }
}
