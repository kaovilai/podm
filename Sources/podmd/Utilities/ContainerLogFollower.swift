import ContainerAPIClient
import Foundation
import Logging

/// Background journal-writer per running container: the counterpart of
/// `ContainerStartRoute.observeExit` for logs. It does what the logs route
/// does today (read the Apple log handle, split on newline) but records each
/// completed line into `ContainerLogJournal` with its ARRIVAL timestamp, and
/// stops once the container is no longer running.
///
/// Arming happens in `ContainerStartRoute.armRestartObserver` — the single
/// choke point shared by `/start`, `/restart`, and the internal
/// restart-policy restart — because every container lifecycle that produces
/// output goes through it (a foreground `docker run` still receives a `/start`
/// after the attach route bootstraps the container). Followers are
/// epoch-guarded: each arm bumps a per-container epoch, the follower loop
/// checks it to exit when superseded, and the journal actor tracks the
/// accepted writer epoch itself (checked synchronously with each mutation),
/// so a superseded follower (redundant `/start`, restart racing a slow poll)
/// can never interleave entries into a newer boot's journal.
actor ContainerLogFollowerRegistry {
    static let shared = ContainerLogFollowerRegistry()

    private var epochs: [String: UInt64] = [:]
    private var tasks: [String: (task: Task<Void, Never>, epoch: UInt64)] = [:]
    private var nextEpoch: UInt64 = 0

    /// True while `epoch` is still the current generation for `nativeId`.
    func isCurrent(nativeId: String, epoch: UInt64) -> Bool {
        epochs[nativeId] == epoch
    }

    /// Whether a follower task is registered for `nativeId` (it may still be
    /// winding down after its container stopped).
    func isArmed(nativeId: String) -> Bool {
        tasks[nativeId] != nil
    }

    /// Arms a journal follower for the container's current boot.
    ///
    /// - Parameter freshBoot: true when the container just (re)started — Apple
    ///   truncates the log file at every boot, so the journal must reset and a
    ///   new follower must take over even if an old one has not noticed the
    ///   restart yet. False for a plain `/start`, where a live current-epoch
    ///   follower means the container was already running under this boot and
    ///   must not be disturbed.
    func arm(
        nativeId: String,
        client: ClientContainerProtocol,
        logger: Logger,
        freshBoot: Bool,
        journal: ContainerLogJournal = .shared,
        openLogStream: (@Sendable (String) async throws -> FileHandle)? = nil
    ) {
        if !freshBoot,
            let existing = tasks[nativeId],
            existing.epoch == epochs[nativeId],
            !existing.task.isCancelled
        {
            return  // a current-boot follower is already watching this container
        }
        nextEpoch += 1
        let epoch = nextEpoch
        epochs[nativeId] = epoch
        tasks[nativeId]?.task.cancel()
        let task = Task.detached {
            await ContainerLogFollower.follow(
                nativeId: nativeId, epoch: epoch, client: client, logger: logger,
                freshBoot: freshBoot, journal: journal, openLogStream: openLogStream)
        }
        tasks[nativeId] = (task, epoch)
        Task.detached {
            _ = await task.value
            await self.reap(nativeId: nativeId, epoch: epoch)
        }
    }

    /// Stops the follower (if any) for a container about to be removed.
    func disarm(nativeId: String) {
        epochs[nativeId] = nil
        tasks[nativeId]?.task.cancel()
        tasks[nativeId] = nil
    }

    private func reap(nativeId: String, epoch: UInt64) {
        if let existing = tasks[nativeId], existing.epoch == epoch {
            tasks[nativeId] = nil
        }
    }
}

enum ContainerLogFollower {
    /// How long the follower sleeps between polls of the Apple log handle —
    /// the same cadence the logs route's follow loop uses.
    static let pollIntervalNs: UInt64 = 150_000_000

