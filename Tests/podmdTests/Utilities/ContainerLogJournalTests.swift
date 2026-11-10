import Foundation
import Testing

@testable import podmd

/// The timestamped log journal is what makes `docker logs --since/--until`
/// (and accurate historical `--timestamps`) possible: Apple's log stream
/// carries no write-time metadata, so the follower records arrival times
/// here. These tests cover the append/replay round trip, the binary framing,
/// the drop-oldest cap, crash salvage, boot resets, and epoch gating.
@Suite("ContainerLogJournal")
struct ContainerLogJournalTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-journal-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ nano: UInt64, _ line: String) -> ContainerLogJournal.Entry {
        ContainerLogJournal.Entry(unixNano: nano, streamType: 1, bytes: Data(line.utf8))
    }

    private let alwaysCurrent: @Sendable () async -> Bool = { true }
    private let neverCurrent: @Sendable () async -> Bool = { false }

    @Test("append then entries round-trips in stream order")
    func appendReplay() async {
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: tempDirectory())
        await journal.append(
            nativeId: "ctr", epoch: 1,
            [entry(100, "first\n"), entry(200, "second\n")], isCurrentEpoch: alwaysCurrent)
        let replayed = await journal.entries(nativeId: "ctr")
        #expect(replayed.map(\.bytes) == [Data("first\n".utf8), Data("second\n".utf8)])
        #expect(replayed.map(\.unixNano) == [100, 200])
    }

    @Test("entries persist across instances configured on the same directory")
    func persistence() async {
        let dir = tempDirectory()
        let writer = ContainerLogJournal()
        await writer.configure(storageDirectory: dir)
        await writer.append(nativeId: "ctr", epoch: 1, [entry(100, "line\n")], isCurrentEpoch: alwaysCurrent)

        let reader = ContainerLogJournal()
        await reader.configure(storageDirectory: dir)
        let replayed = await reader.entries(nativeId: "ctr")
        #expect(replayed.count == 1)
        #expect(replayed.first?.bytes == Data("line\n".utf8))
        #expect(replayed.first?.unixNano == 100)
    }

    @Test("framing round-trips through encode and parse")
    func framingRoundTrip() {
        let entries = [
            entry(1, "a\n"),
            entry(UInt64.max, "unicode ✓ line\n"),
            entry(42, String(repeating: "x", count: 1000) + "\n"),
        ]
        var file = Data("PDLJ".utf8)
        withUnsafeBytes(of: UInt32(1).littleEndian) { file.append(contentsOf: $0) }
        for e in entries { file.append(ContainerLogJournal.encode(e)) }
        let (parsed, salvaged) = ContainerLogJournal.parse(file)
        #expect(!salvaged)
        #expect(parsed == entries)
    }

    @Test("parse rejects bad magic and salvages a truncated trailing entry")
    func parseSalvage() {
        let good = entry(7, "hello\n")
        var file = Data("PDLJ".utf8)
        withUnsafeBytes(of: UInt32(1).littleEndian) { file.append(contentsOf: $0) }
        file.append(ContainerLogJournal.encode(good))
        // Half of a second record's header — a crash mid-write.
        file.append(Data([0x01, 0x02, 0x03]))

        let (parsed, salvaged) = ContainerLogJournal.parse(file)
        #expect(salvaged)
        #expect(parsed == [good])

        let (bad, badSalvaged) = ContainerLogJournal.parse(Data("NOPEjunkjunkjunkjunkjunkjunkjunk".utf8))
        #expect(badSalvaged)
        #expect(bad.isEmpty)
    }

    @Test("the drop-oldest cap evicts from the front and the file matches memory")
    func capDropOldest() async {
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: tempDirectory())
        // ~94 framed bytes per entry (13-byte header + 81-byte line); fill
        // past the 4 MiB cap.
        let line = String(repeating: "y", count: 80) + "\n"
        let perEntry = ContainerLogJournal.Entry.headerByteCount + line.utf8.count
        var batches: [ContainerLogJournal.Entry] = []
        let entryCount = (ContainerLogJournal.maxJournalBytes / perEntry) + 50
        for i in 0..<entryCount {
            batches.append(entry(UInt64(i), line))
        }
        await journal.append(nativeId: "ctr", epoch: 1, batches, isCurrentEpoch: alwaysCurrent)

        let replayed = await journal.entries(nativeId: "ctr")
        #expect(!replayed.isEmpty)
        #expect(replayed.count < entryCount, "the cap must have evicted entries")
        // Only the OLDEST went: the newest entry survives with its timestamp.
        #expect(replayed.last?.unixNano == UInt64(entryCount - 1))
        #expect(replayed.first!.unixNano > 0, "the earliest entries were dropped")
        let totalFramed = replayed.reduce(0) { $0 + $1.framedByteCount }
        #expect(totalFramed <= ContainerLogJournal.maxJournalBytes)
    }

    @Test("beginBoot drops the previous boot's entries and the file")
    func beginBootResets() async {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.append(nativeId: "ctr", epoch: 1, [entry(100, "old boot\n")], isCurrentEpoch: alwaysCurrent)

        await journal.beginBoot(nativeId: "ctr", epoch: 2, isCurrentEpoch: alwaysCurrent)
        let afterReset = await journal.entries(nativeId: "ctr")
        #expect(afterReset.isEmpty)

        // A fresh instance finds no file at all — the reset hit disk.
        let reloaded = ContainerLogJournal()
        await reloaded.configure(storageDirectory: dir)
        let afterReload = await reloaded.entries(nativeId: "ctr")
        #expect(afterReload.isEmpty)
    }

    @Test("a stale-epoch beginBoot wipes nothing; a stale-epoch append writes nothing")
    func epochGating() async {
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: tempDirectory())
        await journal.append(nativeId: "ctr", epoch: 1, [entry(100, "mine\n")], isCurrentEpoch: alwaysCurrent)

        await journal.beginBoot(nativeId: "ctr", epoch: 1, isCurrentEpoch: neverCurrent)
        let afterStaleBoot = await journal.entries(nativeId: "ctr")
        #expect(afterStaleBoot.count == 1, "stale beginBoot must not wipe")

        await journal.append(nativeId: "ctr", epoch: 1, [entry(200, "intruder\n")], isCurrentEpoch: neverCurrent)
        let afterStaleAppend = await journal.entries(nativeId: "ctr")
        #expect(afterStaleAppend.count == 1, "stale append must not write")
    }

    @Test("remove clears memory and deletes the file")
    func remove() async {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.append(nativeId: "ctr", epoch: 1, [entry(100, "gone\n")], isCurrentEpoch: alwaysCurrent)
        await journal.remove(nativeId: "ctr")
        let afterRemove = await journal.entries(nativeId: "ctr")
        #expect(afterRemove.isEmpty)

        let reloaded = ContainerLogJournal()
        await reloaded.configure(storageDirectory: dir)
        let afterRemoveReload = await reloaded.entries(nativeId: "ctr")
        #expect(afterRemoveReload.isEmpty)
    }

    @Test("alignment recovers journal timestamps and disables on mismatch")
    func alignment() {
        let entries = [entry(100, "a\n"), entry(200, "b\n")]
        var alignment = ContainerLogJournal.Alignment(entries: entries)
        #expect(alignment.timestamp(for: Data("a\n".utf8)) == 100)
        #expect(alignment.timestamp(for: Data("b\n".utf8)) == 200)
        // Beyond the journal: nil (follower behind), alignment stays usable.
        #expect(alignment.timestamp(for: Data("c\n".utf8)) == nil)

        // A mismatch mid-journal disables matching even for later matches.
        var strict = ContainerLogJournal.Alignment(entries: entries)
        #expect(strict.timestamp(for: Data("NOT a\n".utf8)) == nil)
        #expect(strict.timestamp(for: Data("b\n".utf8)) == nil, "alignment must not recover after a mismatch")
    }
}
