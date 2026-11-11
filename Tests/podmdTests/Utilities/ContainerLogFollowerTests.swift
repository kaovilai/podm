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

    /// ClientContainerProtocol mock whose reported status flips on demand.
    private final class StatusFlipMock: ClientContainerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func stopContainer() {
            lock.lock()
            stopped = true
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
        func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
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
    private func waitFor(
        _ condition: () async -> Bool,
        timeout: TimeInterval = 5
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
        ContainerLogFollower.onBatchFlush = flushCounter.record

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
        defer { ContainerLogFollower.onBatchFlush = nil }

        let journaled = await waitFor {
            await journal.entries(nativeId: "batch-ctr").count >= 600
        }
        #expect(journaled, "the whole backlog should be journaled")
        // 600 lines at a 256-line batch size: at least the two in-read
        // flushes plus the final remainder — the single flush-at-EOF of the
        // old unbounded accumulation would count 1.
        #expect(flushCounter.count >= 3, "batches must be flushed mid-read, not accumulated until EOF")

        client.stopContainer()
        let finished = await waitFor {
            let armed = await registry.isArmed(nativeId: "batch-ctr")
            return !armed
        }
        #expect(finished)
    }

    /// Thread-safe flush counter for the `onBatchFlush` seam, scoped to one
    /// native id so parallel followers from other tests do not skew it.
    private final class FlushCounter: @unchecked Sendable {
        private let lock = NSLock()
        private let nativeId: String
        private(set) var count = 0
        init(nativeId: String) { self.nativeId = nativeId }
        func record(_ nativeId: String) {
            guard nativeId == self.nativeId else { return }
            lock.lock()
            count += 1
            lock.unlock()
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
}
