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

    @Test("append then entries round-trips in stream order")
    func appendReplay() async {
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: tempDirectory())
        await journal.beginBoot(nativeId: "ctr", epoch: 1)
        await journal.append(nativeId: "ctr", epoch: 1, [entry(100, "first\n"), entry(200, "second\n")])
        let replayed = await journal.entries(nativeId: "ctr")
        #expect(replayed.map(\.bytes) == [Data("first\n".utf8), Data("second\n".utf8)])
        #expect(replayed.map(\.unixNano) == [100, 200])
    }

    @Test("entries persist across instances configured on the same directory")
    func persistence() async {
        let dir = tempDirectory()
        let writer = ContainerLogJournal()
        await writer.configure(storageDirectory: dir)
        await writer.beginBoot(nativeId: "ctr", epoch: 1)
        await writer.append(nativeId: "ctr", epoch: 1, [entry(100, "line\n")])

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
        withUnsafeBytes(of: UInt32(2).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(7).littleEndian) { file.append(contentsOf: $0) }
        for e in entries { file.append(ContainerLogJournal.encode(e)) }
        let (parsed, droppedLines, _, _, salvaged) = ContainerLogJournal.parse(file)
        #expect(!salvaged)
        #expect(droppedLines == 7)
        #expect(parsed == entries)
    }

    @Test("version-1 files (no dropped-count header) still parse")
    func versionOneBackCompat() {
        let good = entry(7, "hello\n")
        var file = Data("PDLJ".utf8)
        withUnsafeBytes(of: UInt32(1).littleEndian) { file.append(contentsOf: $0) }
        file.append(ContainerLogJournal.encode(good))
        let (parsed, droppedLines, _, _, salvaged) = ContainerLogJournal.parse(file)
        #expect(!salvaged)
        #expect(droppedLines == 0)
        #expect(parsed == [good])
    }

    @Test("version-3 files round-trip the evicted stamps; a truncated stamp section salvages")
    func versionThreeEvictedStamps() {
        let good = entry(7, "hello\n")
        var file = Data("PDLJ".utf8)
        withUnsafeBytes(of: UInt32(3).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(2).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(2).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(100).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(200).littleEndian) { file.append(contentsOf: $0) }
        file.append(ContainerLogJournal.encode(good))
        let (parsed, droppedLines, evictedNanos, _, salvaged) = ContainerLogJournal.parse(file)
        #expect(!salvaged)
        #expect(droppedLines == 2)
        #expect(evictedNanos == [100, 200])
        #expect(parsed == [good])

        // A stamp count running past the file is a truncated header:
        // salvaged to nothing, like a truncated entry.
        var truncated = Data("PDLJ".utf8)
        withUnsafeBytes(of: UInt32(3).littleEndian) { truncated.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(2).littleEndian) { truncated.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(5).littleEndian) { truncated.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(100).littleEndian) { truncated.append(contentsOf: $0) }
        let (_, _, _, _, truncatedSalvaged) = ContainerLogJournal.parse(truncated)
        #expect(truncatedSalvaged)
    }

    @Test("parse rejects bad magic and salvages a truncated trailing entry")
    func parseSalvage() {
        let good = entry(7, "hello\n")
        var file = Data("PDLJ".utf8)
        withUnsafeBytes(of: UInt32(2).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(0).littleEndian) { file.append(contentsOf: $0) }
        file.append(ContainerLogJournal.encode(good))
        // Half of a second record's header — a crash mid-write.
        file.append(Data([0x01, 0x02, 0x03]))

        let (parsed, _, _, _, salvaged) = ContainerLogJournal.parse(file)
        #expect(salvaged)
        #expect(parsed == [good])

        let (bad, _, _, _, badSalvaged) = ContainerLogJournal.parse(Data("NOPEjunkjunkjunkjunkjunkjunkjunk".utf8))
        #expect(badSalvaged)
        #expect(bad.isEmpty)
    }

    @Test("the drop-oldest cap evicts from the front, tracks the evicted count, and the file matches memory")
    func capDropOldest() async {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.beginBoot(nativeId: "ctr", epoch: 1)
        // ~94 framed bytes per entry (13-byte header + 81-byte line); fill
        // past the 4 MiB cap in ONE batch — the first append already exceeds
        // the cap, so the trim path (and its directory creation) runs before
        // the plain append path has ever created the journal directory.
        let line = String(repeating: "y", count: 80) + "\n"
        let perEntry = ContainerLogJournal.Entry.headerByteCount + line.utf8.count
        var batches: [ContainerLogJournal.Entry] = []
        let entryCount = (ContainerLogJournal.maxJournalBytes / perEntry) + 50
        for i in 0..<entryCount {
            batches.append(entry(UInt64(i), line))
        }
        await journal.append(nativeId: "ctr", epoch: 1, batches)

        let contents = await journal.contents(nativeId: "ctr")
        let replayed = contents.entries
        #expect(!replayed.isEmpty)
        #expect(replayed.count < entryCount, "the cap must have evicted entries")
        // Only the OLDEST went: the newest entry survives with its timestamp.
        #expect(replayed.last?.unixNano == UInt64(entryCount - 1))
        #expect(replayed.first!.unixNano > 0, "the earliest entries were dropped")
        let totalFramed = replayed.reduce(0) { $0 + $1.framedByteCount }
        #expect(totalFramed <= ContainerLogJournal.maxJournalBytes)
        #expect(contents.droppedLines == entryCount - replayed.count, "the evicted line count is tracked")

        // The evicted lines' arrival stamps are retained (all of them here —
        // far below the stamp bound) in stream order, so a windowed reader
        // can judge evicted lines by their write time instead of read time.
        #expect(contents.evictedNanos.count == contents.droppedLines, "one retained stamp per evicted line")
        #expect(contents.evictedNanos.first == 0, "the first evicted line's stamp is retained")
        #expect(contents.evictedNanos.last == UInt64(contents.droppedLines - 1), "the last evicted line's stamp is retained")

        // A second instance re-reads the trimmed file from disk: the capped
        // state (entries AND evicted-prefix count AND its stamps) genuinely
        // persisted — the first append exceeded the cap before the directory
        // existed.
        let reloaded = ContainerLogJournal()
        await reloaded.configure(storageDirectory: dir)
        let reloadedContents = await reloaded.contents(nativeId: "ctr")
        #expect(reloadedContents.entries == replayed)
        #expect(reloadedContents.droppedLines == contents.droppedLines)
        #expect(reloadedContents.evictedNanos == contents.evictedNanos, "the evicted stamps persist (header v3)")
    }

    @Test("a small append after a cap trim lands on disk (no stale write handle)")
    func appendAfterTrimPersists() async {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.beginBoot(nativeId: "ctr", epoch: 1)
        // One batch past the cap (trim rewrites the file), then a small batch
        // that must NOT reuse the pre-rewrite write handle.
        let line = String(repeating: "y", count: 80) + "\n"
        let perEntry = ContainerLogJournal.Entry.headerByteCount + line.utf8.count
        let entryCount = (ContainerLogJournal.maxJournalBytes / perEntry) + 50
        await journal.append(
            nativeId: "ctr", epoch: 1, (0..<entryCount).map { entry(UInt64($0), line) })
        await journal.append(nativeId: "ctr", epoch: 1, [entry(UInt64(entryCount), "tail\n")])

        let reloaded = ContainerLogJournal()
        await reloaded.configure(storageDirectory: dir)
        let replayed = await reloaded.entries(nativeId: "ctr")
        #expect(replayed.last?.bytes == Data("tail\n".utf8), "the post-trim append must survive a reload")
        #expect(replayed.last?.unixNano == UInt64(entryCount))
        #expect(replayed.count < entryCount, "the cap still holds")
    }

    @Test("beginBoot drops the previous boot's entries and the file")
    func beginBootResets() async {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.beginBoot(nativeId: "ctr", epoch: 1)
        await journal.append(nativeId: "ctr", epoch: 1, [entry(100, "old boot\n")])

        await journal.beginBoot(nativeId: "ctr", epoch: 2)
        let afterReset = await journal.entries(nativeId: "ctr")
        #expect(afterReset.isEmpty)

        // A fresh instance finds no file at all — the reset hit disk.
        let reloaded = ContainerLogJournal()
        await reloaded.configure(storageDirectory: dir)
        let afterReload = await reloaded.entries(nativeId: "ctr")
        #expect(afterReload.isEmpty)
    }

    @Test("an append after a same-instance beginBoot persists through a reopened handle")
    func appendAfterBeginBootPersists() async {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.beginBoot(nativeId: "ctr", epoch: 1)
        await journal.append(nativeId: "ctr", epoch: 1, [entry(100, "first boot\n")])

        // A new boot on the SAME journal instance: the reset closes the old
        // write handle, and the new State must not carry the closed handle
        // over — or the new boot's appends write through a dead descriptor
        // and survive only in memory until a cap rewrite.
        await journal.beginBoot(nativeId: "ctr", epoch: 2)
        await journal.append(nativeId: "ctr", epoch: 2, [entry(200, "second boot\n")])

        let reloaded = ContainerLogJournal()
        await reloaded.configure(storageDirectory: dir)
        let replayed = await reloaded.entries(nativeId: "ctr")
        #expect(
            replayed.map(\.bytes) == [Data("second boot\n".utf8)],
            "the new boot's entries must hit disk, not just the in-memory state")
    }

    @Test("resumeBoot adopts the persisted journal without dropping entries")
    func resumeBootPreserves() async {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.beginBoot(nativeId: "ctr", epoch: 1)
        await journal.append(nativeId: "ctr", epoch: 1, [entry(100, "same boot\n")])

        // A daemon-restart resume: a NEW journal instance (no in-memory
        // state), a higher epoch, reset NOT requested.
        let resumed = ContainerLogJournal()
        await resumed.configure(storageDirectory: dir)
        await resumed.resumeBoot(nativeId: "ctr", epoch: 2)
        let afterResume = await resumed.entries(nativeId: "ctr")
        #expect(afterResume.map(\.bytes) == [Data("same boot\n".utf8)], "resume must not wipe the journal")

        // The resumed epoch is the accepted writer; the old one is rejected.
        await resumed.append(nativeId: "ctr", epoch: 1, [entry(150, "stale\n")])
        #expect(await resumed.entries(nativeId: "ctr").count == 1, "the superseded epoch must not write")
        await resumed.append(nativeId: "ctr", epoch: 2, [entry(200, "continued\n")])
        #expect(await resumed.entries(nativeId: "ctr").count == 2)
    }

    @Test("an older-epoch beginBoot wipes nothing; a foreign-epoch append writes nothing")
    func epochGating() async {
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: tempDirectory())
        await journal.beginBoot(nativeId: "ctr", epoch: 5)
        await journal.append(nativeId: "ctr", epoch: 5, [entry(100, "mine\n")])

        // A superseded follower (older registry epoch) arriving late.
        await journal.beginBoot(nativeId: "ctr", epoch: 3)
        let afterStaleBoot = await journal.entries(nativeId: "ctr")
        #expect(afterStaleBoot.count == 1, "stale beginBoot must not wipe")

        await journal.append(nativeId: "ctr", epoch: 3, [entry(200, "intruder\n")])
        await journal.append(nativeId: "ctr", epoch: 9, [entry(300, "unactivated\n")])
        let afterStaleAppend = await journal.entries(nativeId: "ctr")
        #expect(afterStaleAppend.count == 1, "only the accepted writer epoch may append")
    }

    @Test("remove tombstones the epoch: a stale follower cannot recreate the journal")
    func removeTombstones() async {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.beginBoot(nativeId: "ctr", epoch: 5)
        await journal.append(nativeId: "ctr", epoch: 5, [entry(100, "gone\n")])
        await journal.remove(nativeId: "ctr")

        // A stale follower that already passed its external gate races the
        // teardown and lands afterward: its writes must be dropped, not
        // recreate the state and the file.
        await journal.append(nativeId: "ctr", epoch: 5, [entry(200, "ghost\n")])
        await journal.beginBoot(nativeId: "ctr", epoch: 5)
        #expect(await journal.entries(nativeId: "ctr").isEmpty, "the torn-down epoch must not resurrect the journal")

        let reloaded = ContainerLogJournal()
        await reloaded.configure(storageDirectory: dir)
        #expect(await reloaded.entries(nativeId: "ctr").isEmpty, "no file may be recreated")

        // A genuinely new lifecycle (strictly higher epoch) may start fresh.
        await journal.beginBoot(nativeId: "ctr", epoch: 6)
        await journal.append(nativeId: "ctr", epoch: 6, [entry(300, "reborn\n")])
        #expect(await journal.entries(nativeId: "ctr").map(\.bytes) == [Data("reborn\n".utf8)])
    }

    @Test("remove clears memory and deletes the file")
    func remove() async {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.beginBoot(nativeId: "ctr", epoch: 1)
        await journal.append(nativeId: "ctr", epoch: 1, [entry(100, "gone\n")])
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
        #expect(strict.failed)
        #expect(strict.timestamp(for: Data("b\n".utf8)) == nil, "alignment must not recover after a mismatch")
    }

    @Test("alignment skips the evicted prefix so a capped journal still recovers timestamps")
    func alignmentSkipsEvictedPrefix() {
        // The journal holds a SUFFIX of the boot's lines (the cap evicted the
        // first two); a reader scanning the log from byte zero must skip the
        // evicted lines and resume matching at the retained suffix.
        let retained = [entry(300, "c\n"), entry(400, "d\n")]
        var alignment = ContainerLogJournal.Alignment(entries: retained, droppedLines: 2)
        #expect(alignment.timestamp(for: Data("a\n".utf8)) == nil, "evicted line: no time, but consumed")
        #expect(alignment.timestamp(for: Data("b\n".utf8)) == nil, "evicted line: no time, but consumed")
        #expect(alignment.timestamp(for: Data("c\n".utf8)) == 300, "retained suffix must align")
        #expect(alignment.timestamp(for: Data("d\n".utf8)) == 400)
        #expect(!alignment.failed)

        // classify() distinguishes evicted (already accounted, a follower
        // must not re-journal) from fresh.
        var classify = ContainerLogJournal.Alignment(entries: retained, droppedLines: 2)
        guard case .evicted = classify.classify(Data("a\n".utf8)) else {
            Issue.record("the first evicted prefix line must classify as evicted")
            return
        }
        guard case .evicted = classify.classify(Data("b\n".utf8)) else {
            Issue.record("the second evicted prefix line must classify as evicted")
            return
        }
        guard case .covered(300) = classify.classify(Data("c\n".utf8)) else {
            Issue.record("the retained suffix line must classify as covered with its timestamp")
            return
        }
    }

    @Test("consumeGapMarker consumes evicted ordinals and distinguishes them from fresh lines")
    func consumeGapMarkerEvictedPrefix() {
        // The cap evicted the oversized line's gap marker: droppedLines
        // accounts the line, and the retained suffix starts at a normal
        // entry. The oversized line's consumption must take the evicted
        // ordinal — or the NEXT retained line would classify as evicted and
        // lose its recorded timestamp.
        let retained = [entry(300, "c\n")]
        var evicted = ContainerLogJournal.Alignment(entries: retained, droppedLines: 1)
        guard case .evicted = evicted.consumeGapMarker() else {
            Issue.record("an oversized line in the evicted prefix must be reported evicted, not fresh")
            return
        }
        #expect(!evicted.failed)
        #expect(evicted.timestamp(for: Data("c\n".utf8)) == 300, "the retained line behind the evicted marker must stay covered")

        // A retained marker at the head still reports its recorded time.
        var withMarker = ContainerLogJournal.Alignment(
            entries: [ContainerLogJournal.Entry.gapMarker(unixNano: 100)] + retained)
        guard case .covered(100) = withMarker.consumeGapMarker() else {
            Issue.record("the retained gap marker must report its recorded time")
            return
        }
        #expect(withMarker.timestamp(for: Data("c\n".utf8)) == 300)

        // Exhaustion — no entry at all, the follower is behind the stream:
        // fresh, alignment usable. (A retained ORDINARY entry at the head is
        // NOT this case: it is a mismatch that must fail alignment — see
        // consumeGapMarkerMismatchInvalidates.)
        var uncovered = ContainerLogJournal.Alignment(entries: [])
        guard case .fresh = uncovered.consumeGapMarker() else {
            Issue.record("an uncovered oversized line must be reported fresh")
            return
        }
        #expect(!uncovered.failed)
    }

    @Test("alignment reports retained stamps for evicted lines, evicted ordinals and the bound fallback")
    func alignmentEvictedStamps() {
        // Two evicted lines with retained stamps 100/200; the retained
        // suffix starts at "c\n".
        let retained = [entry(300, "c\n")]
        var alignment = ContainerLogJournal.Alignment(entries: retained, droppedLines: 2, evictedNanos: [100, 200])
        #expect(alignment.timestamp(for: Data("a\n".utf8)) == 100, "the first evicted line reports its retained stamp")
        #expect(alignment.timestamp(for: Data("b\n".utf8)) == 200, "the second evicted line reports its retained stamp")
        #expect(alignment.timestamp(for: Data("c\n".utf8)) == 300, "the retained suffix still aligns")

        // Evicted ordinals consumed via consumeGapMarker (oversized lines)
        // report the retained stamp too.
        var marker = ContainerLogJournal.Alignment(entries: retained, droppedLines: 1, evictedNanos: [100])
        guard case .evicted(unixNano: 100, isUpperBound: false) = marker.consumeGapMarker() else {
            Issue.record("an evicted ordinal must report its retained stamp, not nil")
            return
        }
        #expect(marker.timestamp(for: Data("c\n".utf8)) == 300)

        // Evictions OLDER than the retained stamp window fall back to the
        // oldest retained stamp — an UPPER BOUND on their write time, so a
        // past `--until` keeps them and a recent `--since` may keep them,
        // never read-time. The bound flag tells the window consumers apart
        // from an exact stamp.
        var old = ContainerLogJournal.Alignment(entries: retained, droppedLines: 5, evictedNanos: [400])
        guard case .evicted(unixNano: 400, isUpperBound: true) = old.classify(Data("ancient\n".utf8)) else {
            Issue.record("an eviction past the stamp window must report the bound")
            return
        }
        #expect(
            old.recordedTime(for: Data("also-ancient\n".utf8))
                == ContainerLogJournal.Alignment.RecordedTime(
                    unixNano: 400, isUpperBound: true))
    }

    // MARK: - Review round 6

    @Test("a damaged dropped-count beyond the Int range salvages instead of trapping")
    func parseRejectsDroppedCountBeyondInt() {
        // A u64 count with the high bit set: decoding it straight into Int
        // turned the value negative (or trapped on the shift), and the
        // salvage rewrite then trapped in UInt64(droppedLines) — crashing
        // the daemon on a damaged file instead of recovering the journal.
        var file = Data("PDLJ".utf8)
        withUnsafeBytes(of: UInt32(2).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(0x8000_0000_0000_0000).littleEndian) { file.append(contentsOf: $0) }
        let (parsed, droppedLines, _, _, salvaged) = ContainerLogJournal.parse(file)
        #expect(salvaged, "an unrepresentable dropped count is corruption — salvage it")
        #expect(parsed.isEmpty)
        #expect(droppedLines == 0)
    }

    @Test("loading a journal with a damaged dropped-count recovers instead of crashing")
    func loadRejectsDroppedCountBeyondInt() async {
        let dir = tempDirectory()
        var file = Data("PDLJ".utf8)
        withUnsafeBytes(of: UInt32(2).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(0x8000_0000_0000_0000).littleEndian) { file.append(contentsOf: $0) }
        // A partial trailing record forces the salvage rewrite on load —
        // the path whose header re-encode used to trap on the negative count.
        file.append(Data([0x01, 0x02, 0x03]))
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("podm-log-journals", isDirectory: true),
            withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("podm-log-journals/damaged.journal").path, contents: file)

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let contents = await journal.contents(nativeId: "damaged")
        #expect(contents.entries.isEmpty)
        #expect(contents.droppedLines == 0)

        // The salvaged file on disk now parses cleanly with a count of 0.
        let reloaded = try? Data(contentsOf: dir.appendingPathComponent("podm-log-journals/damaged.journal"))
        #expect(reloaded != nil)
        if let reloaded {
            let (entries, dropped, _, _, salvaged) = ContainerLogJournal.parse(reloaded)
            #expect(!salvaged)
            #expect(entries.isEmpty)
            #expect(dropped == 0)
        }
    }

    @Test("consumeGapMarker fails alignment on a retained non-marker entry; only exhaustion stays usable")
    func consumeGapMarkerMismatchInvalidates() {
        let retained = [entry(300, "c\n")]
        // A retained ORDINARY entry where the oversized line's marker should
        // be is a content mismatch: the journal provably does not describe
        // this stream. Returning .fresh without failing left matching on, so
        // a stale journal's retained line behind the oversized line kept
        // lending its old timestamp to the new boot's identical lines.
        var mismatched = ContainerLogJournal.Alignment(entries: retained)
        guard case .fresh = mismatched.consumeGapMarker() else {
            Issue.record("a retained non-marker entry must report fresh")
            return
        }
        #expect(mismatched.failed, "a retained non-marker at the marker position must invalidate alignment")
        #expect(mismatched.timestamp(for: Data("c\n".utf8)) == nil, "alignment must not recover after the mismatch")

        // Exhaustion — no entry at all, the follower is simply behind the
        // stream — stays usable.
        var exhausted = ContainerLogJournal.Alignment(entries: [])
        guard case .fresh = exhausted.consumeGapMarker() else {
            Issue.record("exhaustion must report fresh")
            return
        }
        #expect(!exhausted.failed)
    }

    @Test("append in many small batches over a growing journal loses no state")
    func appendManySmallBatchesKeepsState() async {
        // append takes the state OUT of the dictionary while mutating it (a
        // value-type copy would trigger copy-on-write of the whole retained
        // entries array on every batch) and restores it afterwards: this
        // pins the remove/restore cycle across many polling-sized flushes.
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: tempDirectory())
        await journal.beginBoot(nativeId: "ctr", epoch: 1)
        var expected: [UInt64] = []
        for batch in 0..<200 {
            let entries = (0..<8).map { entry(UInt64(batch * 8 + $0), "line-\(batch)-\($0)\n") }
            expected.append(contentsOf: entries.map(\.unixNano))
            await journal.append(nativeId: "ctr", epoch: 1, entries)
        }
        let contents = await journal.contents(nativeId: "ctr")
        #expect(contents.entries.count == 1600)
        #expect(contents.entries.map(\.unixNano) == expected)
        #expect(contents.droppedLines == 0)
    }

    // MARK: - Boot identity (version-4 header)

    @Test("the boot identity round-trips through the persisted file")
    func bootIdRoundTrips() async {
        let dir = tempDirectory()
        let writer = ContainerLogJournal()
        await writer.configure(storageDirectory: dir)
        await writer.beginBoot(nativeId: "boot-ctr", epoch: 1, bootIdNano: 1_730_000_000_000_000_000)
        await writer.append(nativeId: "boot-ctr", epoch: 1, [entry(100, "line\n")])

        let reader = ContainerLogJournal()
        await reader.configure(storageDirectory: dir)
        let contents = await reader.contents(nativeId: "boot-ctr")
        #expect(contents.entries.count == 1)

        // The identity is in the file itself, not just in memory.
        let raw = try? Data(contentsOf: dir.appendingPathComponent("podm-log-journals/boot-ctr.journal"))
        #expect(raw != nil)
        if let raw {
            let (_, _, _, bootIdNano, salvaged) = ContainerLogJournal.parse(raw)
            #expect(!salvaged)
            #expect(bootIdNano == 1_730_000_000_000_000_000)
        }

        // An unidentified boot (no startedDate) persists a flag-only header.
        await writer.beginBoot(nativeId: "unidentified-ctr", epoch: 1)
        await writer.append(nativeId: "unidentified-ctr", epoch: 1, [entry(100, "line\n")])
        let unidentifiedRaw = try? Data(
            contentsOf: dir.appendingPathComponent("podm-log-journals/unidentified-ctr.journal"))
        #expect(unidentifiedRaw != nil)
        if let unidentifiedRaw {
            let (_, _, _, bootIdNano, salvaged) = ContainerLogJournal.parse(unidentifiedRaw)
            #expect(!salvaged)
            #expect(bootIdNano == nil)
        }
    }

    @Test("a truncated version-4 boot identity salvages to nothing")
    func truncatedBootIdSalvages() {
        // A presence flag with fewer than 8 bytes behind it is a truncated
        // header, like a truncated stamp section.
        var file = Data("PDLJ".utf8)
        withUnsafeBytes(of: UInt32(4).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(0).littleEndian) { file.append(contentsOf: $0) }  // droppedLines
        withUnsafeBytes(of: UInt32(0).littleEndian) { file.append(contentsOf: $0) }  // stamp count
        file.append(Data([1, 0x01, 0x02]))  // flag set, only 2 of 8 identity bytes
        let (entries, _, _, _, salvaged) = ContainerLogJournal.parse(file)
        #expect(salvaged)
        #expect(entries.isEmpty)
    }

    @Test("a resume whose boot identity differs resets; the same or unknown identity adopts")
    func resumeBootIdentityMismatchResets() async {
        let dir = tempDirectory()
        let seeder = ContainerLogJournal()
        await seeder.configure(storageDirectory: dir)
        await seeder.beginBoot(nativeId: "reboot-ctr", epoch: 1, bootIdNano: 1_000_000_000_000_000_000)
        await seeder.append(nativeId: "reboot-ctr", epoch: 1, [entry(111, "previous boot\n")])

        // Same boot (podm restarted, container kept running): adopt.
        let sameBoot = ContainerLogJournal()
        await sameBoot.configure(storageDirectory: dir)
        await sameBoot.resumeBoot(nativeId: "reboot-ctr", epoch: 2, bootIdNano: 1_000_000_000_000_000_000)
        #expect(
            await sameBoot.entries(nativeId: "reboot-ctr").map(\.bytes) == [Data("previous boot\n".utf8)],
            "the same boot's persisted timestamps must survive the daemon restart")

        // Different boot (the container REBOOTED while podmd was down): the
        // old journal can never align with the new boot's stream — resetting
        // it is the only way identical startup lines cannot inherit the old
        // boot's stamps.
        let rebooted = ContainerLogJournal()
        await rebooted.configure(storageDirectory: dir)
        await rebooted.resumeBoot(nativeId: "reboot-ctr", epoch: 3, bootIdNano: 2_000_000_000_000_000_000)
        #expect(
            await rebooted.entries(nativeId: "reboot-ctr").isEmpty,
            "a reboot while no follower was armed must reset the stale journal")

        // Unknown identity on either side cannot prove a mismatch: adopt.
        await rebooted.beginBoot(nativeId: "unknown-ctr", epoch: 1, bootIdNano: 5_000_000_000_000_000_000)
        await rebooted.append(nativeId: "unknown-ctr", epoch: 1, [entry(222, "current boot\n")])
        let unidentified = ContainerLogJournal()
        await unidentified.configure(storageDirectory: dir)
        await unidentified.resumeBoot(nativeId: "unknown-ctr", epoch: 2, bootIdNano: nil)
        #expect(
            await unidentified.entries(nativeId: "unknown-ctr").map(\.bytes) == [Data("current boot\n".utf8)],
            "a nil identity (Apple reported no startedDate) must not force a reset")
    }

    @Test("bootIdNano(from:) converts startedDate, and leaves unknown or pre-epoch dates nil")
    func bootIdConversion() {
        #expect(ContainerLogJournal.bootIdNano(from: nil) == nil)
        #expect(ContainerLogJournal.bootIdNano(from: Date(timeIntervalSince1970: -1)) == nil)
        let nano = ContainerLogJournal.bootIdNano(from: Date(timeIntervalSince1970: 100.5))
        #expect(nano == 100_500_000_000)
    }

    @Test("reconfiguring the same directory is a no-op — live state survives")
    func configureIsIdempotentPerDirectory() async {
        // The route lifecycle suite installs ONE process-wide test directory
        // from every test; without per-directory idempotence each install
        // would wipe live state — closing cached writers and dropping the
        // writer epochs of followers other suites armed, silently
        // discarding their appends.
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.beginBoot(nativeId: "ctr", epoch: 1)
        await journal.append(nativeId: "ctr", epoch: 1, [entry(100, "line\n")])

        await journal.configure(storageDirectory: dir)  // same directory: no wipe

        #expect(
            await journal.entries(nativeId: "ctr").map(\.bytes) == [Data("line\n".utf8)],
            "a same-directory reconfigure must not drop live entries")
        #expect(
            await journal.writerIsOpen(nativeId: "ctr"),
            "a same-directory reconfigure must not close the cached writer")
    }
}
