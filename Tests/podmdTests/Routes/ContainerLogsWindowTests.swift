import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `docker logs --since/--until` (and `--timestamps` on backlog lines) filter
/// by per-line write times recovered from the log journal. `scanWindowedBacklog`
/// is the route's filtering core: these tests drive it with a fixture journal
/// and a chunked fake read stream, plus the HTTP-level parameter validation.
@Suite("ContainerLogsRoute — since/until window")
struct ContainerLogsWindowTests {

    private func journal(
        _ lines: [(nano: UInt64, line: String)], dropped: Int = 0
    ) -> ContainerLogJournal.Contents {
        ContainerLogJournal.Contents(
            entries: lines.map { ContainerLogJournal.Entry(unixNano: $0.nano, streamType: 1, bytes: Data($0.line.utf8)) },
            droppedLines: dropped)
    }

    /// Drives the scanner over `stream` in fixed-size chunks and collects the
    /// framed payloads (non-TTY: an 8-byte stdcopy header precedes each).
    private func scan(
        _ stream: String,
        journal: ContainerLogJournal.Contents = ContainerLogJournal.Contents(),
        since: UInt64? = nil,
        until: UInt64? = nil,
        tail: Int? = nil,
        timestamps: Bool = false,
        ttyMode: Bool = false,
        nowNanos: UInt64 = 999_999_999_999,
        streamEnded: Bool = false
    ) async throws -> (payloads: [String], remainder: Data) {
        let bytes = Array(stream.utf8)
        var offset = 0
        var payloads: [String] = []
        let handoff = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < bytes.count else { return nil }
                let next = min(offset + 3, bytes.count)  // tiny chunks split lines mid-way
                defer { offset = next }
                return Data(bytes[offset..<next])
            },
            journal: journal,
            since: since,
            until: until,
            tail: tail,
            ttyMode: ttyMode,
            timestamps: timestamps,
            nowNanos: { nowNanos },
            streamEnded: streamEnded
        ) { frame in
            var frame = frame
            if !ttyMode { frame.moveReaderIndex(forwardBy: 8) }  // skip the stdcopy header
            let payload = frame.readData(length: frame.readableBytes)!
            payloads.append(String(decoding: payload, as: UTF8.self))
        }
        return (payloads, handoff.pending)
    }

    @Test("since drops lines written before it, using journal timestamps")
    func sinceFilter() async throws {
        let fixture = journal([(100, "old\n"), (200, "recent\n"), (300, "newest\n")])
        let result = try await scan("old\nrecent\nnewest\n", journal: fixture, since: 150)
        #expect(result.payloads == ["recent\n", "newest\n"])
    }

    @Test("until drops lines written after it")
    func untilFilter() async throws {
        let fixture = journal([(100, "old\n"), (200, "recent\n"), (300, "newest\n")])
        let result = try await scan("old\nrecent\nnewest\n", journal: fixture, until: 250)
        #expect(result.payloads == ["old\n", "recent\n"])
    }

    @Test("since and until combine into a window")
    func window() async throws {
        let fixture = journal([(100, "a\n"), (200, "b\n"), (300, "c\n"), (400, "d\n")])
        let result = try await scan("a\nb\nc\nd\n", journal: fixture, since: 150, until: 350)
        #expect(result.payloads == ["b\n", "c\n"])
    }

    @Test("lines the journal does not cover fall back to read time")
    func unjournaledFallback() async throws {
        // Only the first line is journaled (write time 100); the rest get the
        // injected read time (999). The since sits between them, so the split
        // proves which timestamp each line was judged by.
        let fixture = journal([(100, "covered\n")])
        let result = try await scan("covered\nuncovered\n", journal: fixture, since: 500)
        #expect(result.payloads == ["uncovered\n"])
    }

    @Test("a stale journal that mismatches the stream yields no timestamps")
    func misalignedJournal() async throws {
        // Journal from a different boot: not a prefix of this stream. The line
        // falls back to read time (999), which this until drops — if the stale
        // journal's time (100) had leaked through, the line would be kept.
        let fixture = journal([(100, "other boot\n")])
        let result = try await scan("this boot\n", journal: fixture, until: 500)
        #expect(result.payloads.isEmpty)
    }

    @Test("tail applies to the window-filtered set, keeping the last N passing lines")
    func tailWithinWindow() async throws {
        let fixture = journal([
            (100, "one\n"), (200, "two\n"), (300, "three\n"), (400, "four\n"), (500, "five\n"),
        ])
        let result = try await scan("one\ntwo\nthree\nfour\nfive\n", journal: fixture, since: 150, tail: 2)
        #expect(result.payloads == ["four\n", "five\n"])
    }

    @Test("tail=0 emits nothing even with a wide-open window")
    func tailZero() async throws {
        let fixture = journal([(100, "one\n"), (200, "two\n")])
        let result = try await scan("one\ntwo\n", journal: fixture, tail: 0)
        #expect(result.payloads.isEmpty)
    }

    @Test("a trailing partial line is returned as the remainder, not emitted")
    func trailingPartial() async throws {
        let fixture = journal([(100, "done\n")])
        let result = try await scan("done\npartial", journal: fixture, since: 50)
        #expect(result.payloads == ["done\n"])
        #expect(result.remainder == Data("partial".utf8))
    }

    @Test("a trailing partial line counts toward tail when the stream genuinely ends")
    func tailCountsTrailingPartial() async throws {
        // `a\nb` (no trailing newline): one complete line (`a\n`, journal time
        // 100) plus the final partial line (`b`). With tail=1 the final line
        // is `b`, so only `b` may be emitted — emitting the retained tail
        // ring first and the partial separately would return both lines.
        let fixture = journal([(100, "a\n")])
        let tailOne = try await scan("a\nb", journal: fixture, tail: 1, timestamps: true, streamEnded: true)
        #expect(tailOne.payloads.count == 1)
        #expect(tailOne.payloads[0].hasSuffix("b"))
        #expect(!tailOne.payloads[0].hasSuffix("\n"), "the emitted final line is the unterminated partial, read-time stamped")
        #expect(tailOne.remainder.isEmpty)

        // tail=2 keeps both the complete line and the partial.
        let tailTwo = try await scan("a\nb", journal: fixture, tail: 2, timestamps: true, streamEnded: true)
        #expect(tailTwo.payloads.count == 2)
        #expect(tailTwo.payloads[0].hasSuffix("a\n"))
        #expect(tailTwo.payloads[1].hasSuffix("b"))
        #expect(!tailTwo.payloads[1].hasSuffix("\n"))

        // Without a tail limit the partial is emitted directly, like
        // flushFinalLogLine did.
        let noTail = try await scan("a\nb", journal: fixture, timestamps: true, streamEnded: true)
        #expect(noTail.payloads.count == 2)
        #expect(noTail.payloads[1].hasSuffix("b"))
        #expect(!noTail.payloads[1].hasSuffix("\n"))

        // A partial that fails the window is dropped and does not consume tail.
        let filtered = try await scan("a\nb", journal: fixture, until: 500, tail: 1, streamEnded: true)
        #expect(filtered.payloads == ["a\n"], "the read-time-stamped partial fails until and must not displace the tail entry")
    }

    @Test("the evicted journal prefix is skipped so the retained suffix still aligns")
    func evictedPrefixAlignment() async throws {
        // The journal covers the whole boot but the cap evicted the first two
        // lines: alignment must skip them (they fall back to read time, which
        // this until drops) and still recover the retained line's recorded
        // time — without the evicted-prefix count the first retained entry
        // would be matched against "a\n", fail, and disable recovery.
        let fixture = journal([(300, "c\n")], dropped: 2)
        let result = try await scan("a\nb\nc\n", journal: fixture, until: 350)
        #expect(result.payloads == ["c\n"])
    }

    @Test("a follow batch that crosses until still emits the lines accepted before it")
    func untilCrossingBatchFlushesAcceptedFrames() throws {
        // One read holds both lines: "keep" passes the window, "past" crosses
        // until. The accepted frame must be returned (and emitted by the
        // caller) rather than dropped when the read stops.
        let bytes = Array("keep\npast\n".utf8)
        var offset = 0
        var buffer = Data()
        var openLine: ContainerLogsRoute.WindowedOpenLine?
        var nowValues: [UInt64] = [300, 600]
        let (frames, reachedUntil, gotData) = ContainerLogsRoute.readWindowedFollowBatch(
            from: &buffer,
            read: {
                guard offset < bytes.count else { return nil }
                defer { offset = min(offset + 4096, bytes.count) }
                return Data(bytes[offset..<min(offset + 4096, bytes.count)])
            },
            since: nil,
            until: 500,
            ttyMode: true,
            timestamps: false,
            nowNanos: { nowValues.removeFirst() },
            openLine: &openLine
        )
        #expect(gotData)
        #expect(reachedUntil, "the line past until must end the follow")
        #expect(frames.count == 1, "the in-window line accepted before until must survive")
        var frame = frames[0]
        #expect(String(decoding: frame.readData(length: frame.readableBytes)!, as: UTF8.self) == "keep\n")
    }

    @Test("timestamps stamps each line with its journal-recorded write time")
    func journalTimestamps() async throws {
        let fixture = journal([(1_357_133_017_000_000_000, "hello\n")])
        let result = try await scan("hello\n", journal: fixture, timestamps: true)
        #expect(result.payloads.count == 1)
        // The stamp is the journal's write time (2013-01-02T13:23:37Z), not
        // the read time — the historical-timestamp fix this journal exists for.
        #expect(result.payloads[0].contains("2013-01-02T13:23:37"))
        #expect(result.payloads[0].hasSuffix("hello\n"))
    }

    @Test("TTY windowed output is raw, without stdcopy framing")
    func ttyRaw() async throws {
        let fixture = journal([(100, "a\n"), (200, "b\n")])
        var offset = 0
        let bytes = Array("a\nb\n".utf8)
        var raw = Data()
        _ = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < bytes.count else { return nil }
                defer { offset = min(offset + 2, bytes.count) }
                return Data(bytes[offset..<min(offset + 2, bytes.count)])
            },
            journal: fixture,
            since: nil,
            until: nil,
            tail: nil,
            ttyMode: true,
            timestamps: false,
            nowNanos: { 999 }
        ) { frame in
            var frame = frame
            raw.append(frame.readData(length: frame.readableBytes)!)
        }
        #expect(raw == Data("a\nb\n".utf8))
    }

    @Test("flushFinalLogLine honors the window and stamps with flush time")
    func flushWindow() {
        var frames: [ByteBuffer] = []
        ContainerLogsRoute.flushFinalLogLine(
            Data("trailing".utf8), ttyMode: false, timestamps: true, since: 100, until: 500,
            nowNanos: { 300 }
        ) { frames.append($0) }
        #expect(frames.count == 1)

        frames.removeAll()
        // Flush time past `until`: dropped.
        ContainerLogsRoute.flushFinalLogLine(
            Data("trailing".utf8), ttyMode: false, timestamps: true, since: 100, until: 500,
            nowNanos: { 600 }
        ) { frames.append($0) }
        #expect(frames.isEmpty)

        // Before `since`: dropped too.
        ContainerLogsRoute.flushFinalLogLine(
            Data("trailing".utf8), ttyMode: false, timestamps: true, since: 100, until: 500,
            nowNanos: { 50 }
        ) { frames.append($0) }
        #expect(frames.isEmpty)

        // Windowed reads without timestamps still flush the trailing line,
        // unstamped — the scanner held it back for window filtering.
        ContainerLogsRoute.flushFinalLogLine(
            Data("trailing".utf8), ttyMode: false, timestamps: false, since: 100, until: 500,
            nowNanos: { 300 }, emitWithoutTimestamps: true
        ) { frames.append($0) }
        #expect(frames.count == 1)
    }

    // MARK: - Oversized-line bounds

    /// A newline-free stream beyond the retention bound must not accumulate
    /// without limit: the scanner spills the incomplete line's bytes as they
    /// cross the bound (preserving the requested output) instead of
    /// buffering the whole line, and the lines after it still flow.
    @Test("a windowed backlog scan spills an oversized unterminated line instead of buffering it")
    func oversizedBacklogLineSpills() async throws {
        let bound = ContainerLogFollower.maxPendingLineBytes
        var stream = Data(repeating: 0x78, count: bound + (1 << 18))  // no newline
        stream.append(Data("\nafter\n".utf8))

        var offset = 0
        var payloads: [Data] = []
        let handoff = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < stream.count else { return nil }
                let next = min(offset + 4096, stream.count)
                defer { offset = next }
                return stream[offset..<next]
            },
            journal: ContainerLogJournal.Contents(),
            since: nil,
            until: nil,
            tail: nil,
            ttyMode: true,
            timestamps: false,
            nowNanos: { 999 },
            streamEnded: true
        ) { frame in
            var frame = frame
            payloads.append(frame.readData(length: frame.readableBytes)!)
        }

        // Every input byte is still emitted (output preserved) — as a spilled
        // head fragment, the terminating fragment, and the following line —
        // and nothing is left buffered in the returned remainder.
        #expect(payloads.reduce(0) { $0 + $1.count } == stream.count, "no byte may be dropped by the spill")
        #expect(payloads.count >= 3, "the oversized line is split across frames, not buffered whole")
        #expect(payloads.last == Data("after\n".utf8))
        #expect(payloads[0].last != 0x0A, "the first spilled fragment is an unterminated line head")
        #expect(handoff.pending.isEmpty)
    }

    /// The journal records an oversized line as a gap marker, never its
    /// payload: the scanner must consume the marker for the oversized line
    /// (instead of comparing it against the next retained entry) so the
    /// lines AFTER it keep their recorded timestamps.
    @Test("a journal gap marker keeps later lines aligned across an oversized line")
    func gapMarkerPreservesAlignment() async throws {
        let bound = ContainerLogFollower.maxPendingLineBytes
        var stream = Data(repeating: 0x78, count: bound + (1 << 18))
        stream.append(Data("\nafter\n".utf8))
        let fixture = ContainerLogJournal.Contents(
            entries: [
                ContainerLogJournal.Entry.gapMarker(unixNano: 100),
                ContainerLogJournal.Entry(unixNano: 200, streamType: 1, bytes: Data("after\n".utf8)),
            ])

        var offset = 0
        var payloads: [String] = []
        _ = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < stream.count else { return nil }
                let next = min(offset + 4096, stream.count)
                defer { offset = next }
                return stream[offset..<next]
            },
            journal: fixture,
            since: nil,
            until: 250,  // journal time 200 passes; read-time 999 would not
            tail: nil,
            ttyMode: true,
            timestamps: false,
            nowNanos: { 999 },
            streamEnded: true
        ) { frame in
            var frame = frame
            payloads.append(String(decoding: frame.readData(length: frame.readableBytes)!, as: UTF8.self))
        }

        #expect(payloads.last == "after\n", "the line after the oversized one must keep its journal timestamp")
        #expect(!payloads.isEmpty, "the oversized line's spilled bytes are still emitted (marker time 100)")
    }

    /// `tail` counts LOGICAL lines: a spilled oversized line is ONE tail
    /// entry whose complete bytes are emitted when it is the selected line
    /// — counting each spilled fragment as its own tail line evicted the
    /// line's head and returned only its final fragment.
    @Test("tail counts a spilled oversized line as one logical line, emitted whole")
    func tailCountsSpilledLineAsOne() async throws {
        let bound = ContainerLogFollower.maxPendingLineBytes
        var line = Data(repeating: 0x78, count: bound + (1 << 18))  // no newline inside
        line.append(Data("\n".utf8))
        var stream = Data("before\n".utf8)
        stream.append(line)

        var offset = 0
        var payloads: [Data] = []
        _ = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < stream.count else { return nil }
                let next = min(offset + 4096, stream.count)
                defer { offset = next }
                return stream[offset..<next]
            },
            journal: ContainerLogJournal.Contents(),
            since: nil,
            until: nil,
            tail: 1,
            ttyMode: true,
            timestamps: false,
            nowNanos: { 999 },
            streamEnded: true
        ) { frame in
            var frame = frame
            payloads.append(frame.readData(length: frame.readableBytes)!)
        }

        // The oversized line is the last logical line, so tail=1 selects it
        // in full — head fragment, middle fragments, terminating newline —
        // and the earlier "before" line is evicted as a whole line.
        #expect(
            payloads.reduce(0) { $0 + $1.count } == line.count,
            "the whole selected line must be emitted byte for byte, not just its final fragment")
        #expect(payloads.last?.last == 0x0A, "the selected line's terminating newline must be emitted")
        #expect(payloads.count >= 2, "the line was spilled across fragments, not buffered whole")
    }

    /// The whole spilled line shares ONE window decision, fixed at its
    /// first fragment: later fragments, the terminating fragment and the
    /// EOF tail must not be restamped with read time — restamping dropped
    /// them (newline included) whenever the read time fell outside the
    /// window.
    @Test("a spilled line keeps its first fragment's window decision across all fragments and EOF")
    func spilledLineKeepsOneWindowDecision() async throws {
        let bound = ContainerLogFollower.maxPendingLineBytes
        // The journal recorded the oversized line as a gap marker at 100;
        // the marker time is in-window, the read time (999) is not.
        let fixture = ContainerLogJournal.Contents(
            entries: [ContainerLogJournal.Entry.gapMarker(unixNano: 100)])

        func scan(_ stream: Data) async throws -> [Data] {
            var offset = 0
            var payloads: [Data] = []
            _ = try await ContainerLogsRoute.scanWindowedBacklog(
                read: {
                    guard offset < stream.count else { return nil }
                    let next = min(offset + 4096, stream.count)
                    defer { offset = next }
                    return stream[offset..<next]
                },
                journal: fixture,
                since: nil,
                until: 250,
                tail: nil,
                ttyMode: true,
                timestamps: false,
                nowNanos: { 999 },
                streamEnded: true
            ) { frame in
                var frame = frame
                payloads.append(frame.readData(length: frame.readableBytes)!)
            }
            return payloads
        }

        // Terminated line: every fragment INCLUDING the terminating newline
        // passes the window on the marker's time (100), never read time.
        var terminated = Data(repeating: 0x78, count: bound + (1 << 18))
        terminated.append(Data("\n".utf8))
        let terminatedPayloads = try await scan(terminated)
        #expect(
            terminatedPayloads.reduce(0) { $0 + $1.count } == terminated.count,
            "no byte of the in-window line may be dropped, its newline included")
        #expect(terminatedPayloads.last?.last == 0x0A, "the terminating newline must be emitted")

        // Unterminated final line: the stream ends while the line is open —
        // its EOF fragment is judged by the same fixed time, not flush time.
        let open = Data(repeating: 0x78, count: bound + (1 << 18))
        let openPayloads = try await scan(open)
        #expect(
            openPayloads.reduce(0) { $0 + $1.count } == open.count,
            "the EOF fragment keeps the line's fixed window decision")
    }

    /// The oversized line may sit in the journal's EVICTED prefix (the cap
    /// evicted its marker): consuming that ordinal keeps the next retained
    /// line aligned — without it, the retained line classified as evicted,
    /// lost its recorded timestamp, and fell to read time.
    @Test("an evicted oversized line consumes its ordinal so the next retained line keeps its timestamp")
    func evictedOversizedLineConsumesItsOrdinal() async throws {
        let bound = ContainerLogFollower.maxPendingLineBytes
        var stream = Data(repeating: 0x78, count: bound + (1 << 18))
        stream.append(Data("\nafter\n".utf8))
        // The cap evicted the oversized line's gap marker: droppedLines
        // accounts it, and only the following line is retained.
        let fixture = ContainerLogJournal.Contents(
            entries: [ContainerLogJournal.Entry(unixNano: 200, streamType: 1, bytes: Data("after\n".utf8))],
            droppedLines: 1)

        var offset = 0
        var payloads: [Data] = []
        _ = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < stream.count else { return nil }
                let next = min(offset + 4096, stream.count)
                defer { offset = next }
                return stream[offset..<next]
            },
            journal: fixture,
            since: nil,
            until: 250,  // journal time 200 passes; read time 999 would not
            tail: nil,
            ttyMode: true,
            timestamps: false,
            nowNanos: { 999 },
            streamEnded: true
        ) { frame in
            var frame = frame
            payloads.append(frame.readData(length: frame.readableBytes)!)
        }

        #expect(
            payloads == [Data("after\n".utf8)],
            "the retained line behind the evicted oversized one must keep its journal time (200)")
    }

    @Test("a follow batch spills an oversized unterminated line instead of buffering it")
    func followBatchSpillsOversizedLine() throws {
        let bound = ContainerLogFollower.maxPendingLineBytes
        let stream = Data(repeating: 0x61, count: bound + (1 << 18))  // no newline at all
        // One read delivers the whole newline-free burst, as a fast writer
        // can: the batch must spill what crosses the bound, not buffer it.
        var delivered = false
        var buffer = Data()
        var openLine: ContainerLogsRoute.WindowedOpenLine?
        let (frames, reachedUntil, gotData) = ContainerLogsRoute.readWindowedFollowBatch(
            from: &buffer,
            read: {
                guard !delivered else { return nil }
                delivered = true
                return stream
            },
            since: nil,
            until: nil,
            ttyMode: true,
            timestamps: false,
            nowNanos: { 999 },
            openLine: &openLine
        )
        #expect(gotData)
        #expect(!reachedUntil)
        let emitted = frames.reduce(0) { $0 + $1.readableBytes }
        #expect(emitted + buffer.count == stream.count, "no byte may be dropped by the spill")
        #expect(buffer.count <= bound, "the carried partial line stays bounded")
    }

    @Test("a follow batch yields after a bounded amount of input")
    func followBatchYieldsAfterBoundedInput() throws {
        // A read that ALWAYS has more data (a container writing faster than
        // the reader is drained): the batch must return after a bounded
        // amount of input so the caller can write and check the deadline —
        // without the budget this call never returns.
        let chunk = Data(String(repeating: "line\n", count: 819).utf8)  // ~4 KiB per read
        var reads = 0
        var buffer = Data()
        var openLine: ContainerLogsRoute.WindowedOpenLine?
        let (frames, reachedUntil, gotData) = ContainerLogsRoute.readWindowedFollowBatch(
            from: &buffer,
            read: {
                reads += 1
                return chunk
            },
            since: nil,
            until: nil,
            ttyMode: true,
            timestamps: false,
            nowNanos: { 999 },
            openLine: &openLine
        )
        #expect(gotData, "data was available")
        #expect(!reachedUntil)
        #expect(!frames.isEmpty)
        let maxReads = ContainerLogsRoute.followBatchMaxBytes / chunk.count + 2
        #expect(reads <= maxReads, "the batch must stop reading after a bounded amount of input")
    }

    // MARK: - Backlog scan bounds (review round 4)

    /// follow=1 on a container that is already stopped: its log can never
    /// grow again, so the backlog scanner must treat EOF as the log's
    /// genuine end and count the trailing partial line toward `tail` — the
    /// follow loop only confirms what the request-start status knew, and
    /// holding the final partial line back mis-selected the tail (`a\nb`
    /// with tail=1 emitted both lines).
    @Test("a stopped container's EOF is final for backlog tail selection even with follow=1")
    func stoppedContainerBacklogEOFFinal() {
        #expect(ContainerLogsRoute.backlogScanBounds(followActive: false, containerRunning: true).streamEnded)
        #expect(ContainerLogsRoute.backlogScanBounds(followActive: false, containerRunning: false).streamEnded)

        let running = ContainerLogsRoute.backlogScanBounds(followActive: true, containerRunning: true)
        #expect(!running.streamEnded, "a running container's log may still grow: EOF is just a read gap")
        #expect(running.maxScanBytes != nil, "a running container's follow backlog scan is byte-bounded")

        let stopped = ContainerLogsRoute.backlogScanBounds(followActive: true, containerRunning: false)
        #expect(stopped.streamEnded, "a stopped container's EOF is final even with follow=1")
        #expect(stopped.maxScanBytes == nil, "a stopped container's log cannot grow: no scan budget is needed")
    }

    /// With `timestamps=1` and no `tail`, a spilled oversized line's
    /// fragments are emitted as they cross the retention bound: only the
    /// FIRST fragment may carry the timestamp prefix — prefixing every
    /// fragment spliced extra timestamp strings into the middle of the
    /// original log line.
    @Test("timestamps prefixes a spilled oversized line once, not per fragment")
    func timestampsPrefixOncePerSpilledLine() async throws {
        let bound = ContainerLogFollower.maxPendingLineBytes
        var stream = Data(repeating: 0x78, count: bound + (1 << 18))  // no newline inside
        stream.append(Data("\nafter\n".utf8))

        var offset = 0
        var payloads: [Data] = []
        _ = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < stream.count else { return nil }
                let next = min(offset + 4096, stream.count)
                defer { offset = next }
                return stream[offset..<next]
            },
            journal: ContainerLogJournal.Contents(),
            since: nil,
            until: nil,
            tail: nil,  // no ring: fragments emit directly as they spill
            ttyMode: true,
            timestamps: true,
            nowNanos: { 1_357_133_017_000_000_000 },  // 2013-01-02T13:23:37Z
            streamEnded: true
        ) { frame in
            var frame = frame
            payloads.append(frame.readData(length: frame.readableBytes)!)
        }

        let joined = String(decoding: payloads.reduce(Data(), +), as: UTF8.self)
        let stamps = joined.components(separatedBy: "2013-01-02T13:23:37").count - 1
        #expect(stamps == 2, "one prefix for the spilled line and one for the following line — continuations must be verbatim, found \(stamps)")
        #expect(payloads.count >= 3, "the oversized line is split across fragments, not buffered whole")
    }

    /// The finding-3 liveness case: follow=1&tail=0&since=0 on a log growing
    /// faster than it is scanned. The backlog pass must stop after a bounded
    /// amount of input and yield to the deadline- and disconnect-aware
    /// follow loop — without the budget this scan never returns.
    @Test("the backlog scan yields after a bounded amount of input when a follow will continue")
    func backlogScanYieldsAtBudget() async throws {
        let chunk = Data(String(repeating: "line\n", count: 819).utf8)  // ~4 KiB per read
        var reads = 0
        let budget = 64 * 1024
        let handoff = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                reads += 1
                return chunk  // always more data: a fast writer
            },
            journal: ContainerLogJournal.Contents(),
            since: 0,
            until: nil,
            tail: 0,  // the finding's exact shape: nothing retained, nothing emitted
            ttyMode: true,
            timestamps: false,
            nowNanos: { 999 },
            maxScanBytes: budget
        ) { _ in
            Issue.record("tail=0 must not emit during the scan")
        }
        #expect(reads <= budget / chunk.count + 2, "the scan must stop reading after a bounded amount of input")
        #expect(handoff.openLine == nil)
    }

    // MARK: - Open spilled-line state across follow batches (review round 4)

    /// A follow batch that spills the head of an oversized line BEFORE
    /// `since` passes must keep that drop decision for the line's later
    /// fragments: without the carried state, the terminating fragment —
    /// arriving after `since` passed — was emitted as a fresh in-window
    /// line.
    @Test("a follow batch keeps a window-dropped spilled line dropped across batches")
    func followBatchKeepsDroppedLineDropped() throws {
        let bound = ContainerLogFollower.maxPendingLineBytes
        let head = Data(repeating: 0x61, count: bound + 1024)
        var buffer = Data()
        var openLine: ContainerLogsRoute.WindowedOpenLine?

        // Batch 1: the head arrives while now()=100 < since=500 — dropped.
        var deliveredHead = false
        let batch1 = ContainerLogsRoute.readWindowedFollowBatch(
            from: &buffer,
            read: {
                guard !deliveredHead else { return nil }
                deliveredHead = true
                return head
            },
            since: 500,
            until: nil,
            ttyMode: true,
            timestamps: true,
            nowNanos: { 100 },
            openLine: &openLine
        )
        #expect(batch1.frames.isEmpty, "the head written before since is dropped")
        #expect(openLine != nil, "the line stays open with its fixed drop decision")

        // Batch 2: the terminating fragment arrives after since passed — it
        // must stay dropped, not be emitted as a fresh timestamped line.
        var deliveredTail = false
        let batch2 = ContainerLogsRoute.readWindowedFollowBatch(
            from: &buffer,
            read: {
                guard !deliveredTail else { return nil }
                deliveredTail = true
                return Data("tail\n".utf8)
            },
            since: 500,
            until: nil,
            ttyMode: true,
            timestamps: true,
            nowNanos: { 600 },
            openLine: &openLine
        )
        #expect(batch2.frames.isEmpty, "the terminating fragment keeps the head's drop decision")
        #expect(openLine == nil, "the newline closed the line")
    }

    /// An in-window spilled line carries ONE prefix: the head fragment is
    /// stamped, and every later fragment — across batches and the final
    /// flush — is a verbatim continuation.
    @Test("a follow batch keeps one prefix and one decision per spilled line, through the final flush")
    func followBatchOpenLinePrefixContinuity() throws {
        let bound = ContainerLogFollower.maxPendingLineBytes
        let head = Data(repeating: 0x61, count: bound + 1024)
        let nano: UInt64 = 1_357_133_017_000_000_000
        var buffer = Data()
        var openLine: ContainerLogsRoute.WindowedOpenLine?
        var frames: [ByteBuffer] = []

        // Batch 1: the head spills in-window — one stamped frame.
        var deliveredHead = false
        let batch1 = ContainerLogsRoute.readWindowedFollowBatch(
            from: &buffer,
            read: {
                guard !deliveredHead else { return nil }
                deliveredHead = true
                return head
            },
            since: nil,
            until: nil,
            ttyMode: true,
            timestamps: true,
            nowNanos: { nano },
            openLine: &openLine
        )
        frames.append(contentsOf: batch1.frames)
        #expect(batch1.frames.count == 1, "the spilled head is one stamped frame")

        // Batch 2: a continuation fragment below the bound waits in the
        // buffer — no newline, no spill, nothing emitted.
        var deliveredMid = false
        let batch2 = ContainerLogsRoute.readWindowedFollowBatch(
            from: &buffer,
            read: {
                guard !deliveredMid else { return nil }
                deliveredMid = true
                return Data("mid".utf8)
            },
            since: nil,
            until: nil,
            ttyMode: true,
            timestamps: true,
            nowNanos: { nano },
            openLine: &openLine
        )
        #expect(batch2.frames.isEmpty)
        #expect(buffer == Data("mid".utf8))

        // The follow ends with the line still open: the final flush emits
        // the carried fragment verbatim — no second prefix, no re-windowing.
        var flushed: [ByteBuffer] = []
        ContainerLogsRoute.flushFinalLogLine(
            buffer, ttyMode: true, timestamps: true, since: nil, until: nil,
            openLine: openLine, nowNanos: { nano }, emitWithoutTimestamps: true
        ) { flushed.append($0) }
        #expect(flushed.count == 1)

        let joined = String(
            decoding: (frames + flushed).reduce(Data()) { acc, frame in
                var frame = frame
                return acc + frame.readData(length: frame.readableBytes)!
            }, as: UTF8.self)
        let stamps = joined.components(separatedBy: "2013-01-02T13:23:37").count - 1
        #expect(stamps == 1, "exactly one prefix for the whole logical line, found \(stamps)")
        #expect(joined.hasSuffix("mid"), "the flushed fragment is a verbatim continuation")
    }

    /// The backlog-to-follow handoff: when the backlog scan ends (read gap)
    /// in the middle of a spilled oversized line whose head was already
    /// window-dropped, the follow reader must keep dropping the line's
    /// remaining fragments instead of treating them as fresh lines.
    @Test("the backlog scan hands an open spilled line's decision to the follow reader")
    func backlogHandoffContinuesOpenLine() async throws {
        let bound = ContainerLogFollower.maxPendingLineBytes
        let stream = Data(repeating: 0x78, count: bound + 1024)  // head only, read gap before the newline
        // The journal recorded the oversized line as a gap marker at 100 —
        // before since=500, so the scanner drops the head fragments.
        let fixture = ContainerLogJournal.Contents(
            entries: [ContainerLogJournal.Entry.gapMarker(unixNano: 100)])

        var offset = 0
        var emitted: [Data] = []
        let handoff = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < stream.count else { return nil }
                let next = min(offset + 4096, stream.count)
                defer { offset = next }
                return stream[offset..<next]
            },
            journal: fixture,
            since: 500,
            until: nil,
            tail: nil,
            ttyMode: true,
            timestamps: true,
            nowNanos: { 999 },
            streamEnded: false  // a follow loop will continue the stream
        ) { frame in
            var frame = frame
            emitted.append(frame.readData(length: frame.readableBytes)!)
        }
        #expect(emitted.isEmpty, "the pre-since head fragments are dropped")
        #expect(handoff.openLine?.inWindow == false, "the open line's drop decision is handed off")

        // The terminating fragment arrives in the follow phase, after since
        // passed (now=600): it must keep the line's fixed drop decision.
        var buffer = handoff.pending
        var openLine = handoff.openLine
        var delivered = false
        let batch = ContainerLogsRoute.readWindowedFollowBatch(
            from: &buffer,
            read: {
                guard !delivered else { return nil }
                delivered = true
                return Data("tail\n".utf8)
            },
            since: 500,
            until: nil,
            ttyMode: true,
            timestamps: true,
            nowNanos: { 600 },
            openLine: &openLine
        )
        #expect(batch.frames.isEmpty, "no resurrection of the window-dropped line after since passed")
        #expect(openLine == nil)
    }

    // MARK: - HTTP level

    @Test(
        "an unparseable since/until is a 400, like moby rejects bad timestamps",
        arguments: ["since=not-a-time", "until=yesterday!!", "since=123.4.5"])
    func badTimestampIs400(query: String) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerLogsRoute(client: WindowContainerMock()))

            try await app.testing().test(.GET, "/v1.51/containers/ctr/logs?stdout=1&\(query)") { res async in
                #expect(res.status == .badRequest)
                // The reason is JSON-encoded in the error body ("/" arrives as "\/").
                #expect(res.body.string.replacingOccurrences(of: "\\/", with: "/").contains("invalid since/until timestamp"))
            }
        }
    }
}

/// Mock whose getContainer returns a running snapshot so the logs route reaches
/// parameter validation before touching Apple Container.
private struct WindowContainerMock: ClientContainerProtocol {
    private var snapshot: ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        let config = ContainerConfiguration(id: "ctr", image: img, process: proc)
        return ContainerSnapshot(configuration: config, status: .running, networks: [])
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