    /// Completed lines are journaled in batches of at most this many while
    /// reading, so a huge backlog (or a continuously written log) reaches the
    /// journal before the stream hits EOF instead of accumulating in memory.
    static let journalBatchLines = 256

    /// A single line without a newline may hold at most this many bytes in
    /// the pending buffer; beyond that the line is discarded (unjournaled —
    /// its timestamps fall back to read time) so a newline-free stream
    /// cannot exhaust daemon memory.
    static let maxPendingLineBytes = 1 << 20

    /// Test seam: invoked with the container's native id after every journal
    /// batch flush (including the end-of-read one). Production never sets it;
    /// tests use it to assert that a large backlog reaches the journal in
    /// bounded batches WHILE the stream is read, not in one unbounded
    /// accumulation at EOF.
    nonisolated(unsafe) static var onBatchFlush: (@Sendable (String) -> Void)?

    /// Tears a container's log-following state down along with it — called
    /// from the delete, prune and --rm auto-remove cleanup paths. `registry`
    /// and `journal` default to the shared instances; tests inject their own.
    static func teardown(
        nativeId: String,
        registry: ContainerLogFollowerRegistry = .shared,
        journal: ContainerLogJournal = .shared
    ) async {
        await registry.disarm(nativeId: nativeId)
        await journal.remove(nativeId: nativeId)
    }

