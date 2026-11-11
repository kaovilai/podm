import ContainerAPIClient
import Foundation
import NIOCore
import Vapor

struct ContainerLogsRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/logs", use: ContainerLogsRoute.handler(client: client))
    }
}

extension ContainerLogsRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            // moby validates the stream parameters before resolving the container:
            // a request that attaches to neither stream is a 400. The docker CLI
            // always sends stdout=1&stderr=1, so neither is a client error, not a
            // request for the default.
            let wantStdout = MobyBool.queryValue(req.query["stdout"] as String?)
            let wantStderr = MobyBool.queryValue(req.query["stderr"] as String?)
            guard wantStdout || wantStderr else {
                throw Abort(.badRequest, reason: "Bad parameters: you must choose at least one stream")
            }

            guard let container = try await client.getContainer(id: id) else {
                // Docker phrasing ("No such container: <id>") is load-bearing — see the
                // matching comment in ContainerInspectRoute.
                throw Abort(.notFound, reason: "No such container: \(id)")
            }

            // `tail=<N>` limits the backlog to the last N lines; "all" (the
            // default) or an unparseable value streams the whole backlog.
            let tail = ContainerLogsRoute.parseTail(req.query["tail"] as String?)

            // Containers started with a TTY produce a raw, unmultiplexed log
            // stream; non-TTY containers use Docker's 8-byte stdcopy framing.
            // The docker CLI decides how to read the stream from the container's
            // Tty setting, so the framing here must match it.
            let isTTY = container.configuration.initProcess.terminal

            // moby parses `since`/`until` after resolving the container and
            // rejects unparseable values. The docker CLI converts durations
            // ("42m") and RFC3339 timestamps to unix seconds client-side;
            // DockerTimeParam accepts those forms too. `until=0` is treated as
            // absent, exactly like dockerd.
            let since: UInt64?
            let until: UInt64?
            do {
                since = try DockerTimeParam.unixNanoseconds(req.query["since"] as String?)
                var parsedUntil = try DockerTimeParam.unixNanoseconds(req.query["until"] as String?)
                if parsedUntil == 0 { parsedUntil = nil }
                until = parsedUntil
            } catch {
                throw Abort(.badRequest, reason: "Bad parameters: invalid since/until timestamp: \(error)")
            }

            // always use the container's log, not the boot of the container
            let boot = false
            let fhs = try await ContainerClient().logs(id: container.id)
            let fileHandle = boot ? fhs[1] : fhs[0]
            // Create a streaming body
            // `follow=1` means tail like
            let follow = MobyBool.queryValue(req.query["follow"] as String?)
            let timestamps = MobyBool.queryValue(req.query["timestamps"] as String?)

            // Timestamped or windowed reads need per-line write times, which
            // Apple's log stream does not carry: the journal the background
            // follower records while the container runs supplies them for
            // backlog lines (read time is the fallback for lines it does not
            // cover). Plain reads skip the journal entirely.
            let windowed = timestamps || since != nil || until != nil
            let bootJournal =
                windowed
                ? await ContainerLogJournal.shared.contents(nativeId: container.id)
                : ContainerLogJournal.Contents()
            // `until` in the past bounds the response: backlog only, no stream.
            let followActive = follow && (until == nil || until! > ContainerLogJournal.currentUnixNano())
            // The container's request-start status bounds the backlog scan:
            // a stopped container's log can never grow again, a running
            // one's may (see `backlogScanBounds`).
            let containerRunning = container.status == .running
            let scanBounds = ContainerLogsRoute.backlogScanBounds(
                followActive: followActive, containerRunning: containerRunning)

            let body = Response.Body.idleTracked(stream: { writer in
                Task.detached {
                    var buffer = Data()
                    // An oversized line still open at a read boundary — its
                    // head fragment was already emitted (or window-dropped)
                    // with a fixed time and decision. Later fragments
                    // continue it across follow batches and final flushing
                    // instead of being restamped as fresh lines.
                    var openLine: ContainerLogsRoute.WindowedOpenLine?

                    // Flushes any trailing line left in `buffer` with no terminating
                    // newline yet, then closes out the response. Only call this once
                    // the stream has genuinely ended — flushing on a mid-stream read
                    // gap could stamp and emit a line the writer hasn't finished yet.
                    // The trailing line is stamped with the flush time unless the
                    // follower's confirmed-exit drain journaled it (the container's
                    // final, unterminated line) — its recorded time is recovered
                    // below — and still has to pass the since/until window, if any.
                    func finish() async {
                        var recordedNano: UInt64? = nil
                        if windowed, openLine == nil, !buffer.isEmpty {
                            // The journal's last entry is the only candidate: a
                            // complete line always ends in `\n` (the buffer never
                            // does), so a match is necessarily the exit-drain's
                            // final-line fragment.
                            let contents = await ContainerLogJournal.shared.contents(nativeId: container.id)
                            if let last = contents.entries.last, last.bytes == buffer {
                                recordedNano = last.unixNano
                            }
                        }
                        ContainerLogsRoute.flushFinalLogLine(
                            buffer, ttyMode: isTTY, timestamps: timestamps, since: since, until: until,
                            openLine: openLine,
                            recordedNano: recordedNano,
                            emitWithoutTimestamps: windowed
                        ) { outputBuffer in
                            _ = writer.write(.buffer(outputBuffer))
                        }
                        try? fileHandle.close()
                        _ = writer.write(.end)
                    }

                    do {
                        if windowed {
                            // tail=0 without follow returns an empty backlog; skip
                            // reading the log at all, like the plain tail path.
                            if tail == 0, !followActive {
                                await finish()
                                return
                            }
                            let handoff = try await ContainerLogsRoute.scanWindowedBacklog(
                                read: { try fileHandle.read(upToCount: 4096) },
                                journal: bootJournal,
                                since: since,
                                until: until,
                                tail: tail,
                                ttyMode: isTTY,
                                timestamps: timestamps,
                                nowNanos: { ContainerLogJournal.currentUnixNano() },
                                streamEnded: scanBounds.streamEnded,
                                maxScanBytes: scanBounds.maxScanBytes,
                                yield: {
                                    // Liveness probe between scan batches: a
                                    // zero-byte write delivers no output but
                                    // fails once the client is gone, and
                                    // awaiting it lets the event loop run — a
                                    // scan of a fast-growing log otherwise
                                    // monopolizes this task between batches.
                                    try await writer.write(
                                        .buffer(ByteBufferAllocator().buffer(capacity: 0))
                                    ).get()
                                }
                            ) { frame in
                                // Await each write so a client disconnect aborts the
                                // response instead of queueing the whole window.
                                try await writer.write(.buffer(frame)).get()
                            }
                            buffer = handoff.pending
                            openLine = handoff.openLine
                        } else if let tail {
                            // tail=0 without follow returns an empty backlog; skip
                            // reading the log at all. With follow the read-through
                            // below still runs so the handle reaches EOF and the
                            // follow loop emits only new lines.
                            if tail == 0, !follow {
                                await finish()
                                return
                            }
                            // Apple Container's log API is a forward byte stream with
                            // no reverse-seek. Read it through, keeping only the last
                            // `tail` lines so memory stays bounded to ~2x tail lines
                            // rather than the whole (unrotated) log.
                            let backlog = try ContainerLogsRoute.tailBacklog(tail: tail) { try fileHandle.read(upToCount: 4096) }
                            var frames: [ByteBuffer] = []
                            buffer = ContainerLogsRoute.processDockerLogFrames(from: backlog, ttyMode: isTTY, timestamps: timestamps) { outputBuffer in
                                frames.append(outputBuffer)
                            }
                            // Await each write so a client disconnect aborts the
                            // response instead of queueing the whole window (the
                            // same contract as the follow loop below).
                            for frame in frames {
                                do {
                                    try await writer.write(.buffer(frame)).get()
                                } catch {
                                    await finish()
                                    return
                                }
                            }
                        } else {
                            // Read initial logs
                            while true {
                                let data = try fileHandle.read(upToCount: 4096)
                                guard let data, !data.isEmpty else { break }
                                buffer.append(data)

                                // Process complete frames from buffer
                                buffer = ContainerLogsRoute.processDockerLogFrames(from: buffer, ttyMode: isTTY, timestamps: timestamps) { outputBuffer in
                                    _ = writer.write(.buffer(outputBuffer))
                                }
                            }
                        }

                        if !followActive {
                            await finish()
                            return
                        }
                    } catch {
                        await finish()
                        return
                    }

                    // For follow mode, poll the log file for new writes. A
                    // DispatchSource on the log fd is fragile: it can fire on a
                    // closed/invalidated fd during teardown (container removed or
                    // client disconnect) and crash the whole process with a
                    // libdispatch trap. Polling is robust. Exit once the
                    // container is no longer running.
                    let logFollowClient = ContainerClient()
                    if windowed {
                        // Windowed follow: same polling contract, but each live
                        // line is stamped with its arrival time and the window
                        // keeps applying — a line (or the wall clock) passing
                        // `until` ends the read, matching moby. Lines accepted
                        // before `until` was crossed are still emitted first:
                        // they passed the window and belong in the response.
                        follow: while true {
                            let batch: (frames: [ByteBuffer], reachedUntil: Bool, gotData: Bool)
                            do {
                                batch = try ContainerLogsRoute.readWindowedFollowBatch(
                                    from: &buffer,
                                    read: { try fileHandle.read(upToCount: 4096) },
                                    since: since,
                                    until: until,
                                    ttyMode: isTTY,
                                    timestamps: timestamps,
                                    nowNanos: { ContainerLogJournal.currentUnixNano() },
                                    openLine: &openLine)
                            } catch {
                                break
                            }
                            for frame in batch.frames {
                                do {
                                    try await writer.write(.buffer(frame)).get()
                                } catch {
                                    break follow
                                }
                            }
                            if batch.reachedUntil { break }
                            // A future `until` also bounds the follow on wall
                            // clock alone, so the response cannot outlive it.
                            if let until, ContainerLogJournal.currentUnixNano() > until { break }
                            if !batch.gotData {
                                let current = try? await logFollowClient.get(id: container.id)
                                if current == nil || current?.status != .running { break }
                                try? await Task.sleep(for: .milliseconds(150))
                            }
                        }
                        await finish()
                        return
                    }
                    follow: while true {
                        var gotData = false
                        var frames: [ByteBuffer] = []
                        do {
                            while let data = try fileHandle.read(upToCount: 4096), !data.isEmpty {
                                gotData = true
                                buffer.append(data)
                                buffer = ContainerLogsRoute.processDockerLogFrames(from: buffer, ttyMode: isTTY, timestamps: timestamps) { outputBuffer in
                                    frames.append(outputBuffer)
                                }
                            }
                        } catch {
                            break
                        }
                        // Await each write so a client disconnect (the write future
                        // fails once the channel is closed) ends this task promptly
                        // instead of polling on until the container stops.
                        for frame in frames {
                            do {
                                try await writer.write(.buffer(frame)).get()
                            } catch {
                                break follow
                            }
                        }
                        if !gotData {
                            let current = try? await logFollowClient.get(id: container.id)
                            if current == nil || current?.status != .running { break }
                            try? await Task.sleep(for: .milliseconds(150))
                        }
                    }
                    await finish()
                }
            })

            return Response(
                status: .ok,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: body
            )
        }
    }

    /// Parses moby's `tail` query value. "all", an absent value, or anything
    /// non-numeric means the whole backlog (nil); a non-negative integer means
    /// only that many trailing lines.
    static func parseTail(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.lowercased() != "all" else { return nil }
        guard let n = Int(value), n >= 0 else { return nil }
        return n
    }

    /// Returns only the last `count` newline-delimited lines of `data`. A
    /// trailing line with no terminating newline still counts as a line, and a
    /// single trailing newline is not treated as an extra empty line. `count == 0`
    /// yields no output.
    /// Reads a stream through chunk by chunk via `read` (nil or empty means
    /// EOF) and returns only its last `tail` lines. The window is trimmed once
    /// it holds twice the wanted lines, not on every chunk, so each byte is
    /// scanned O(1) times amortized even for a huge `tail` over a huge log.
    static func tailBacklog(tail: Int, read: () throws -> Data?) rethrows -> Data {
        var backlog = Data()
        var newlines = 0
        let trimAt = max(tail, 1) > Int.max / 2 ? Int.max : max(tail, 1) * 2
        while let data = try read(), !data.isEmpty {
            newlines += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            backlog.append(data)
            if newlines >= trimAt {
                backlog = lastLines(backlog, count: tail)
                newlines = tail
            }
        }
        return lastLines(backlog, count: tail)
    }

    static func lastLines(_ data: Data, count: Int) -> Data {
        guard count > 0 else { return Data() }
        guard !data.isEmpty else { return data }
        // Ignore one trailing newline so "a\nb\n" with count 1 yields "b\n".
        var searchEnd = data.endIndex
        if data.last == 0x0A { searchEnd = data.index(before: data.endIndex) }
        var seen = 0
        var i = searchEnd
        while i > data.startIndex {
            let prev = data.index(before: i)
            if data[prev] == 0x0A {
                seen += 1
                if seen == count { return Data(data[i...]) }
            }
            i = prev
        }
        return data
    }

    static func processDockerLogFrames(from buffer: Data, ttyMode: Bool, timestamps: Bool = false, writeOutput: (ByteBuffer) -> Void) -> Data {
        guard !buffer.isEmpty else {
            return buffer
        }

        guard timestamps else {
            emitFrame(buffer, ttyMode: ttyMode, writeOutput: writeOutput)
            return Data()
        }

        // Real Docker stamps each line with the time it was written. Apple Container's
        // log API is a raw byte stream with no per-line write-time metadata, so every
        // complete line found in this pass is stamped with the same "now" value instead
        // — reasonably accurate for live follow tailing (within the ~150ms poll
        // interval), but a non-follow read of already-buffered historical output gets
        // every line stamped with the same read-time value, since the true write time
        // isn't recoverable on this platform. A trailing line with no newline yet is
        // left in the returned remainder so it isn't stamped and framed prematurely.
        let prefix = timestampPrefix()
        var remaining = buffer
        while let newlineIndex = remaining.firstIndex(of: 0x0A) {
            let line = prefix + remaining[remaining.startIndex...newlineIndex]
            remaining = remaining[remaining.index(after: newlineIndex)...]
            emitFrame(line, ttyMode: ttyMode, writeOutput: writeOutput)
        }
        return Data(remaining)
    }

    /// The `tail` ring of `scanWindowedBacklog`: the last N passing LOGICAL
    /// lines. A spilled oversized line counts as ONE entry — its fragments
    /// are written to a lazily-created temp file and the entry holds their
    /// byte range, so reading the line back at emission keeps memory
    /// bounded by the retention bound rather than by the (unbounded) length
    /// of a selected line. While a spilled line is still open (its
    /// terminating newline has not been scanned yet), continuation
    /// fragments extend the open entry in place: no other line can arrive
    /// between a line's fragments, so an oversized line can never evict its
    /// own head — a selected line is always emitted whole or not at all.
    private struct WindowTailRing {
        /// How an accepted line/fragment lands in the ring.
        enum Position {
            /// A normal, retention-bounded line held in memory.
            case inline
            /// A complete oversized line (newline included) — one entry, closed.
            case completeSpill
            /// The first fragment of an oversized line still being spilled.
            case spillHead
            /// A later fragment (terminating newline or EOF) of the line
            /// opened by `spillHead`.
            case spillContinuation
        }

        private enum Entry {
            case inline(Data)
            /// One logical line's byte range in the spill file.
            case spilled(offset: Int, length: Int)
        }

        private var entries: [(line: Entry, unixNano: UInt64)] = []
        private var head = 0
        private let limit: Int
        /// The index of the open spilled entry — the oversized line whose
        /// fragments are still arriving — nil once it closed, or once the
        /// cap evicted it (which drops the line's remaining fragments too:
        /// a partially-evicted line must not be emitted).
        private var openSpill: Int?
        private var spill: FileHandle?
        private var spillURL: URL?
        private var spillBytes = 0

        /// Reading a spilled line back in chunks keeps the emission path's
        /// memory bounded too — no frame ever holds a whole oversized line.
        private static let spillReadChunkBytes = 256 * 1024

        init(limit: Int) {
            self.limit = limit
        }

        /// Appends one accepted line (or fragment) as a new logical-line
        /// entry, or extends the open spilled entry.
        mutating func append(_ line: Data, unixNano: UInt64, position: Position) throws {
            switch position {
            case .inline:
                entries.append((.inline(line), unixNano))
                evict()
            case .completeSpill, .spillHead:
                let offset = try writeSpill(line)
                entries.append((.spilled(offset: offset, length: line.count), unixNano))
                if position == .spillHead {
                    openSpill = entries.count - 1
                }
                evict()
            case .spillContinuation:
                // The head fragment may already have been evicted (a tail
                // count smaller than the number of logical lines): the
                // selected line is gone, and so are its remaining fragments.
                guard let open = openSpill, case .spilled(let offset, let length) = entries[open].line else {
                    return
                }
                try writeSpill(line)
                entries[open].line = .spilled(offset: offset, length: length + line.count)
            }
        }

        /// Emits the retained entries — the last `limit` logical lines, the
        /// spilled ones streamed back from the temp file in bounded chunks
        /// (timestamped once, on the line's first chunk).
        mutating func emit(
            ttyMode: Bool, timestamps: Bool, emit: (ByteBuffer) async throws -> Void
        ) async throws {
            guard head < entries.count else { return }
            // All writes are done: hand the spill file over to reading.
            if let spill {
                try spill.close()
                self.spill = nil
            }
            for (line, unixNano) in entries[head...] {
                switch line {
                case .inline(let data):
                    try await emit(stampedFrame(data, unixNano: unixNano, ttyMode: ttyMode, timestamps: timestamps))
                case .spilled(let offset, let length):
                    let handle = try openSpillForReading()
                    try handle.seek(toOffset: UInt64(offset))
                    var remaining = length
                    var first = true
                    while remaining > 0 {
                        let want = min(remaining, Self.spillReadChunkBytes)
                        guard let chunk = try handle.read(upToCount: want), chunk.count == want else {
                            throw Abort(.internalServerError, reason: "log tail spill file could not be read back")
                        }
                        remaining -= want
                        try await emit(
                            stampedFrame(chunk, unixNano: unixNano, ttyMode: ttyMode, timestamps: timestamps && first))
                        first = false
                    }
                }
            }
        }

        /// Closes and removes the spill file, if one was created.
        mutating func cleanUp() {
            if let spill { try? spill.close() }
            spill = nil
            if let spillURL { try? FileManager.default.removeItem(at: spillURL) }
            spillURL = nil
        }

        /// Evicts whole entries past `limit` (the dead prefix is compacted
        /// in bulk, so a large `tail` over a huge window does not shift the
        /// window on every accepted line), invalidating an open spill the
        /// prefix swallowed.
        private mutating func evict() {
            if entries.count - head > limit { head += 1 }
            if let open = openSpill, open < head { openSpill = nil }
            if head > max(limit, 1024) {
                let removed = head
                entries.removeFirst(removed)
                head = 0
                openSpill = openSpill.map { $0 - removed }
            }
        }

        @discardableResult
        private mutating func writeSpill(_ fragment: Data) throws -> Int {
            if spill == nil {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("podm-log-tail-\(UUID().uuidString)")
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw Abort(.internalServerError, reason: "could not create log tail spill file")
                }
                spill = try FileHandle(forWritingTo: url)
                spillURL = url
            }
            let offset = spillBytes
            try spill?.write(contentsOf: fragment)
            spillBytes += fragment.count
            return offset
        }

        private mutating func openSpillForReading() throws -> FileHandle {
            if let spill { return spill }
            guard let spillURL else {
                throw Abort(.internalServerError, reason: "log tail spill file is missing")
            }
            let handle = try FileHandle(forReadingFrom: spillURL)
            spill = handle
            return handle
        }
    }

    /// Backlog-scan boundaries for a windowed logs request, derived from
    /// whether follow is active and whether the container was running when
    /// the request arrived.
    ///
    /// Without follow the scan must read to EOF — the response is the whole
    /// backlog — so EOF is always final. With follow on a STOPPED container
    /// the log can never grow again either: EOF is final too, so the scanner
    /// counts the trailing partial line toward `tail` (moby's `logs -f` on a
    /// stopped container prints the backlog, final partial line included,
    /// then exits) instead of holding it back for a follow loop that can
    /// only confirm what the request-start status already knew — holding it
    /// back mis-selected the tail: `a\nb` with `tail=1` returned both lines.
    ///
    /// With follow on a RUNNING container the scan reads in bounded
    /// batches: a log growing faster than it is scanned never reaches a
    /// read gap on its own, so an unbatched backlog pass would read — with
    /// `tail` set, emitting nothing — indefinitely, out of reach of the
    /// `until` deadline and client-disconnect checks. The whole backlog
    /// must still pass through the scanner (the follow reader applies
    /// neither the tail ring nor journal alignment — handing it unread
    /// backlog made `follow=1&tail=0` emit old output and nonzero tails
    /// select the end of the first batch rather than the backlog's actual
    /// tail), so the boundary the scan drains to is the first READ GAP:
    /// everything written before it is the request's backlog, everything
    /// after it is live output for the follow loop. Between batches the
    /// scan yields (`maxScanBytes` of input per batch) to check the `until`
    /// deadline and probe the client connection.
    static func backlogScanBounds(
        followActive: Bool, containerRunning: Bool
    ) -> (streamEnded: Bool, maxScanBytes: Int?) {
        guard followActive, containerRunning else { return (true, nil) }
        return (false, ContainerLogsRoute.backlogScanMaxBytes)
    }

    /// The windowed backlog scan reads at most this much input between
    /// yield points — twice the journal's byte cap, so the whole
    /// journal-covered portion of the backlog (the only portion with
    /// recorded write times) is judged inside one batch even while evicted
    /// stamps and gap markers straddle a boundary.
    static let backlogScanMaxBytes = 2 * ContainerLogJournal.maxJournalBytes

    /// A logical line still open at a read boundary: an oversized line whose
    /// head fragment was already emitted (or window-dropped). Its write time
    /// and window decision were fixed at the first fragment, so every later
    /// fragment — across follow batches, the backlog-to-follow handoff, and
    /// final flushing — continues that decision instead of being restamped
    /// and re-windowed as a fresh line (which spliced extra timestamp
    /// prefixes into the middle of the line, or emitted a window-dropped
    /// line's terminating fragment once `since` had passed).
    struct WindowedOpenLine {
        /// The line's write time, fixed at its first fragment.
        let unixNano: UInt64
        /// Whether the line passed the since/until window: in-window
        /// continuations are emitted verbatim (any timestamp prefix went out
        /// with the head fragment); out-of-window ones are dropped.
        let inWindow: Bool
    }

    /// What `scanWindowedBacklog` hands onward to a follow loop: the
    /// trailing partial line, plus its open-line state when those bytes
    /// continue an oversized line whose head fragment was already emitted
    /// or window-dropped.
    struct BacklogHandoff {
        var pending: Data
        var openLine: WindowedOpenLine?
    }

    /// Reads the Apple log stream through once, resolving each complete line's
    /// write time from the journal (falling back to read time for lines the
    /// journal does not cover), applying the `since`/`until` window, and
    /// emitting passing lines as framed output. With `tail` set the passing
    /// LOGICAL lines are kept in a ring and emitted at the end — moby applies
    /// `tail` to the window-filtered set — bounded by the tail count, and
    /// counting a spilled oversized line as ONE line (see `WindowTailRing`);
    /// without it they are emitted as they are scanned, so memory stays
    /// bounded by the window rather than the whole log.
    ///
    /// An unterminated line is spilled at `ContainerLogFollower.maxPendingLineBytes`
    /// — the same bound the journal follower discards at: the accumulated
    /// bytes are emitted (preserving the requested output) instead of
    /// buffered, so a newline-free stream cannot grow memory without limit.
    /// A line beyond the bound is one the journal recorded as a gap marker
    /// (never its payload): its first fragment consumes the marker — or the
    /// evicted ordinal, when the cap took the marker — and fixes the line's
    /// write time AND window decision for the whole logical line, so every
    /// later fragment (and the terminating fragment, and EOF) is judged by
    /// the same time: an in-window head can never be followed by a dropped
    /// tail, which would silently lose the line's remaining bytes.
    ///
    /// Returns the trailing partial line, like `processDockerLogFrames`, so a
    /// follow can carry it onward — unless `streamEnded` is set (no follow will
    /// run), in which case the partial line is a genuine final line: it passes
    /// through the same window check, counts toward the `tail` limit (moby's
    /// tail counts an unterminated final line, like `lastLines` does) and is
    /// emitted with the ring, stamped with the journal-recorded time of the
    /// follower's confirmed-exit drain when it covered the fragment, else the
    /// read time. When the
    /// partial line continues a spilled oversized line, the handoff also
    /// carries that line's fixed state (see `WindowedOpenLine`) so the follow
    /// reader does not restamp its remaining fragments.
    ///
    /// `maxScanBytes` bounds how much input one scan BATCH consumes before
    /// yielding; it requires a follow loop to continue the stream, so it must
    /// only be set together with `streamEnded == false`. At each batch
    /// boundary the scan checks the `until` deadline and invokes `yield` —
    /// which must be non-nil whenever `maxScanBytes` is set — to probe the
    /// client connection and let the event loop run; it then CONTINUES the
    /// scan (same alignment, ring and open-line state) rather than handing
    /// the rest of the backlog to the follow reader, which applies neither
    /// the tail ring nor journal alignment. The scan ends at the first read
    /// gap (the backlog boundary: everything before it belongs to this
    /// response's backlog, everything after is live output) or, without
    /// `maxScanBytes`, at EOF.
    static func scanWindowedBacklog(
        read: () throws -> Data?,
        journal: ContainerLogJournal.Contents,
        since: UInt64?,
        until: UInt64?,
        tail: Int?,
        ttyMode: Bool,
        timestamps: Bool,
        nowNanos: () -> UInt64,
        streamEnded: Bool = false,
        maxScanBytes: Int? = nil,
        yield: (() async throws -> Void)? = nil,
        emit: (ByteBuffer) async throws -> Void
    ) async throws -> BacklogHandoff {
        var alignment = ContainerLogJournal.Alignment(
            entries: journal.entries, droppedLines: journal.droppedLines, evictedNanos: journal.evictedNanos)
        var ring = tail.map { WindowTailRing(limit: $0) }
        defer { ring?.cleanUp() }
        var pending = Data()
        // True while `pending` holds the continuation of an oversized line
        // whose head bytes were already spilled: every fragment up to (and
        // including) the terminating newline bypasses journal alignment —
        // the journal holds a gap marker (or an evicted ordinal), not
        // content, for that line.
        var inOversizedLine = false
        // The write time resolved for the logical line currently spilling:
        // fixed at its first fragment and reused by every later fragment,
        // so the whole line shares one window decision.
        var oversizedLineNano: UInt64?

        /// Applies the since/until window to one accepted line (or fragment
        /// of an oversized line) and emits it, or holds it in the tail ring.
        func accept(_ line: Data, unixNano: UInt64, position: WindowTailRing.Position = .inline) async throws {
            // moby: lines written before `since` or after `until` are dropped.
            if let since, unixNano < since { return }
            if let until, unixNano > until { return }
            if ring != nil {
                try ring?.append(line, unixNano: unixNano, position: position)
            } else {
                // Only the FIRST fragment of a spilled line carries the
                // timestamp prefix — continuations are emitted verbatim, or
                // the frames would splice extra prefixes into the middle of
                // the line (the ring's emit applies the same rule).
                try await emit(
                    stampedFrame(
                        line, unixNano: unixNano, ttyMode: ttyMode,
                        timestamps: timestamps && position != .spillContinuation))
            }
        }

        var scannedBytes = 0
        while let chunk = try read(), !chunk.isEmpty {
            pending.append(chunk)
            scannedBytes += chunk.count
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<pending.index(after: newline))
                pending = pending.subdata(in: pending.index(after: newline)..<pending.endIndex)
                if inOversizedLine {
                    // Final fragment of a spilled oversized line: no journal
                    // alignment applies — the marker (or evicted ordinal) was
                    // consumed by the line's first fragment — and the window
                    // decision fixed there holds for this fragment too.
                    inOversizedLine = false
                    let unixNano = oversizedLineNano ?? nowNanos()
                    oversizedLineNano = nil
                    try await accept(line, unixNano: unixNano, position: .spillContinuation)
                    continue
                }
                if line.count > ContainerLogFollower.maxPendingLineBytes {
                    // A complete line beyond the bound (its newline arrived in
                    // the same chunk that crossed it). The journal recorded a
                    // gap marker (or an evicted ordinal), not this payload:
                    // consume it — keeping later lines alignable — and window
                    // the line with its recorded (or the read) time.
                    let unixNano = alignment.consumeGapMarker().recordedNano ?? nowNanos()
                    try await accept(line, unixNano: unixNano, position: .completeSpill)
                    continue
                }
                let unixNano = alignment.timestamp(for: line) ?? nowNanos()
                try await accept(line, unixNano: unixNano)
            }
            if pending.count > ContainerLogFollower.maxPendingLineBytes {
                // Spill the head of an unterminated line at the bound: emit
                // the accumulated bytes instead of buffering them further.
                // The line's FIRST fragment fixes the write time and window
                // decision for the whole logical line.
                if inOversizedLine {
                    try await accept(pending, unixNano: oversizedLineNano ?? nowNanos(), position: .spillContinuation)
                } else {
                    let unixNano = alignment.consumeGapMarker().recordedNano ?? nowNanos()
                    oversizedLineNano = unixNano
                    try await accept(pending, unixNano: unixNano, position: .spillHead)
                    inOversizedLine = true
                }
                pending.removeAll(keepingCapacity: true)
            }
            // Batch boundary while a follow loop will continue the stream:
            // yield (deadline check + client liveness probe) and keep
            // scanning with the same ring/alignment state. Cutting over to
            // the follow reader here instead would hand it unread backlog —
            // it applies neither the tail ring nor journal alignment, so
            // `follow=1&tail=0` emitted old output and nonzero tails
            // selected the end of the first batch, not the backlog's tail.
            if let maxScanBytes, !streamEnded, scannedBytes >= maxScanBytes {
                if let until, nowNanos() > until { break }
                try await yield?()
                scannedBytes = 0
            }
        }
        if streamEnded, !pending.isEmpty {
            // The stream genuinely ends here: the unterminated trailing line is
            // the log's final line, not a mid-write gap — window it and count
            // it toward the tail limit before the retained tail is emitted.
            // A spilled line's final fragment keeps the line's fixed write
            // time and window decision, like every other fragment.
            if inOversizedLine {
                try await accept(pending, unixNano: oversizedLineNano ?? nowNanos(), position: .spillContinuation)
            } else {
                // The follower's confirmed-exit drain journals the final
                // unterminated line (without its missing newline): recover
                // that recorded time — stamping it with the read time made
                // an `--until` after the exit but before this request
                // return nothing for the container's only output.
                let unixNano = alignment.timestamp(for: pending) ?? nowNanos()
                try await accept(pending, unixNano: unixNano)
            }
            pending.removeAll()
        }
        if ring != nil {
            try await ring?.emit(ttyMode: ttyMode, timestamps: timestamps, emit: emit)
        }
        // A spilled line still open at a read gap (or at the scan budget)
        // continues into the follow loop with its fixed time and decision.
        if inOversizedLine, !streamEnded {
            let nano = oversizedLineNano ?? nowNanos()
            let dropped = (since.map { nano < $0 } ?? false) || (until.map { nano > $0 } ?? false)
            return BacklogHandoff(
                pending: pending, openLine: WindowedOpenLine(unixNano: nano, inWindow: !dropped))
        }
        return BacklogHandoff(pending: pending, openLine: nil)
    }

    /// One follow batch reads at most this many bytes before returning, so the
    /// caller writes the accumulated frames and re-checks the client
    /// connection and the `until` deadline between reads. Without the budget,
    /// a container writing faster than the reader is drained keeps the batch
    /// loop reading indefinitely — output is delayed, frames accumulate
    /// without bound, and a client disconnect is never observed.
    static let followBatchMaxBytes = 64 * 1024

    /// One pass of the windowed follow loop: reads whatever is currently
    /// available from the log stream, stamps each complete line with its
    /// arrival time and applies the `since`/`until` window. Returns the framed
    /// output, whether a line passed `until` (the caller ends the follow but
    /// must still emit the accepted frames — dropping them would lose
    /// in-window output that already passed the window check), and whether any
    /// bytes were read. `buffer` carries the trailing partial line across
    /// passes, and `openLine` carries the state of an oversized line still
    /// open across a pass boundary (see `WindowedOpenLine`) so its later
    /// fragments keep the line's fixed time, window decision and prefix
    /// state instead of being restamped as fresh lines.
    ///
    /// An unterminated line is spilled at
    /// `ContainerLogFollower.maxPendingLineBytes` — the accumulated bytes are
    /// emitted instead of buffered, FIXING the line's time and window
    /// decision at that first fragment — and the batch yields after
    /// `followBatchMaxBytes` of input even when the stream still has data, so
    /// neither memory nor output latency can grow without bound while
    /// following a noisy container.
    static func readWindowedFollowBatch(
        from buffer: inout Data,
        read: () throws -> Data?,
        since: UInt64?,
        until: UInt64?,
        ttyMode: Bool,
        timestamps: Bool,
        nowNanos: () -> UInt64,
        openLine: inout WindowedOpenLine?
    ) rethrows -> (frames: [ByteBuffer], reachedUntil: Bool, gotData: Bool) {
        var frames: [ByteBuffer] = []
        var gotData = false
        var reachedUntil = false
        var batchBytes = 0
        readLoop: while let data = try read(), !data.isEmpty {
            gotData = true
            buffer.append(data)
            batchBytes += data.count
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<buffer.index(after: newline))
                buffer = buffer.subdata(in: buffer.index(after: newline)..<buffer.endIndex)
                if let open = openLine {
                    // Terminating fragment of an open spilled line: keep the
                    // line's fixed window decision and prefix state — verbatim
                    // if its head was emitted, dropped if it was not.
                    openLine = nil
                    if open.inWindow {
                        frames.append(stampedFrame(line, unixNano: open.unixNano, ttyMode: ttyMode, timestamps: false))
                    }
                    continue
                }
                let unixNano = nowNanos()
                if let since, unixNano < since { continue }
                if let until, unixNano > until {
                    reachedUntil = true
                    break readLoop
                }
                frames.append(stampedFrame(line, unixNano: unixNano, ttyMode: ttyMode, timestamps: timestamps))
            }
            if buffer.count > ContainerLogFollower.maxPendingLineBytes {
                if let open = openLine {
                    // Continuation fragment of an open line: its decision is
                    // already fixed — emit verbatim or drop, never restamp.
                    if open.inWindow {
                        frames.append(stampedFrame(buffer, unixNano: open.unixNano, ttyMode: ttyMode, timestamps: false))
                    }
                    buffer.removeAll(keepingCapacity: true)
                } else {
                    // Spill the head of an unterminated line at the bound:
                    // emit the accumulated bytes (preserving the requested
                    // output) instead of buffering a newline-free stream
                    // without limit — and FIX the line's time, window
                    // decision and prefix state for its later fragments.
                    let unixNano = nowNanos()
                    if let since, unixNano < since {
                        openLine = WindowedOpenLine(unixNano: unixNano, inWindow: false)
                        buffer.removeAll(keepingCapacity: true)
                    } else if let until, unixNano > until {
                        reachedUntil = true
                        break
                    } else {
                        frames.append(stampedFrame(buffer, unixNano: unixNano, ttyMode: ttyMode, timestamps: timestamps))
                        openLine = WindowedOpenLine(unixNano: unixNano, inWindow: true)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            }
            // Yield after a bounded amount of input so the caller can write
            // and check the deadline between reads.
            if batchBytes >= ContainerLogsRoute.followBatchMaxBytes { break }
        }
        return (frames, reachedUntil, gotData)
    }

    /// Frames one windowed line for output, prefixing the resolved write time
    /// (journal-recorded, or read/arrival time) when `timestamps` is set.
    static func stampedFrame(_ line: Data, unixNano: UInt64, ttyMode: Bool, timestamps: Bool) -> ByteBuffer {
        let payload = timestamps ? timestampPrefix(unixNano) + line : line
        var outputBuffer = ByteBufferAllocator().buffer(capacity: payload.count + (ttyMode ? 0 : 8))
        outputBuffer.writeDockerFrame(streamType: .stdout, data: payload, ttyMode: ttyMode)
        return outputBuffer
    }

    /// Stamps and frames a trailing line left over with no terminating newline —
    /// called once the stream has genuinely ended, not on a mid-stream read gap that
    /// might just mean the writer hasn't flushed the rest of the line yet. The
    /// trailing line is normally not journal-covered (the journal records only
    /// complete lines), so it is stamped with the flush time and must still pass
    /// the since/until window, if any. The exception is the container's FINAL
    /// line, which the follower's confirmed-exit drain journals without its
    /// missing newline: pass its recorded time via `recordedNano` so the window
    /// and the timestamp prefix use the exit-time stamp, not the flush time.
    ///
    /// When the trailing bytes continue an oversized line whose head fragment
    /// was already emitted (or window-dropped), `openLine` carries that
    /// line's fixed state: the fragment is flushed verbatim under the line's
    /// own decision — a new prefix or a flush-time re-windowing would splice
    /// a second timestamp into the line or resurrect a dropped one.
    ///
    /// In the plain (non-windowed) path, an unstamped trailing line was already
    /// emitted inline by `processDockerLogFrames`, so flushing there would
    /// double-emit — hence `emitWithoutTimestamps` is only set by the windowed
    /// path, whose scanner holds partial lines back for window filtering.
    static func flushFinalLogLine(
        _ buffer: Data,
        ttyMode: Bool,
        timestamps: Bool,
        since: UInt64? = nil,
        until: UInt64? = nil,
        openLine: WindowedOpenLine? = nil,
        recordedNano: UInt64? = nil,
        nowNanos: () -> UInt64 = { ContainerLogJournal.currentUnixNano() },
        emitWithoutTimestamps: Bool = false,
        writeOutput: (ByteBuffer) -> Void
    ) {
        guard !buffer.isEmpty, timestamps || emitWithoutTimestamps else { return }
        if let open = openLine {
            if open.inWindow {
                emitFrame(buffer, ttyMode: ttyMode, writeOutput: writeOutput)
            }
            return
        }
        let unixNano = recordedNano ?? nowNanos()
        if let since, unixNano < since { return }
        if let until, unixNano > until { return }
        guard timestamps else {
            emitFrame(buffer, ttyMode: ttyMode, writeOutput: writeOutput)
            return
        }
        emitFrame(timestampPrefix(unixNano) + buffer, ttyMode: ttyMode, writeOutput: writeOutput)
    }

    private static func timestampPrefix(_ unixNano: UInt64? = nil) -> Data {
        let date = unixNano.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000) } ?? Date()
        return Data("\(AppleContainerTimestampResolver.iso8601Timestamp(date)) ".utf8)
    }

    /// Match the container's TTY mode: a TTY produces a raw, unmultiplexed stream, while
    /// non-TTY logs use Docker's 8-byte stdcopy framing. Shared with the attach/exec routes
    /// via writeDockerFrame so the wire format is defined in exactly one place.
    private static func emitFrame(_ data: Data, ttyMode: Bool, writeOutput: (ByteBuffer) -> Void) {
        var outputBuffer = ByteBufferAllocator().buffer(capacity: data.count + (ttyMode ? 0 : 8))
        outputBuffer.writeDockerFrame(streamType: .stdout, data: data, ttyMode: ttyMode)
        writeOutput(outputBuffer)
    }
}
