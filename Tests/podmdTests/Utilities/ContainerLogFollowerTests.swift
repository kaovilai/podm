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
    private func seedJournal(dir: URL, nativeId: String, lines: [(nano: UInt64, line: String)]) async
        -> ContainerLogJournal
    {
        let seeder = ContainerLogJournal()
        await seeder.configure(storageDirectory: dir)
        await seeder.beginBoot(nativeId: nativeId, epoch: 1)
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
        #expect(
            await journal.entries(nativeId: "oversize-ctr").map(\.bytes) == [Data("after\n".utf8)],
            "the oversized line must not be journaled; the following line must be")

        client.stopContainer()
        _ = await waitFor {
            let armed = await registry.isArmed(nativeId: "oversize-ctr")
            return !armed
        }
    }
}
