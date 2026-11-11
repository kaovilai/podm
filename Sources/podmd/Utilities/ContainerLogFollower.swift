import ContainerAPIClient
import ContainerResource
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
///
/// Epochs order ARMS, not boots: a `/start` delayed in its post-start setup
/// can arm after a newer `/restart` already booted the container and armed
/// its own follower — the delayed arm would carry a higher epoch, cancel the
/// newer boot's follower and wipe its journal. Arms therefore also carry the
/// boot's `startedDate` (when the lifecycle transition observed one); an arm
/// for an OLDER boot than the currently-armed one is rejected outright.
actor ContainerLogFollowerRegistry {
    static let shared = ContainerLogFollowerRegistry()

    private var epochs: [String: UInt64] = [:]
    private var tasks: [String: (task: Task<Void, Never>, epoch: UInt64)] = [:]
    /// The `startedDate` of the boot each container's armed follower belongs
    /// to — the boot-generation token stale arms are rejected against.
    private var bootTokens: [String: Date] = [:]
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
    /// - Parameter bootStartedAt: the `startedDate` of the boot this arm is
    ///   for, when the lifecycle transition observed one. An arm for a boot
    ///   OLDER than the currently-armed follower's boot is rejected — it
    ///   belongs to a superseded lifecycle (a `/start` delayed past a newer
    ///   `/restart`) and must not cancel the newer boot's follower or wipe
    ///   its journal. Nil (Apple reported no start date) falls back to
    ///   epoch-only ordering.
    ///
    /// The journal activation (reset for a fresh boot, adoption for a resume)
    /// happens BEFORE this method returns: a windowed logs request issued
    /// immediately after the route returns must not read the previous boot's
    /// journal — repeated startup lines would match its old timestamps.
    func arm(
        nativeId: String,
        client: ClientContainerProtocol,
        logger: Logger,
        freshBoot: Bool,
        bootStartedAt: Date? = nil,
        journal: ContainerLogJournal = .shared,
        openLogStream: (@Sendable (String) async throws -> FileHandle)? = nil
    ) async {
        // A stale boot never displaces the armed follower of a newer one.
        if let bootStartedAt, let armedBoot = bootTokens[nativeId], bootStartedAt < armedBoot {
            return
        }
        if let existing = tasks[nativeId], existing.epoch == epochs[nativeId], !existing.task.isCancelled {
            if !freshBoot {
                // A current-boot follower is already watching this container.
                // The arm may still carry what the original arm lacked — this
                // boot's `startedDate` (the attach paths arm right after
                // bootstrap, before Apple reports one; the `/start` that
                // follows supplies it). Adopt it into the journal before
                // returning: an unidentified journal can never prove a later
                // reboot-while-unarmed, and would lend its old timestamps to
                // identical startup lines.
                if let bootStartedAt {
                    await journal.adoptBootIdentity(
                        nativeId: nativeId, epoch: existing.epoch,
                        bootIdNano: ContainerLogJournal.bootIdNano(from: bootStartedAt))
                }
                return
            }
            // A FRESH arm for the boot that is already armed is redundant.
            // A `/start` delayed past a `/restart` fetches the restart's
            // newer snapshot during post-start setup, so it arrives with
            // that same (newer) `startedDate` and freshBoot true — the
            // older-boot guard above cannot reject it. Letting it through
            // would cancel the restart's follower and erase the timestamps
            // it already recorded. Same boot, same journal — leave both be.
            if let bootStartedAt, bootStartedAt == bootTokens[nativeId] {
                return
            }
        }
        nextEpoch += 1
        let epoch = nextEpoch
        epochs[nativeId] = epoch
        tasks[nativeId]?.task.cancel()
        if let bootStartedAt { bootTokens[nativeId] = bootStartedAt }
        // Activate this follower as the journal's writer NOW, not from the
        // detached task: the route must not return while the previous boot's
        // journal is still visible. A fresh boot resets (gated on the epoch
        // inside the journal actor); a resume adopts — or resets, when the
        // persisted journal's boot identity proves a reboot happened while no
        // follower was armed.
        if freshBoot {
            await journal.beginBoot(
                nativeId: nativeId, epoch: epoch, bootIdNano: ContainerLogJournal.bootIdNano(from: bootStartedAt))
        } else {
            await journal.resumeBoot(
                nativeId: nativeId, epoch: epoch, bootIdNano: ContainerLogJournal.bootIdNano(from: bootStartedAt))
        }
        // The activation suspended this actor — a concurrent arm may have
        // taken the epoch over in the meantime. Its own activation (higher
        // epoch) won inside the journal; do not register a superseded task.
        guard epochs[nativeId] == epoch else { return }
        let task = Task.detached {
            await ContainerLogFollower.follow(
                nativeId: nativeId, epoch: epoch, client: client, logger: logger,
                freshBoot: freshBoot, journal: journal, openLogStream: openLogStream,
                bootStartedAt: bootStartedAt, journalAlreadyActivated: true)
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
        bootTokens[nativeId] = nil
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

    /// Framed-byte bound for one in-flight journal batch. The line-count
    /// bound alone allowed ~256 MiB of payload (256 lines at the 1 MiB
    /// pending-line bound) to accumulate per follower before the journal's
    /// 4 MiB cap ever ran — several containers emitting large lines could
    /// exhaust daemon memory. Bounding the batch's payload by bytes as well
    /// keeps each follower's in-flight batch near one max-size line.
    static let journalBatchBytes = 1 << 20

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
    ///
    /// Access is lock-guarded: tests run in parallel and several suites
    /// install (and nil out) the callback while followers of OTHER tests are
    /// invoking it — an unsynchronized global is a data race that can crash
    /// the test process. `nonisolated(unsafe)` only silences the compiler's
    /// isolation check; the lock below provides the actual safety.
    private static let onBatchFlushLock = NSLock()
    nonisolated(unsafe) private static var _onBatchFlush: (@Sendable (String) -> Void)?
    nonisolated(unsafe) static var onBatchFlush: (@Sendable (String) -> Void)? {
        get {
            onBatchFlushLock.lock()
            defer { onBatchFlushLock.unlock() }
            return _onBatchFlush
        }
        set {
            onBatchFlushLock.lock()
            defer { onBatchFlushLock.unlock() }
            _onBatchFlush = newValue
        }
    }

    /// Picks the container's log stream out of the handles Apple Container's
    /// `logs(id:)` returns — 1.2.2 yields TWO (`[containerLog, bootlog]`),
    /// both with `closeOnDealloc: false` — and closes the rest. Taking
    /// `.first` and dropping the array leaks a descriptor per follower arm,
    /// and repeated container restarts exhaust the daemon's fd limit.
    static func selectLogHandle(_ handles: [FileHandle]) -> FileHandle? {
        guard let log = handles.first else { return nil }
        for unused in handles.dropFirst() { try? unused.close() }
        return log
    }

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
    /// `bootStartedAt` (the boot's `startedDate`) is the journal's boot
    /// identity: a resume whose identity differs from the persisted one
    /// resets instead of adopting — the container rebooted while no follower
    /// was armed. `journalAlreadyActivated` marks that the registry already
    /// performed the activation before spawning this follower (arming routes
    /// must not return while the previous boot's journal is still visible),
    /// so the follower must not reset or adopt again.
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
        isCurrentEpoch: (@Sendable () async -> Bool)? = nil,
        bootStartedAt: Date? = nil,
        journalAlreadyActivated: Bool = false
    ) async {
        await runFollow(
            nativeId: nativeId, epoch: epoch, client: client, logger: logger, freshBoot: freshBoot,
            journal: journal, openLogStream: openLogStream, isCurrentEpoch: isCurrentEpoch,
            bootStartedAt: bootStartedAt, journalAlreadyActivated: journalAlreadyActivated)
        // The follower is done: release the journal's cached writer. The
        // follower closed ITS Apple log handle on exit, but the journal's
        // writer would otherwise stay open until the next reset, trim or
        // container deletion — one leaked descriptor per stopped container
        // can exhaust the daemon's fd limit. Epoch-guarded inside the
        // journal: a superseded follower cannot close its replacement's
        // handle. The entries stay for later windowed reads.
        await journal.closeWriter(nativeId: nativeId, epoch: epoch)
    }

    private static func runFollow(
        nativeId: String,
        epoch: UInt64,
        client: ClientContainerProtocol,
        logger: Logger,
        freshBoot: Bool,
        journal: ContainerLogJournal,
        openLogStream: (@Sendable (String) async throws -> FileHandle)?,
        isCurrentEpoch: (@Sendable () async -> Bool)?,
        bootStartedAt: Date?,
        journalAlreadyActivated: Bool
    ) async {
        let isCurrent: @Sendable () async -> Bool =
            isCurrentEpoch ?? { await ContainerLogFollowerRegistry.shared.isCurrent(nativeId: nativeId, epoch: epoch) }

        // Activate this follower as the journal's writer. A fresh boot resets
        // the journal (gated on the epoch inside the actor, so a follower
        // superseded before it starts wipes nothing); a resume adopts the
        // persisted journal of the current boot instead — or resets when the
        // persisted boot identity proves a reboot happened in between. The
        // registry already did this before spawning us (its callers must not
        // return while the old journal is visible) — never repeat it: a
        // second reset would wipe entries journaled in between.
        if !journalAlreadyActivated {
            if freshBoot {
                await journal.beginBoot(
                    nativeId: nativeId, epoch: epoch, bootIdNano: ContainerLogJournal.bootIdNano(from: bootStartedAt))
            } else {
                await journal.resumeBoot(
                    nativeId: nativeId, epoch: epoch, bootIdNano: ContainerLogJournal.bootIdNano(from: bootStartedAt))
            }
        }
        guard await isCurrent() else { return }

        // Opening the Apple log stream can fail TRANSIENTLY (the XPC service
        // reconnecting while the VM keeps running). A single failure used to
        // end the follower for good — the registry reaped it and later
        // output lost its recorded timestamps until another lifecycle
        // request or a daemon restart. Retry while this follower's epoch
        // stays current, stopping only on cancellation/supersession or a
        // CONFIRMED missing/stopped container. A failed status LOOKUP is
        // not a confirmation (same rule as the poll loop below — the Apple
        // service can stay unavailable through a reconnect retry): retry
        // after the polling delay instead.
        var handle: FileHandle?
        while handle == nil {
            if Task.isCancelled { return }
            guard await isCurrent() else { return }
            do {
                if let openLogStream {
                    handle = try await openLogStream(nativeId)
                } else {
                    handle = ContainerLogFollower.selectLogHandle(
                        try await ContainerClient().logs(id: nativeId))
                }
            } catch {
                logger.debug(
                    "log follower: could not open Apple log stream for \(nativeId) (will retry): \(error)")
            }
            if handle == nil {
                let current: ContainerSnapshot?
                do {
                    current = try await client.getContainer(id: nativeId)
                } catch {
                    try? await Task.sleep(nanoseconds: pollIntervalNs)
                    continue
                }
                if Task.isCancelled { return }
                guard await isCurrent() else { return }
                if current == nil || current?.status != .running { return }
                try? await Task.sleep(nanoseconds: pollIntervalNs)
            }
        }
        guard let handle else { return }
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
            var freshBytes = 0

            func flushBatch() async {
                guard !fresh.isEmpty else { return }
                let batch = fresh
                fresh.removeAll(keepingCapacity: true)
                freshBytes = 0
                await journal.append(nativeId: nativeId, epoch: epoch, batch)
                ContainerLogFollower.onBatchFlush?(nativeId)
            }

            /// Enqueues one journal entry, flushing the batch when EITHER
            /// bound is exceeded. Ordinary lines and gap markers share this
            /// path: the line-count bound alone let ~256 MiB of large-line
            /// payload accumulate before a flush, and gap markers appended
            /// outside a flush check accumulated unboundedly until a read
            /// gap.
            func enqueue(_ entry: ContainerLogJournal.Entry) async {
                fresh.append(entry)
                freshBytes += entry.framedByteCount
                if fresh.count >= ContainerLogFollower.journalBatchLines
                    || freshBytes >= ContainerLogFollower.journalBatchBytes
                {
                    await flushBatch()
                }
            }

            /// Records that one oversized stream line was consumed without
            /// retaining its payload: consume the journal's existing gap
            /// marker (this boot already recorded one — a resume re-reading
            /// the same oversized line), or append a new marker so later
            /// alignments can consume the line's ordinal. An EVICTED result
            /// is equally accounted: the line's marker was evicted by the
            /// cap, and the evicted-prefix count already covers the line —
            /// appending a marker here would double-count its ordinal.
            ///
            /// A retained ORDINARY entry at the alignment head is a mismatch
            /// (`consumeGapMarker` disables matching) — the journal is from
            /// a different boot, and the heal must run HERE, before any
            /// marker is flushed: a resumed stream of ONLY oversized lines
            /// never reaches the ordinary-line recovery branch, so without
            /// this the marker would land behind the stale entries and
            /// every later windowed read would fall back to read time. The
            /// line itself is accounted by the heal's dropped-lines count —
            /// no marker is recorded for it, exactly like the ordinary-line
            /// heal (a surviving marker would double-count its ordinal).
            func markOversizedLine() async {
                if case .fresh = alignment.consumeGapMarker() {
                    if alignment.failed {
                        // Count THIS line before healing so the replacement
                        // journal's dropped-lines prefix accounts it.
                        linesConsumedUnretained += 1
                        await healStaleJournal()
                        return
                    }
                    await enqueue(
                        ContainerLogJournal.Entry.gapMarker(unixNano: ContainerLogJournal.currentUnixNano()))
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
                freshBytes -= fresh.filter(\.isGapMarker).reduce(0) { $0 + $1.framedByteCount }
                fresh.removeAll { $0.isGapMarker }
                await journal.beginBoot(
                    nativeId: nativeId, epoch: epoch, droppedLines: linesConsumedUnretained,
                    bootIdNano: ContainerLogJournal.bootIdNano(from: bootStartedAt))
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
                        await markOversizedLine()
                        continue
                    }
                    if line.count > ContainerLogFollower.maxPendingLineBytes {
                        // A complete line beyond the bound (its newline landed
                        // in the same chunk that crossed the bound): same
                        // treatment as the mid-line discard — marker, no
                        // payload — so the journal never retains a line the
                        // windowed readers would have to spill.
                        await markOversizedLine()
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
                        await enqueue(
                            ContainerLogJournal.Entry(
                                unixNano: ContainerLogJournal.currentUnixNano(),
                                streamType: DockerStreamFrame.StreamType.stdout.rawValue,
                                bytes: line
                            ))
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
                    await markOversizedLine()
                } else if !pending.isEmpty {
                    switch alignment.classify(pending) {
                    case .covered, .evicted:
                        break  // already recorded by an earlier exit drain
                    case .fresh:
                        if alignment.failed {
                            await healStaleJournal()
                        }
                        await enqueue(
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
            let current: ContainerSnapshot?
            do {
                current = try await client.getContainer(id: nativeId)
            } catch {
                // A FAILED lookup is not a confirmed exit: the Apple API
                // service can stay unavailable through a reconnect retry
                // while the VM keeps running. Ending the follower here
                // would permanently stop journaling — later output would
                // lose its timestamps until another start or a daemon
                // restart. Retry after the polling delay instead.
                try? await Task.sleep(nanoseconds: pollIntervalNs)
                continue
            }
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
