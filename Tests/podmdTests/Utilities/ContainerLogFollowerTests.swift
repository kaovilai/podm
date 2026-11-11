import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import podmd

/// The background journal-writer's lifecycle: armed through the registry, it
/// reads the container's log stream, records each completed line with its
/// arrival time, keeps following while the container runs, and stops (with a
/// final drain) once it no longer does. Driven through the registry's test
/// seams — a temp log file instead of Apple's XPC-backed stream, a mutable
/// mock client for the running/stopped check, and a temp-dir journal.
@Suite("ContainerLogFollower")
struct ContainerLogFollowerTests {

    /// ClientContainerProtocol mock whose reported status flips on demand,
    /// and whose status LOOKUPS can be made to fail (an Apple API service
    /// outage) and recover — a failed lookup must not read as an exit.
    private final class StatusFlipMock: ClientContainerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var failLookups = false
        func stopContainer() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
        func failContainerLookups() {
            lock.lock()
            failLookups = true
            lock.unlock()
        }
        func recoverContainerLookups() {
            lock.lock()
            failLookups = false
            lock.unlock()
        }
        private var snapshot: ContainerSnapshot {
            let proc = ProcessConfiguration(
                executable: "/bin/sh", arguments: [], environment: [],
                workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
            let img = ImageDescription(
                reference: "alpine:latest",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
            let config = ContainerConfiguration(id: "ctr", image: img, process: proc)
            lock.lock()
            defer { lock.unlock() }
            return ContainerSnapshot(configuration: config, status: stopped ? .stopped : .running, networks: [])
        }
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
        func getContainer(id: String) async throws -> ContainerSnapshot? {
            if lookupFailing { throw StatusFlipMock.LookupUnavailable() }
            return snapshot
        }

        private var lookupFailing: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failLookups
        }

        private struct LookupUnavailable: Error {}
        func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws -> Bool { true }
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { true }
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
            RESTContainerWait(statusCode: 0)
        }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
            ([], 0)
        }
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-follower-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Polls `condition` until true or the timeout passes.
    ///
    /// The budget must survive a transiently starved cooperative pool, not
    /// just a slow poll: CI's shared 3-core macOS runners periodically stall
    /// the whole test process for ~10s (every test in the run, down to pure
    /// unit tests, completes only after the stall lifts — see the round-1
    /// live-broadcast de-flake for the same runner class). The follower
    /// journals within milliseconds once scheduled, so a generous deadline
    /// only ever waits out the stall; a tight one fails a correct follower.
    private func waitFor(
        _ condition: () async -> Bool,
        timeout: TimeInterval = 30
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    @Test("journals completed lines with arrival times and stops when the container stops")
    func followsUntilExit() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let writer = try FileHandle(forWritingTo: logFile)

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared

        let before = ContainerLogJournal.currentUnixNano()
        await registry.arm(
            nativeId: "follower-test-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )
        try writer.write(contentsOf: Data("first\n".utf8))
        try writer.write(contentsOf: Data("second\npartial-no-newline".utf8))

        let journaled = await waitFor {
            await journal.entries(nativeId: "follower-test-ctr").count >= 2
        }
        #expect(journaled, "both complete lines should be journaled promptly")

        let entries = await journal.entries(nativeId: "follower-test-ctr")
        #expect(entries.map(\.bytes) == [Data("first\n".utf8), Data("second\n".utf8)], "partial line must not be journaled")
        #expect(entries.allSatisfy { $0.unixNano >= before }, "arrival timestamps must be recorded")

        // The container stops; the held-back partial line is completed and a
        // final line still gets drained and journaled, then the follower
        // exits and reaps itself from the registry.
        client.stopContainer()
        // The leading \n completes the pending partial as its own line first.
        try writer.write(contentsOf: Data("\nfinal\n".utf8))
        try? writer.close()

        let finished = await waitFor {
            let armed = await registry.isArmed(nativeId: "follower-test-ctr")
            return !armed
        }
        #expect(finished, "follower should reap itself after the container stops")

        let finalEntries = await journal.entries(nativeId: "follower-test-ctr")
        #expect(
            finalEntries.map(\.bytes) == [
                Data("first\n".utf8), Data("second\n".utf8),
                Data("partial-no-newline\n".utf8), Data("final\n".utf8),
            ], "the exit drain should journal the completed partial and the final line")
    }

    @Test("teardown disarms the follower and removes the journal")
    func teardown() async throws {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.beginBoot(nativeId: "teardown-ctr", epoch: 1)
        await journal.append(
            nativeId: "teardown-ctr", epoch: 1,
            [ContainerLogJournal.Entry(unixNano: 1, streamType: 1, bytes: Data("x\n".utf8))])
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "teardown-ctr",
            client: StatusFlipMock(),
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in FileHandle.nullDevice }
        )
        let armedBefore = await registry.isArmed(nativeId: "teardown-ctr")
        #expect(armedBefore)

        // Exercise the real teardown entry point (registry + journal are its
        // test seams) — the delete/prune/auto-remove paths depend on it.
        await ContainerLogFollower.teardown(nativeId: "teardown-ctr", registry: registry, journal: journal)
        let cleared = await journal.entries(nativeId: "teardown-ctr")
        #expect(cleared.isEmpty)
        let armedAfter = await registry.isArmed(nativeId: "teardown-ctr")
        #expect(!armedAfter)
    }

    // MARK: - Boot semantics (fresh boot vs resume)

    /// Seeds `journal` (a fresh instance over `dir`, as after a daemon
    /// restart) with `lines` under epoch 1, then returns the instance a
    /// resumed follower would use.
    private func seedJournal(
        dir: URL, nativeId: String, lines: [(nano: UInt64, line: String)], droppedLines: Int = 0
    ) async
        -> ContainerLogJournal
    {
        let seeder = ContainerLogJournal()
        await seeder.configure(storageDirectory: dir)
        await seeder.beginBoot(nativeId: nativeId, epoch: 1, droppedLines: droppedLines)
        await seeder.append(
            nativeId: nativeId, epoch: 1,
            lines.map { ContainerLogJournal.Entry(unixNano: $0.nano, streamType: 1, bytes: Data($0.line.utf8)) })
        let resumed = ContainerLogJournal()
        await resumed.configure(storageDirectory: dir)
        return resumed
    }

    @Test("a resume boot preserves the journal and skips already-covered lines")
    func resumeBootPreservesJournal() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        // The whole current boot's output, of which the journal already
        // covers the first line (persisted across a daemon restart).
        FileManager.default.createFile(atPath: logFile.path, contents: Data("first\nsecond\n".utf8))
        let journal = await seedJournal(dir: dir, nativeId: "resume-ctr", lines: [(111, "first\n")])

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "resume-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        let journaled = await waitFor {
            await journal.entries(nativeId: "resume-ctr").count >= 2
        }
        #expect(journaled, "the uncovered line should be journaled promptly")

        let entries = await journal.entries(nativeId: "resume-ctr")
        #expect(entries.map(\.bytes) == [Data("first\n".utf8), Data("second\n".utf8)])
        #expect(entries.first?.unixNano == 111, "the covered line keeps its recorded time — not restamped, not duplicated")

        client.stopContainer()
        let finished = await waitFor {
            let armed = await registry.isArmed(nativeId: "resume-ctr")
            return !armed
        }
        #expect(finished)
    }

    @Test("a fresh boot resets the journal for the new boot")
    func freshBootResetsJournal() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logFile.path, contents: Data("new boot line\n".utf8))
        // A journal still holding the PREVIOUS boot's lines (a quick
        // stop/start: Apple truncated the log at the new boot).
        let journal = await seedJournal(dir: dir, nativeId: "fresh-ctr", lines: [(111, "previous boot\n")])

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "fresh-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        // Wait for the RESET and the new line (count alone could pass on the
        // seeded old-boot entry before the follower runs).
        let journaled = await waitFor {
            await journal.entries(nativeId: "fresh-ctr").map(\.bytes) == [Data("new boot line\n".utf8)]
        }
        #expect(journaled)
        let entries = await journal.entries(nativeId: "fresh-ctr")
        #expect(entries.map(\.bytes) == [Data("new boot line\n".utf8)], "the old boot's entries must be reset")

        // The reset hit disk: a fresh instance sees only the new boot.
        let reloaded = ContainerLogJournal()
        await reloaded.configure(storageDirectory: dir)
        #expect(await reloaded.entries(nativeId: "fresh-ctr").map(\.bytes) == [Data("new boot line\n".utf8)])

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "fresh-ctr")
            return !armed
        }
    }

    @Test("a resumed follower resets a journal that provably belongs to another boot")
    func resumedFollowerSelfHealsStaleJournal() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logFile.path, contents: Data("this boot\n".utf8))
        // A journal from a DIFFERENT boot (e.g. a `docker start -a` flow where
        // the attach route bootstrapped the container before any /start could
        // pass fresh-boot): its lines can never align with this stream.
        let journal = await seedJournal(dir: dir, nativeId: "heal-ctr", lines: [(111, "stale boot\n")])

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "heal-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        let journaled = await waitFor {
            await journal.entries(nativeId: "heal-ctr").map(\.bytes) == [Data("this boot\n".utf8)]
        }
        #expect(journaled, "the misaligned stale journal must be reset, not restamped or appended to")

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "heal-ctr")
            return !armed
        }
    }

    // MARK: - Bounded reading

    @Test("completed lines reach the journal in bounded batches while the stream is read")
    func boundedBatchJournaling() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        // A backlog far beyond one batch: the old behavior accumulated every
        // completed line until EOF and journaled once; the reader must flush
        // each bounded batch as it goes. (Foundation's read(upToCount:) on a
        // pipe blocks until the full count or EOF, so a never-ending stream
        // cannot be simulated — the seam observes the flush cadence instead.)
        let line = String(repeating: "0123456789", count: 10) + "\n"
        FileManager.default.createFile(
            atPath: logFile.path, contents: Data(String(repeating: line, count: 600).utf8))

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let flushCounter = FlushCounter(nativeId: "batch-ctr")
        FlushHub.install()
        FlushHub.shared.register(flushCounter, nativeId: "batch-ctr")

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "batch-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )
        defer { FlushHub.shared.unregister(nativeId: "batch-ctr") }

        // Wait for the journal AND the flush notifications TOGETHER:
        // `flushBatch()` updates the journal before invoking `onBatchFlush`,
        // so observing 600 entries does not imply the third notification
        // has run yet — asserting the count at that moment flakes with
        // correct batching.
        let journaled = await waitFor {
            await journal.entries(nativeId: "batch-ctr").count >= 600 && flushCounter.currentCount() >= 3
        }
        #expect(journaled, "the whole backlog should be journaled")
        // 600 lines at a 256-line batch size: at least the two in-read
        // flushes plus the final remainder — the single flush-at-EOF of the
        // old unbounded accumulation would count 1.
        #expect(flushCounter.currentCount() >= 3, "batches must be flushed mid-read, not accumulated until EOF")

        client.stopContainer()
        let finished = await waitFor {
            let armed = await registry.isArmed(nativeId: "batch-ctr")
            return !armed
        }
        #expect(finished)
    }

    /// Thread-safe flush counter for the `onBatchFlush` seam, scoped to one
    /// native id so parallel followers from other tests do not skew it. The
    /// count is read through a LOCKED accessor — the follower's flush task
    /// increments it concurrently, and an unsynchronized read races.
    private final class FlushCounter: @unchecked Sendable {
        private let lock = NSLock()
        private let nativeId: String
        private var count = 0
        init(nativeId: String) { self.nativeId = nativeId }
        func record(_ nativeId: String) {
            guard nativeId == self.nativeId else { return }
            lock.lock()
            count += 1
            lock.unlock()
        }
        func currentCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// `onBatchFlush` is a single global closure, but tests run in parallel:
    /// two tests assigning it (and nil-ing it in `defer`) overwrite each
    /// other and lose flush signals. The hub installs ONE forwarding closure
    /// and routes each flush to whichever counter is registered for that
    /// container — unregistered ids are no-ops, so the installed closure is
    /// safe to leave in place for the rest of the process.
    private final class FlushHub: @unchecked Sendable {
        static let shared = FlushHub()
        private let lock = NSLock()
        private var counters: [String: FlushCounter] = [:]

        static func install() {
            ContainerLogFollower.onBatchFlush = { FlushHub.shared.forward($0) }
        }

        func register(_ counter: FlushCounter, nativeId: String) {
            lock.lock()
            counters[nativeId] = counter
            lock.unlock()
        }

        func unregister(nativeId: String) {
            lock.lock()
            counters[nativeId] = nil
            lock.unlock()
        }

        private func forward(_ nativeId: String) {
            lock.lock()
            let counter = counters[nativeId]
            lock.unlock()
            counter?.record(nativeId)
        }
    }

    @Test("a newline-free burst beyond the pending bound is discarded, not buffered")
    func oversizedPartialLineIsDiscarded() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        // A single line larger than maxPendingLineBytes, completed and
        // followed by a normal line: the oversized line is unjournaled (its
        // timestamps fall back to read time) but must not accumulate in
        // memory, and the following line still gets journaled.
        let giant = Data(repeating: 0x78, count: ContainerLogFollower.maxPendingLineBytes + (1 << 18))
        var contents = giant
        contents.append(Data("\nafter\n".utf8))
        FileManager.default.createFile(atPath: logFile.path, contents: contents)

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "oversize-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        let journaled = await waitFor {
            await journal.entries(nativeId: "oversize-ctr").count >= 1
        }
        #expect(journaled)
        let entries = await journal.entries(nativeId: "oversize-ctr")
        #expect(entries.count == 2, "one gap marker plus the following line")
        #expect(entries[0].isGapMarker, "the oversized line's payload is never retained — only a gap marker")
        #expect(entries[1].bytes == Data("after\n".utf8), "the following line must be journaled")

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "oversize-ctr")
            return !armed
        }
    }

    // MARK: - Oversized-line gap markers

    /// Seeds `journal` with mixed entries (lines and gap markers) under
    /// epoch 1, then returns the instance a resumed follower would use.
    private func seedJournal(dir: URL, nativeId: String, entries: [ContainerLogJournal.Entry]) async
        -> ContainerLogJournal
    {
        let seeder = ContainerLogJournal()
        await seeder.configure(storageDirectory: dir)
        await seeder.beginBoot(nativeId: nativeId, epoch: 1)
        await seeder.append(nativeId: nativeId, epoch: 1, entries)
        let resumed = ContainerLogJournal()
        await resumed.configure(storageDirectory: dir)
        return resumed
    }

    @Test("an oversized line spanning a read gap journals one gap marker, not a bogus tail line")
    func oversizedLineAcrossReadGapRecordsMarker() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let writer = try FileHandle(forWritingTo: logFile)

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared

        // Head of an oversized line: written alone so the follower's first
        // read pass consumes and discards it, then hits a read gap (empty
        // read) before the line's tail arrives — the discard state must
        // survive the gap (it used to reset per read pass, which journaled
        // the later tail fragment as a complete line).
        try writer.write(contentsOf: Data(repeating: 0x78, count: ContainerLogFollower.maxPendingLineBytes + (1 << 18)))

        await registry.arm(
            nativeId: "gap-marker-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )
        // Let at least one full poll pass consume the head (the follower
        // polls every 150ms; a pass that read data re-polls immediately, so
        // a gap of several poll intervals guarantees the read gap happened).
        try await Task.sleep(for: .milliseconds(600))
        try writer.write(contentsOf: Data("tail-fragment\nafter\n".utf8))

        let journaled = await waitFor {
            await journal.entries(nativeId: "gap-marker-ctr").contains { $0.bytes == Data("after\n".utf8) }
        }
        #expect(journaled, "the line after the oversized one must be journaled")

        let entries = await journal.entries(nativeId: "gap-marker-ctr")
        #expect(entries.count == 2, "exactly one gap marker plus the following line — no bogus tail-fragment line")
        #expect(entries[0].isGapMarker, "the discarded oversized line is recorded as a gap marker")
        #expect(entries[1].bytes == Data("after\n".utf8))
        #expect(!entries.contains { $0.bytes == Data("tail-fragment\n".utf8) })

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "gap-marker-ctr")
            return !armed
        }
    }

    @Test("a resumed follower consumes the persisted gap marker without duplicating it")
    func resumeConsumesPersistedGapMarker() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        // The whole current boot's output: one oversized line (discarded,
        // recorded as a gap marker before the daemon restart) plus two
        // normal lines the journal already covers.
        var contents = Data(repeating: 0x78, count: ContainerLogFollower.maxPendingLineBytes + (1 << 18))
        contents.append(Data("\ncovered\nmore\n".utf8))
        FileManager.default.createFile(atPath: logFile.path, contents: contents)

        let journal = await seedJournal(
            dir: dir, nativeId: "resume-marker-ctr",
            entries: [
                ContainerLogJournal.Entry.gapMarker(unixNano: 111),
                ContainerLogJournal.Entry(unixNano: 222, streamType: 1, bytes: Data("covered\n".utf8)),
                ContainerLogJournal.Entry(unixNano: 333, streamType: 1, bytes: Data("more\n".utf8)),
            ])

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "resume-marker-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        // The resumed follower re-reads the oversized line, must consume the
        // persisted marker (not append a second one, not misalign the
        // covered entries behind it) and journal nothing new. Give the
        // resume a poll pass to process the stream, then stop the container.
        try await Task.sleep(for: .milliseconds(600))
        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "resume-marker-ctr")
            return !armed
        }

        let entries = await journal.entries(nativeId: "resume-marker-ctr")
        #expect(entries.count == 3, "one marker plus the two covered lines — no duplicate marker, no re-journaled lines")
        #expect(entries[0].isGapMarker)
        #expect(entries[0].unixNano == 111, "the persisted marker is consumed, not replaced")
        #expect(Array(entries.map(\.bytes).suffix(2)) == [Data("covered\n".utf8), Data("more\n".utf8)])
    }

    @Test("a resumed follower does not re-mark an oversized line whose marker the cap evicted")
    func resumeWithEvictedMarkerDoesNotDuplicate() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        // The boot's output: one oversized line whose gap marker the cap
        // EVICTED (only the dropped-lines count accounts it) plus one
        // normal line the journal retains.
        var contents = Data(repeating: 0x78, count: ContainerLogFollower.maxPendingLineBytes + (1 << 18))
        contents.append(Data("\ncovered\n".utf8))
        FileManager.default.createFile(atPath: logFile.path, contents: contents)

        let journal = await seedJournal(
            dir: dir, nativeId: "resume-evicted-marker-ctr",
            lines: [(222, "covered\n")], droppedLines: 1)

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "resume-evicted-marker-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        // The resumed follower re-reads the oversized line: the evicted
        // prefix already accounts it, so NO marker may be appended — a
        // duplicate marker would double-count its ordinal and misalign the
        // covered line behind it. Give the resume a poll pass to process
        // the stream, then stop the container.
        try await Task.sleep(for: .milliseconds(600))
        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "resume-evicted-marker-ctr")
            return !armed
        }

        let entries = await journal.entries(nativeId: "resume-evicted-marker-ctr")
        #expect(
            entries.count == 1,
            "no duplicate marker for the evicted oversized line, no re-journaled covered line")
        #expect(!entries.contains { $0.isGapMarker }, "the evicted prefix already accounts the oversized line")
        #expect(entries.first?.bytes == Data("covered\n".utf8))
    }

    // MARK: - Stale-journal heal ordering

    @Test("a stale journal is reset on first mismatch, so no replacement line is lost to the wipe")
    func staleJournalHealKeepsEveryReplacementLine() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        // 300 lines none of which match the stale journal's entry: the old
        // end-of-read heal flushed the first 256 into the stale journal,
        // wiped them with beginBoot, and kept only the last 44 — losing
        // historical timestamp filtering for the rest.
        let lines = (1...300).map { "line\($0)\n" }
        FileManager.default.createFile(atPath: logFile.path, contents: Data(lines.joined().utf8))
        let journal = await seedJournal(
            dir: dir, nativeId: "heal-order-ctr",
            entries: [
                ContainerLogJournal.Entry(unixNano: 111, streamType: 1, bytes: Data("stale boot\n".utf8))
            ])

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "heal-order-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        let journaled = await waitFor {
            await journal.entries(nativeId: "heal-order-ctr").count >= 300
        }
        #expect(journaled, "every line of the read must land in the replacement journal")
        let entries = await journal.entries(nativeId: "heal-order-ctr")
        #expect(entries.map(\.bytes) == lines.map { Data($0.utf8) }, "no line may be flushed into the stale journal and wiped")

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "heal-order-ctr")
            return !armed
        }
    }

    @Test("a stale journal with a matching prefix accounts the consumed prefix as dropped")
    func staleJournalHealAccountsConsumedPrefix() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        // The stale journal's first line coincidentally matches this boot's
        // first line (identical boot banners are common); the second does
        // not. The heal must reset on the mismatch AND account the consumed
        // prefix line as dropped, so a scan from byte zero still aligns the
        // retained suffix.
        let stream = Data("same banner\ndiverges\nthird\n".utf8)
        FileManager.default.createFile(atPath: logFile.path, contents: stream)
        let journal = await seedJournal(
            dir: dir, nativeId: "heal-prefix-ctr",
            entries: [
                ContainerLogJournal.Entry(unixNano: 100, streamType: 1, bytes: Data("same banner\n".utf8)),
                ContainerLogJournal.Entry(unixNano: 111, streamType: 1, bytes: Data("stale boot\n".utf8)),
            ])

        let stampBefore = ContainerLogJournal.currentUnixNano()
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "heal-prefix-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        let journaled = await waitFor {
            await journal.entries(nativeId: "heal-prefix-ctr").map(\.bytes)
                == [Data("diverges\n".utf8), Data("third\n".utf8)]
        }
        #expect(journaled)
        let stampAfter = ContainerLogJournal.currentUnixNano()
        let contents = await journal.contents(nativeId: "heal-prefix-ctr")
        #expect(contents.droppedLines == 1, "the covered prefix line is accounted as dropped, not silently orphaned")

        // End to end: a windowed scan over the same stream recovers the
        // replacement entries' timestamps (their real arrival times, inside
        // [stampBefore, stampAfter]) — without the accounted prefix the
        // first retained entry would be matched against the banner, fail,
        // and disable recovery for everything after it (all lines would
        // fall back to read time 999, which `since` drops).
        var offset = 0
        var payloads: [String] = []
        _ = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < stream.count else { return nil }
                let next = min(offset + 16, stream.count)
                defer { offset = next }
                return stream[offset..<next]
            },
            journal: ContainerLogJournal.Contents(entries: contents.entries, droppedLines: contents.droppedLines),
            since: stampBefore - 1,
            until: stampAfter,
            tail: nil,
            ttyMode: true,
            timestamps: false,
            nowNanos: { 999 },
            streamEnded: true
        ) { frame in
            var frame = frame
            payloads.append(String(decoding: frame.readData(length: frame.readableBytes)!, as: UTF8.self))
        }
        #expect(payloads == ["diverges\n", "third\n"], "the retained suffix must stay timestamp-recoverable after the heal")

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "heal-prefix-ctr")
            return !armed
        }
    }

    /// A stale journal meeting an oversized line followed by a mismatching
    /// normal line: the heal counts the oversized line as dropped, so the
    /// gap marker recorded for it against the stale journal must be cleared
    /// — surviving into the replacement journal it double-counted the line's
    /// ordinal and made the mismatching line skip as evicted, losing its
    /// recorded timestamp.
    @Test("a stale journal heal clears pending gap markers so an oversized line counts once")
    func staleJournalHealClearsPendingGapMarkers() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        var contents = Data(repeating: 0x78, count: ContainerLogFollower.maxPendingLineBytes + (1 << 18))
        contents.append(Data("\ndiverges\nthird\n".utf8))
        FileManager.default.createFile(atPath: logFile.path, contents: contents)
        let journal = await seedJournal(
            dir: dir, nativeId: "heal-marker-ctr",
            entries: [
                ContainerLogJournal.Entry(unixNano: 111, streamType: 1, bytes: Data("stale boot\n".utf8))
            ])

        let stampBefore = ContainerLogJournal.currentUnixNano()
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "heal-marker-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        let journaled = await waitFor {
            await journal.entries(nativeId: "heal-marker-ctr").map(\.bytes)
                == [Data("diverges\n".utf8), Data("third\n".utf8)]
        }
        #expect(journaled)
        let stampAfter = ContainerLogJournal.currentUnixNano()
        let healed = await journal.contents(nativeId: "heal-marker-ctr")
        #expect(
            !healed.entries.contains { $0.isGapMarker },
            "the oversized line is accounted by droppedLines alone — a surviving marker would double-count its ordinal")
        #expect(healed.droppedLines == 1)

        // End to end: windowed replay over the same stream keeps the
        // replacement lines' timestamps — with a surviving marker,
        // "diverges" mismatches it, alignment fails, and both lines fall
        // back to read time 999, which since drops.
        var offset = 0
        var payloads: [String] = []
        _ = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < contents.count else { return nil }
                // 4096-byte chunks, like the route's real reads: tiny chunks
                // make the newline-free head's rescan of `pending` quadratic
                // (each chunk rescans the whole unterminated buffer).
                let next = min(offset + 4096, contents.count)
                defer { offset = next }
                return contents[offset..<next]
            },
            journal: ContainerLogJournal.Contents(entries: healed.entries, droppedLines: healed.droppedLines),
            since: stampBefore - 1,
            until: stampAfter,
            tail: nil,
            ttyMode: true,
            timestamps: false,
            nowNanos: { 999 },
            streamEnded: true
        ) { frame in
            var frame = frame
            payloads.append(String(decoding: frame.readData(length: frame.readableBytes)!, as: UTF8.self))
        }
        #expect(payloads == ["diverges\n", "third\n"], "the retained suffix must stay timestamp-recoverable after the heal")

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "heal-marker-ctr")
            return !armed
        }
    }

    // MARK: - Attach-bootstrap fresh-boot registration (review round 5)

    /// The attach routes' bootstrap performs the container's boot, so IT must
    /// register the fresh log boot: the /start the CLI sends next sees the
    /// container already running and arms with freshBoot false. When the new
    /// boot's startup lines are IDENTICAL to the previous boot's (same
    /// banner), the resume alignment classifies them covered and they keep
    /// the old boot's timestamps — a coincidence the first-mismatch
    /// self-heal can never catch.
    @Test("an attach bootstrap's fresh-boot arm restamps identical banners; the later no-op /start keeps them")
    func attachBootstrapFreshBootRestampsIdenticalBanners() async throws {
        let dir = tempDirectory()
        // The previous boot's journal, persisted: its banner stamped at 111.
        let journal = await seedJournal(dir: dir, nativeId: "attach-fresh-ctr", lines: [(111, "boot banner\n")])
        // The new boot writes the SAME banner (Apple truncated the log, the
        // content repeats) — the exact case the self-heal misses.
        let logFile = dir.appendingPathComponent("attach-fresh.log")
        FileManager.default.createFile(atPath: logFile.path, contents: Data("boot banner\n".utf8))

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared

        // What the attach route's bootstrap registers: a FRESH boot.
        let stampBefore = ContainerLogJournal.currentUnixNano()
        await registry.arm(
            nativeId: "attach-fresh-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )
        let restamped = await waitFor {
            let entries = await journal.entries(nativeId: "attach-fresh-ctr")
            return entries.count == 1 && entries.first!.unixNano >= stampBefore
        }
        #expect(restamped, "the fresh-boot arm must reset the journal and restamp the identical banner")

        // What the CLI's later /start does on the now-running container: a
        // no-op arm (freshBoot false) that must leave the current-boot
        // follower and its timestamps alone.
        await registry.arm(
            nativeId: "attach-fresh-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )
        try await Task.sleep(for: .milliseconds(300))
        let afterStart = await journal.entries(nativeId: "attach-fresh-ctr")
        #expect(
            afterStart.count == 1 && afterStart.first!.unixNano >= stampBefore,
            "the no-op /start arm must not reset or restamp the boot the attach bootstrap registered")

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "attach-fresh-ctr")
            return !armed
        }

        // The contrast — the pre-fix behavior this test pins out: arming the
        // identical banner as a plain resume (what happened when only the
        // no-op /start armed) classifies it covered and keeps the stale 111
        // stamp, so a recent --since would omit the new boot's output.
        let staleJournal = await seedJournal(dir: dir, nativeId: "attach-stale-ctr", lines: [(111, "boot banner\n")])
        let staleLog = dir.appendingPathComponent("attach-stale.log")
        FileManager.default.createFile(atPath: staleLog.path, contents: Data("boot banner\n".utf8))
        await registry.arm(
            nativeId: "attach-stale-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: staleJournal,
            openLogStream: { _ in try FileHandle(forReadingFrom: staleLog) }
        )
        try await Task.sleep(for: .milliseconds(300))
        let staleEntries = await staleJournal.entries(nativeId: "attach-stale-ctr")
        #expect(
            staleEntries.count == 1 && staleEntries.first?.unixNano == 111,
            "without the fresh-boot registration the identical banner inherits the previous boot's stamp")

        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "attach-stale-ctr")
            return !armed
        }
    }

    // MARK: - Cancellation inside the drain loop (review round 5)

    /// A noisy container keeps data available faster than it is read, so the
    /// drain loop never reaches a read gap on its own: a cancelled (disarmed
    /// or superseded) follower must stop draining at the next chunk instead
    /// of reading and journaling alongside its replacement indefinitely.
    @Test("a cancelled follower stops draining a log that keeps growing")
    func cancelledFollowerStopsDraining() async throws {
        let dir = tempDirectory()
        // This test's log grows ~100 MB even when it runs cleanly: remove
        // the directory so repeated local runs do not accumulate gigabytes
        // in the system temp directory.
        defer { try? FileManager.default.removeItem(at: dir) }
        let logFile = dir.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let writer = try FileHandle(forWritingTo: logFile)

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let nativeId = "cancel-drain-ctr"

        // Appends to the log faster than the follower drains, so the drain
        // loop's read gap (EOF) never arrives while this runs — the exact
        // shape of a container writing faster than it is read. The loop is
        // PACED and hard-capped: an unpaced, unbounded variant wrote ~2 GB/s
        // of "spam" — on CI's starved 3-core runners the synchronization
        // window (waitFor + settle sleeps) stretched to tens of seconds, the
        // writer filled the runner's disk, and `make test` plus the runner's
        // own logger died with ENOSPC (job logs lost — pr-check red on
        // 6e3016d, three attempts). ~40 KiB per 1 ms yields ~40 MB/s, still
        // far above the follower's journaling throughput, so the busy-stream
        // premise holds; the 64 MiB cap only engages on a pathologically
        // slow run whose premise is already gone.
        let writerTask = Task.detached {
            let block = Data(String(repeating: "spam\n", count: 8192).utf8)  // ~40 KiB per write
            let budgetBytes = 64 * 1024 * 1024
            var written = 0
            while !Task.isCancelled, written < budgetBytes {
                try? writer.write(contentsOf: block)
                written += block.count
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: nativeId,
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )
        let started = await waitFor { await journal.entries(nativeId: nativeId).count >= 1 }
        #expect(started, "the follower should journal the growing log promptly")

        // The delete-path teardown: cancels the follower task.
        await registry.disarm(nativeId: nativeId)

        // At most one in-flight batch may flush after the cancel; after that
        // the journal must go quiet even though the log keeps growing.
        try await Task.sleep(for: .milliseconds(500))
        let settled = await journal.entries(nativeId: nativeId).count
        try await Task.sleep(for: .milliseconds(500))
        let after = await journal.entries(nativeId: nativeId).count
        #expect(
            after == settled,
            "a cancelled follower must stop draining a busy stream — the superseded task cannot keep reading and journaling")

        writerTask.cancel()
        _ = await writerTask.value
        try? writer.close()
    }

    // MARK: - Final unterminated line (review round 5)

    /// `printf hello` and exit: the confirmed-exit drain must journal the
    /// final unterminated line (stamped with the drain time), or a windowed
    /// read can only stamp that fragment with the CURRENT read time — an
    /// `--until` after the exit but before the request then returns nothing.
    /// A resume re-reading the same exit classifies the fragment covered and
    /// must not duplicate it.
    @Test("the confirmed-exit drain journals the final unterminated line, once")
    func exitDrainJournalsFinalUnterminatedLine() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logFile.path, contents: Data("hello".utf8))

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared

        let before = ContainerLogJournal.currentUnixNano()
        await registry.arm(
            nativeId: "final-line-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )
        client.stopContainer()
        let finished = await waitFor {
            let armed = await registry.isArmed(nativeId: "final-line-ctr")
            return !armed
        }
        #expect(finished, "the follower should wind down after the exit drain")

        let entries = await journal.entries(nativeId: "final-line-ctr")
        #expect(entries.map(\.bytes) == [Data("hello".utf8)], "the final unterminated line must be journaled at exit")
        #expect(entries.first!.unixNano >= before, "stamped with its exit-drain arrival time")

        // A resumed follower (daemon restart) re-reading the same exit: the
        // fragment classifies covered and must not be journaled again.
        await registry.arm(
            nativeId: "final-line-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "final-line-ctr")
            return !armed
        }
        let resumed = await journal.entries(nativeId: "final-line-ctr")
        #expect(resumed.count == 1, "the resumed exit drain must not duplicate the final line")
    }

    // MARK: - Review round 6

    /// Whether `fd` is closed (or was recycled to a different file —
    /// comparing only the fd number races against a concurrent open reusing
    /// it, so the inode decides). Probing a closed FileHandle's
    /// `fileDescriptor` raises an NSException on Darwin; the raw fd does not.
    private func fdIsClosed(_ fd: Int32, ofFileAt url: URL) -> Bool {
        if fcntl(fd, F_GETFD) == -1 { return true }
        var current = stat()
        guard fstat(fd, &current) == 0 else { return true }
        var expected = stat()
        guard stat(url.path, &expected) == 0 else { return true }
        return current.st_ino != expected.st_ino || current.st_dev != expected.st_dev
    }

    @Test("Apple's extra log handles (the bootlog) are closed, not leaked")
    func selectLogHandleClosesExtras() throws {
        let dir = tempDirectory()
        let logPath = dir.appendingPathComponent("container.log")
        let bootPath = dir.appendingPathComponent("boot.log")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        FileManager.default.createFile(atPath: bootPath.path, contents: nil)

        // Mirror how Apple's handles arrive: FileHandles over raw fds with
        // closeOnDealloc:false — closing them is the caller's job.
        let logFD = open(logPath.path, O_RDONLY)
        let bootFD = open(bootPath.path, O_RDONLY)
        #expect(logFD >= 0 && bootFD >= 0)
        let log = FileHandle(fileDescriptor: logFD, closeOnDealloc: false)
        let boot = FileHandle(fileDescriptor: bootFD, closeOnDealloc: false)

        // Apple Container 1.2.2 returns [containerLog, bootlog], both with
        // closeOnDealloc:false — taking .first and dropping the array leaked
        // one descriptor per follower arm, and repeated restarts exhausted
        // the daemon's fd limit.
        let selected = ContainerLogFollower.selectLogHandle([log, boot])
        #expect(selected === log)
        #expect(fdIsClosed(bootFD, ofFileAt: bootPath), "the unused bootlog handle must be closed")
        #expect(!fdIsClosed(logFD, ofFileAt: logPath), "the container log handle stays open for reading")
        close(logFD)
    }

    @Test("payload-heavy batches flush on framed bytes, not only on line count")
    func boundedBatchJournalingByBytes() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        // Six 256 KiB lines: far below the 256-line count bound, but 1.5 MiB
        // total crosses the 1 MiB batch-byte bound mid-read. The count-only
        // check let ~256 MiB of large-line payload accumulate per follower
        // before the journal's 4 MiB cap ever ran.
        let line = Data(repeating: 0x78, count: 256 * 1024) + Data("\n".utf8)
        var contents = Data()
        for _ in 0..<6 { contents.append(line) }
        FileManager.default.createFile(atPath: logFile.path, contents: contents)

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let flushCounter = FlushCounter(nativeId: "byte-batch-ctr")
        FlushHub.install()
        FlushHub.shared.register(flushCounter, nativeId: "byte-batch-ctr")
        defer { FlushHub.shared.unregister(nativeId: "byte-batch-ctr") }

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "byte-batch-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        // Wait for the journal AND the flush notifications TOGETHER — see
        // the line-count batching test for why observing entries alone does
        // not imply the notification has run yet.
        let journaled = await waitFor {
            await journal.entries(nativeId: "byte-batch-ctr").count >= 6 && flushCounter.currentCount() >= 2
        }
        #expect(journaled, "the whole backlog should be journaled")
        #expect(
            flushCounter.currentCount() >= 2,
            "payload-heavy batches must flush on the byte bound mid-read, not accumulate until EOF")

        client.stopContainer()
        let finished = await waitFor {
            let armed = await registry.isArmed(nativeId: "byte-batch-ctr")
            return !armed
        }
        #expect(finished)
    }

    @Test("a failed status lookup is retried, not treated as the container's exit")
    func statusLookupFailureRetries() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let writer = try FileHandle(forWritingTo: logFile)

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "lookup-error-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        // The status lookup starts failing (the Apple API service stays
        // unavailable through a reconnect retry) while the VM keeps running.
        // The old try? collapsed the error into nil — a "confirmed" exit —
        // permanently ending the follower and its timestamping.
        client.failContainerLookups()
        try writer.write(contentsOf: Data("during-outage\n".utf8))
        let journaled = await waitFor {
            await journal.entries(nativeId: "lookup-error-ctr").contains {
                $0.bytes == Data("during-outage\n".utf8)
            }
        }
        #expect(journaled, "output written during the outage must still be journaled")

        // Several poll intervals with the lookup failing: the follower must
        // still be armed (retrying), not wound down as if the container had
        // exited.
        try await Task.sleep(for: .milliseconds(600))
        let stillArmed = await registry.isArmed(nativeId: "lookup-error-ctr")
        #expect(stillArmed, "a failed lookup must not end the follower while the container may still be running")

        // The service recovers: journaling continues where it left off.
        client.recoverContainerLookups()
        try writer.write(contentsOf: Data("after-recovery\n".utf8))
        let recovered = await waitFor {
            await journal.entries(nativeId: "lookup-error-ctr").contains {
                $0.bytes == Data("after-recovery\n".utf8)
            }
        }
        #expect(recovered, "journaling must continue once the lookup outage lifts")

        // A real stop still ends the follower, with the exit drain.
        client.stopContainer()
        try writer.write(contentsOf: Data("final\n".utf8))
        let finished = await waitFor {
            let armed = await registry.isArmed(nativeId: "lookup-error-ctr")
            return !armed
        }
        #expect(finished)
        let entries = await journal.entries(nativeId: "lookup-error-ctr")
        #expect(entries.map(\.bytes).contains(Data("final\n".utf8)), "the exit drain still journals the final line")
    }

    @Test("an oversized line before a stale journal's retained line invalidates and heals")
    func oversizedLineBeforeStaleRetainedLineHeals() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        // The stale journal retained "banner\n" with an old timestamp; the
        // new boot's stream has an oversized line followed by the SAME banner
        // text. consumeGapMarker used to return .fresh for the retained
        // non-marker entry without failing alignment, so the new banner
        // matched the stale retained entry and inherited its old timestamp.
        let giant = Data(repeating: 0x78, count: ContainerLogFollower.maxPendingLineBytes + (1 << 18))
        var contents = giant
        contents.append(Data("\nbanner\n".utf8))
        FileManager.default.createFile(atPath: logFile.path, contents: contents)

        let before = ContainerLogJournal.currentUnixNano()
        let journal = await seedJournal(
            dir: dir,
            nativeId: "stale-oversized-ctr",
            entries: [ContainerLogJournal.Entry(unixNano: 100, streamType: 1, bytes: Data("banner\n".utf8))]
        )

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "stale-oversized-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,  // resume: adopts the persisted (stale) journal
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        let healed = await waitFor {
            await journal.contents(nativeId: "stale-oversized-ctr").entries.contains {
                $0.bytes == Data("banner\n".utf8) && $0.unixNano >= before
            }
        }
        #expect(healed, "the banner line must be re-journaled with a fresh timestamp after the heal")

        let contentsAfter = await journal.contents(nativeId: "stale-oversized-ctr")
        #expect(
            contentsAfter.entries.map(\.bytes) == [Data("banner\n".utf8)],
            "the healed journal holds only the re-stamped banner — no surviving gap marker, no stale copy")
        #expect(
            contentsAfter.droppedLines == 1,
            "the consumed oversized line is accounted in the replacement's dropped prefix")

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "stale-oversized-ctr")
            return !armed
        }
    }

    // MARK: - Review round 7

    /// A resumed stream of ONLY oversized lines never runs the ordinary-line
    /// branch that self-heals a stale journal: the mismatch surfaces inside
    /// `markOversizedLine` (a retained ORDINARY entry where the gap marker
    /// should be), and healing must happen THERE — without it the marker lands
    /// behind the stale entries, alignment stays broken, and later windowed
    /// reads fall back to read time for everything. The line itself is
    /// accounted by the heal's dropped-lines count, like the ordinary-line
    /// heal.
    @Test("a resumed stream of only oversized lines heals the stale journal before recording its marker")
    func oversizedOnlyResumeHealsStaleJournal() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        // The new boot's output is a single newline-free line far past the
        // pending bound: its head is discarded mid-read and its (empty) tail is
        // finalized at the confirmed-exit drain — no ordinary line ever fires
        // the classify-based heal.
        FileManager.default.createFile(
            atPath: logFile.path,
            contents: Data(repeating: 0x78, count: ContainerLogFollower.maxPendingLineBytes + (1 << 18)))
        // The stale journal retains an ordinary entry at the head — exactly
        // where the oversized line's marker consumption expects a marker.
        let journal = await seedJournal(
            dir: dir, nativeId: "oversized-heal-ctr",
            entries: [ContainerLogJournal.Entry(unixNano: 111, streamType: 1, bytes: Data("stale boot\n".utf8))])

        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "oversized-heal-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: false,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        try await Task.sleep(for: .milliseconds(600))
        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "oversized-heal-ctr")
            return !armed
        }

        let contents = await journal.contents(nativeId: "oversized-heal-ctr")
        #expect(
            contents.entries.isEmpty,
            "the stale journal must be healed — its ordinary entry must not survive behind a marker")
        #expect(
            !contents.entries.contains { $0.bytes == Data("stale boot\n".utf8) },
            "the stale boot's entry must not lend its timestamps to the new boot's lines")
        #expect(
            contents.droppedLines == 1,
            "the consumed oversized line is accounted in the replacement's dropped prefix")
    }

    /// The journal's cached writer is released when the follower finishes — the
    /// follower closes its Apple log handle at exit, but the writer would
    /// otherwise stay open until the next reset, trim or deletion. Starting and
    /// stopping containers without deleting them must not accumulate one
    /// descriptor per stopped container.
    @Test("the journal's cached writer closes when the follower finishes; entries are retained")
    func followerExitClosesJournalWriter() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logFile.path, contents: Data("hello\n".utf8))

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "writer-close-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )

        let journaled = await waitFor {
            await journal.entries(nativeId: "writer-close-ctr").count >= 1
        }
        #expect(journaled)
        #expect(
            await journal.writerIsOpen(nativeId: "writer-close-ctr"),
            "the writer is open while the follower runs")

        client.stopContainer()
        let finished = await waitFor {
            let armed = await registry.isArmed(nativeId: "writer-close-ctr")
            return !armed
        }
        #expect(finished)
        let writerOpen = await journal.writerIsOpen(nativeId: "writer-close-ctr")
        #expect(
            !writerOpen,
            "the follower's exit must release the journal's cached writer — one leaked descriptor per stopped container exhausts the fd limit")
        #expect(
            await journal.entries(nativeId: "writer-close-ctr").map(\.bytes) == [Data("hello\n".utf8)],
            "the entries stay for later windowed reads")
    }

    /// Epochs order ARMS, not boots: a `/start` delayed in post-start setup can
    /// arm after a newer `/restart` already booted the container and armed its
    /// follower. The delayed arm carries the OLDER boot's `startedDate` and must
    /// be rejected — pre-fix it received a higher epoch, cancelled the newer
    /// boot's follower and wiped its journal.
    @Test("an arm for an older boot than the armed follower's is rejected")
    func staleBootArmIsRejected() async throws {
        let dir = tempDirectory()
        let newLogFile = dir.appendingPathComponent("new-boot.log")
        let oldLogFile = dir.appendingPathComponent("old-boot.log")
        FileManager.default.createFile(atPath: newLogFile.path, contents: Data("new boot\n".utf8))
        FileManager.default.createFile(atPath: oldLogFile.path, contents: Data("old boot\n".utf8))

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared
        let newerBoot = Date(timeIntervalSince1970: 2_000_000_000)
        let olderBoot = Date(timeIntervalSince1970: 1_000_000_000)

        // A /restart boots at `newerBoot` and arms its follower over its boot's
        // log stream.
        await registry.arm(
            nativeId: "stale-arm-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            bootStartedAt: newerBoot,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: newLogFile) }
        )
        let journaled = await waitFor {
            await journal.entries(nativeId: "stale-arm-ctr").count >= 1
        }
        #expect(journaled)

        // The delayed /start finally arms — for the OLDER boot it transitioned,
        // over that boot's (already superseded) log stream. It must be rejected
        // outright: accepting it would cancel the newer follower and journal
        // the old boot's stream over the new boot's timestamps.
        await registry.arm(
            nativeId: "stale-arm-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            bootStartedAt: olderBoot,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: oldLogFile) }
        )
        // Give a wrongly-accepted stale follower time to journal its stream.
        try await Task.sleep(for: .milliseconds(400))
        let entries = await journal.entries(nativeId: "stale-arm-ctr")
        #expect(
            entries.map(\.bytes) == [Data("new boot\n".utf8)],
            "the newer boot's journal must survive the stale arm untouched — no old-boot output, no reset")

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "stale-arm-ctr")
            return !armed
        }
    }

    /// `arm()` activates the journal BEFORE it returns: the route answers right
    /// after, and an immediately-issued windowed logs request reads the journal
    /// synchronously — if the reset still lived in the detached follower task,
    /// the request could see the previous boot's journal and match repeated
    /// startup lines against its old timestamps.
    @Test("arm() resets the journal before returning — an immediate windowed read cannot see the previous boot")
    func armActivatesJournalBeforeReturning() async throws {
        let dir = tempDirectory()
        // An EMPTY log stream: the follower can never journal anything, so the
        // assertion below is deterministic — whatever it sees is arm()'s own
        // activation, not a race with the follower's first read.
        let logFile = dir.appendingPathComponent("empty.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)

        let journal = await seedJournal(dir: dir, nativeId: "arm-activation-ctr", lines: [(111, "boot banner\n")])
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared

        await registry.arm(
            nativeId: "arm-activation-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )
        // No waitFor: the previous boot's journal must already be gone the
        // moment arm() returns.
        let entries = await journal.entries(nativeId: "arm-activation-ctr")
        #expect(entries.isEmpty, "the previous boot's journal must be reset before arm() returns")

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "arm-activation-ctr")
            return !armed
        }
    }
}