    /// Mirrors the container's Apple log stream into the journal until the
    /// container stops. Re-opening the stream per arm (rather than sharing a
    /// handle with the route) keeps ownership simple: each follower reads from
    /// byte 0 and skips lines the journal already covers by content
    /// alignment, which also self-heals after cap evictions.
    ///
    /// `freshBoot` distinguishes a container that just (re)started (the
    /// journal resets — Apple truncates the log at every boot) from a resume
    /// of an already-running container (daemon restart, redundant `/start`):
    /// the persisted journal is preserved and alignment continues. A stale
    /// journal from a different boot is detected by alignment failure and
    /// reset then, so an unknowing resume cannot restamp history.
    ///
    /// `journal`, `openLogStream` and `isCurrentEpoch` are seams for tests:
    /// production runs use the shared journal, Apple's log stream, and the
    /// follower registry's epoch check respectively.
    static func follow(
        nativeId: String,
        epoch: UInt64,
        client: ClientContainerProtocol,
        logger: Logger,
        freshBoot: Bool,
        journal: ContainerLogJournal = .shared,
        openLogStream: (@Sendable (String) async throws -> FileHandle)? = nil,
        isCurrentEpoch: (@Sendable () async -> Bool)? = nil
    ) async {
        let isCurrent: @Sendable () async -> Bool =
            isCurrentEpoch ?? { await ContainerLogFollowerRegistry.shared.isCurrent(nativeId: nativeId, epoch: epoch) }

        // Activate this follower as the journal's writer. A fresh boot resets
        // the journal (gated on the epoch inside the actor, so a follower
        // superseded before it starts wipes nothing); a resume adopts the
        // persisted journal of the current boot instead.
        if freshBoot {
            await journal.beginBoot(nativeId: nativeId, epoch: epoch)
        } else {
            await journal.resumeBoot(nativeId: nativeId, epoch: epoch)
        }
        guard await isCurrent() else { return }

        let handle: FileHandle
        do {
            if let openLogStream {
                handle = try await openLogStream(nativeId)
            } else {
                guard let appleHandle = try await ContainerClient().logs(id: nativeId).first else { return }
                handle = appleHandle
            }
        } catch {
            logger.debug("log follower: could not open Apple log stream for \(nativeId): \(error)")
            return
        }
        defer { try? handle.close() }

        let bootJournal = await journal.contents(nativeId: nativeId)
        var alignment = ContainerLogJournal.Alignment(
            entries: bootJournal.entries, droppedLines: bootJournal.droppedLines, evictedNanos: bootJournal.evictedNanos)
        var pending = Data()
        // True while `pending` holds the continuation of an oversized line
        // whose head bytes were already discarded: everything up to (and
        // including) the terminating newline belongs to that line. The flag
        // lives HERE, beside `pending`, not inside `readAvailable` — a line
        // spanning a read gap (temporary EOF, then more bytes) must still be
        // recognized as a discard tail by the next poll, or its last fragment
        // would be journaled as a complete line.
        var discardingPartialLine = false
        // Stream lines consumed against the CURRENT journal generation
        // without being retained in it (covered/evicted/marker ordinals of a
        // journal that turns out stale). The first content mismatch passes
        // this count to `beginBoot(droppedLines:)`, so the reset accounts the
        // already-consumed prefix and the retained suffix still aligns.
        var linesConsumedUnretained = 0

        /// Reads everything currently available, journaling each complete line
        /// (skipping lines already covered by the journal) with the arrival
        /// time of this pass. Lines reach the journal in bounded batches while
        /// reading, so a huge backlog cannot accumulate in memory; a
        /// newline-free partial line beyond `maxPendingLineBytes` is
        /// discarded rather than buffered. Returns whether any bytes were
        /// read.
        ///
        /// With `finalizeUnterminatedLine` — the confirmed-exit drain only —
        /// the log's trailing unterminated line is persisted too (stamped with
        /// the exit-drain time), so a container whose last line never met its
        /// newline (`printf hello`) still gets a recorded write time: without
        /// it, a windowed read could only stamp that fragment with the CURRENT
        /// read time, and an `--until` after the exit but before the request
        /// returned nothing. A resumed follower re-reading the same exit
        /// classifies the fragment covered and does not duplicate it. An
        /// oversized final line keeps its marker-only accounting (no payload
        /// is ever retained for it).
        func readAvailable(finalizeUnterminatedLine: Bool = false) async -> Bool {
            var gotData = false
            var fresh: [ContainerLogJournal.Entry] = []

            func flushBatch() async {
                guard !fresh.isEmpty else { return }
                await journal.append(nativeId: nativeId, epoch: epoch, fresh)
                fresh.removeAll(keepingCapacity: true)
                ContainerLogFollower.onBatchFlush?(nativeId)
            }

            /// Records that one oversized stream line was consumed without
            /// retaining its payload: consume the journal's existing gap
            /// marker (this boot already recorded one — a resume re-reading
            /// the same oversized line), or append a new marker so later
            /// alignments can consume the line's ordinal. An EVICTED result
            /// is equally accounted: the line's marker was evicted by the
            /// cap, and the evicted-prefix count already covers the line —
            /// appending a marker here would double-count its ordinal.
            func markOversizedLine() {
                if case .fresh = alignment.consumeGapMarker() {
                    fresh.append(ContainerLogJournal.Entry.gapMarker(unixNano: ContainerLogJournal.currentUnixNano()))
                }
                // .covered and .evicted are both already accounted — by the
                // persisted marker, or by the evicted prefix the cap took
                // the marker with; appending a marker here would
                // double-count the line's ordinal.
                linesConsumedUnretained += 1
            }

            /// Heals a journal that provably belongs to a different boot:
            /// reset it on the FIRST alignment failure — before this batch's
            /// replacement entries flush — so the stale entries cannot leak
            /// wrong timestamps into --since/--until, and so no replacement
            /// line is flushed into the stale journal only to be wiped a
            /// batch later. The lines already consumed against the stale
            /// journal are accounted as dropped, keeping the suffix aligned.
            func healStaleJournal() async {
                // Gap markers recorded while aligning against the journal
                // that just proved stale account lines the reset itself
                // counts as dropped (`linesConsumedUnretained`): keeping one
                // would count its line twice — replay would skip the line as
                // evicted AND mismatch the next retained line against the
                // marker, losing its recorded timestamp.
                fresh.removeAll { $0.isGapMarker }
                await journal.beginBoot(nativeId: nativeId, epoch: epoch, droppedLines: linesConsumedUnretained)
                alignment = ContainerLogJournal.Alignment(entries: [])
                linesConsumedUnretained = 0
            }

            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                // A superseding arm or a disarm cancels this task: stop
                // draining at the next chunk. A noisy container can keep
                // data available faster than it is read, so the read loop
                // would otherwise never reach the read gap that (only) the
                // outer loop's checks act on — the cancelled follower kept
                // reading and journaling alongside its replacement, and the
                // log handle was never released.
                if Task.isCancelled { break }
                gotData = true
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending.subdata(in: pending.startIndex..<pending.index(after: newline))
                    pending = pending.subdata(in: pending.index(after: newline)..<pending.endIndex)
                    if discardingPartialLine {
                        // Tail of an oversized line: not journalable, but its
                        // ordinal still consumes a gap marker (or records one).
                        discardingPartialLine = false
                        markOversizedLine()
                        continue
                    }
                    if line.count > ContainerLogFollower.maxPendingLineBytes {
                        // A complete line beyond the bound (its newline landed
                        // in the same chunk that crossed the bound): same
                        // treatment as the mid-line discard — marker, no
                        // payload — so the journal never retains a line the
                        // windowed readers would have to spill.
                        markOversizedLine()
                        continue
                    }
                    switch alignment.classify(line) {
                    case .covered, .evicted:
                        // Already journaled this boot (or since evicted): if
                        // the journal later proves stale, this consumed line
                        // must be accounted as dropped after the reset.
                        linesConsumedUnretained += 1
                        continue
                    case .fresh:
                        if alignment.failed {
                            // First mismatch: reset now, before appending or
                            // flushing anything, so this line and the rest of
                            // the read land in the replacement journal.
                            await healStaleJournal()
                        }
                        fresh.append(
                            ContainerLogJournal.Entry(
                                unixNano: ContainerLogJournal.currentUnixNano(),
                                streamType: DockerStreamFrame.StreamType.stdout.rawValue,
                                bytes: line
                            ))
                        if fresh.count >= ContainerLogFollower.journalBatchLines {
                            await flushBatch()
                        }
                    }
                }
                if pending.count > ContainerLogFollower.maxPendingLineBytes {
                    pending.removeAll(keepingCapacity: false)
                    discardingPartialLine = true
                }
            }
            if finalizeUnterminatedLine {
                if discardingPartialLine {
                    // The final line was oversized: its head bytes were
                    // discarded and the tail bytes in `pending` are
                    // unjournalable — record the marker for the line's
                    // ordinal, so a resumed follower re-reading the same exit
                    // consumes it instead of double-accounting.
                    markOversizedLine()
                } else if !pending.isEmpty {
                    switch alignment.classify(pending) {
                    case .covered, .evicted:
                        break  // already recorded by an earlier exit drain
                    case .fresh:
                        if alignment.failed {
                            await healStaleJournal()
                        }
                        fresh.append(
                            ContainerLogJournal.Entry(
                                unixNano: ContainerLogJournal.currentUnixNano(),
                                streamType: DockerStreamFrame.StreamType.stdout.rawValue,
                                bytes: pending))
                    }
                }
            }
            await flushBatch()
            return gotData
        }

        while !Task.isCancelled {
            guard await isCurrent() else { return }
            let gotData = await readAvailable()
            if gotData { continue }
            let current = try? await client.getContainer(id: nativeId)
            guard await isCurrent() else { return }
            if current == nil || current?.status != .running {
                // Give the exit path the same flush grace the process exit
                // monitor grants pipe readers, journal the final writes, stop.
                try? await Task.sleep(nanoseconds: ContainerProcessExitMonitor.outputFlushGraceNs)
                guard await isCurrent() else { return }
                _ = await readAvailable(finalizeUnterminatedLine: true)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
    }
}
