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

            let body = Response.Body.idleTracked(stream: { writer in
                Task.detached {
                    var buffer = Data()

                    // Flushes any trailing line left in `buffer` with no terminating
                    // newline yet, then closes out the response. Only call this once
                    // the stream has genuinely ended — flushing on a mid-stream read
                    // gap could stamp and emit a line the writer hasn't finished yet.
                    // The trailing line can never be journal-covered (the journal
                    // records only complete lines), so it is stamped with the flush
                    // time and still has to pass the since/until window, if any.
                    func finish() {
                        ContainerLogsRoute.flushFinalLogLine(
                            buffer, ttyMode: isTTY, timestamps: timestamps, since: since, until: until,
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
                                finish()
                                return
                            }
                            buffer = try await ContainerLogsRoute.scanWindowedBacklog(
                                read: { try fileHandle.read(upToCount: 4096) },
                                journal: bootJournal,
                                since: since,
                                until: until,
                                tail: tail,
                                ttyMode: isTTY,
                                timestamps: timestamps,
                                nowNanos: { ContainerLogJournal.currentUnixNano() },
                                streamEnded: !followActive
                            ) { frame in
                                // Await each write so a client disconnect aborts the
                                // response instead of queueing the whole window.
                                try await writer.write(.buffer(frame)).get()
                            }
                        } else if let tail {
                            // tail=0 without follow returns an empty backlog; skip
                            // reading the log at all. With follow the read-through
                            // below still runs so the handle reaches EOF and the
                            // follow loop emits only new lines.
                            if tail == 0, !follow {
                                finish()
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
                                    finish()
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
                            finish()
                            return
                        }
                    } catch {
                        finish()
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
                                    nowNanos: { ContainerLogJournal.currentUnixNano() })
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
                        finish()
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
                    finish()
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

    /// Reads the Apple log stream through once, resolving each complete line's
    /// write time from the journal (falling back to read time for lines the
    /// journal does not cover), applying the `since`/`until` window, and
    /// emitting passing lines as framed output. With `tail` set the passing
    /// lines are kept in a ring and emitted at the end — moby applies `tail` to
    /// the window-filtered set — bounded by the tail count; without it they are
    /// emitted as they are scanned, so memory stays bounded by the window
    /// rather than the whole log. The ring is a head-indexed array (the dead
    /// prefix is compacted in bulk), so a large `tail` over a huge window does
    /// not shift the window on every accepted line.
    ///
    /// An unterminated line is spilled at `ContainerLogFollower.maxPendingLineBytes`
    /// — the same bound the journal follower discards at: the accumulated
    /// bytes are emitted (preserving the requested output) instead of
    /// buffered, so a newline-free stream cannot grow memory without limit.
    /// A line beyond the bound is one the journal recorded as a gap marker
    /// (never its payload): its first fragment consumes the marker and the
    /// rest bypass alignment, so the lines after it keep their recorded
    /// timestamps.
    ///
    /// Returns the trailing partial line, like `processDockerLogFrames`, so a
    /// follow can carry it onward — unless `streamEnded` is set (no follow will
    /// run), in which case the partial line is a genuine final line: it passes
    /// through the same window check, counts toward the `tail` limit (moby's
    /// tail counts an unterminated final line, like `lastLines` does) and is
    /// emitted with the ring, stamped with read time. It can never be
    /// journal-covered (the journal records only complete lines).
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
        emit: (ByteBuffer) async throws -> Void
    ) async throws -> Data {
        var alignment = ContainerLogJournal.Alignment(entries: journal.entries, droppedLines: journal.droppedLines)
        var ring: [(line: Data, unixNano: UInt64)] = []
        var ringHead = 0
        var pending = Data()
        // True while `pending` holds the continuation of an oversized line
        // whose head bytes were already spilled: every fragment up to (and
        // including) the terminating newline bypasses journal alignment —
        // the journal holds a gap marker, not content, for that line.
        var inOversizedLine = false

        /// Applies the since/until window to one accepted line (or fragment
        /// of an oversized line) and emits it, or holds it in the tail ring.
        func accept(_ line: Data, unixNano: UInt64) async throws {
            // moby: lines written before `since` or after `until` are dropped.
            if let since, unixNano < since { return }
            if let until, unixNano > until { return }
            if let tail {
                ring.append((line, unixNano))
                if ring.count - ringHead > tail { ringHead += 1 }
                // Compact the dead prefix in bulk once it outgrows the
                // live window, so the array stays ~2x tail at most.
                if ringHead > max(tail, 1024) {
                    ring.removeFirst(ringHead)
                    ringHead = 0
                }
            } else {
                try await emit(stampedFrame(line, unixNano: unixNano, ttyMode: ttyMode, timestamps: timestamps))
            }
        }

        while let chunk = try read(), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<pending.index(after: newline))
                pending = pending.subdata(in: pending.index(after: newline)..<pending.endIndex)
                if inOversizedLine {
                    // Final fragment of a spilled oversized line: no journal
                    // alignment applies — the marker was consumed by the
                    // line's first fragment.
                    inOversizedLine = false
                    try await accept(line, unixNano: nowNanos())
                    continue
                }
                if line.count > ContainerLogFollower.maxPendingLineBytes {
                    // A complete line beyond the bound (its newline arrived in
                    // the same chunk that crossed it). The journal recorded a
                    // gap marker, not this payload: consume the marker —
                    // keeping later lines alignable — and window the line with
                    // the marker's (or the read) time.
                    let markerNano = alignment.consumeGapMarker()
                    try await accept(line, unixNano: markerNano ?? nowNanos())
                    continue
                }
                let unixNano = alignment.timestamp(for: line) ?? nowNanos()
                try await accept(line, unixNano: unixNano)
            }
            if pending.count > ContainerLogFollower.maxPendingLineBytes {
                // Spill the head of an unterminated line at the bound: emit
                // the accumulated bytes instead of buffering them further.
                // The line's first fragment consumes any journal gap marker;
                // the rest bypass alignment until the terminating newline.
                let markerNano = inOversizedLine ? nil : alignment.consumeGapMarker()
                inOversizedLine = true
                try await accept(pending, unixNano: markerNano ?? nowNanos())
                pending.removeAll(keepingCapacity: true)
            }
        }
        if streamEnded, !pending.isEmpty {
            // The stream genuinely ends here: the unterminated trailing line is
            // the log's final line, not a mid-write gap — window it and count
            // it toward the tail limit before the retained tail is emitted.
            let unixNano = nowNanos()
            let passesWindow = (since.map { unixNano >= $0 } ?? true) && (until.map { unixNano <= $0 } ?? true)
            if passesWindow {
                if let tail {
                    ring.append((pending, unixNano))
                    if ring.count - ringHead > tail { ringHead += 1 }
                } else {
                    try await emit(stampedFrame(pending, unixNano: unixNano, ttyMode: ttyMode, timestamps: timestamps))
                }
            }
            pending.removeAll()
        }
        if ringHead < ring.count {
            for (line, unixNano) in ring[ringHead...] {
                try await emit(stampedFrame(line, unixNano: unixNano, ttyMode: ttyMode, timestamps: timestamps))
            }
        }
        return pending
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
    /// passes.
    ///
    /// An unterminated line is spilled at
    /// `ContainerLogFollower.maxPendingLineBytes` — the accumulated bytes are
    /// emitted instead of buffered — and the batch yields after
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
        nowNanos: () -> UInt64
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
                let unixNano = nowNanos()
                if let since, unixNano < since { continue }
                if let until, unixNano > until {
                    reachedUntil = true
                    break readLoop
                }
                frames.append(stampedFrame(line, unixNano: unixNano, ttyMode: ttyMode, timestamps: timestamps))
            }
            if buffer.count > ContainerLogFollower.maxPendingLineBytes {
                // Spill the head of an unterminated line at the bound: emit
                // the accumulated bytes (preserving the requested output)
                // instead of buffering a newline-free stream without limit.
                let unixNano = nowNanos()
                if let since, unixNano < since {
                    buffer.removeAll(keepingCapacity: true)
                } else if let until, unixNano > until {
                    reachedUntil = true
                    break
                } else {
                    frames.append(stampedFrame(buffer, unixNano: unixNano, ttyMode: ttyMode, timestamps: timestamps))
                    buffer.removeAll(keepingCapacity: true)
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
    /// trailing line can never be journal-covered (the journal records only
    /// complete lines), so it is stamped with the flush time and must still pass
    /// the since/until window, if any.
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
        nowNanos: () -> UInt64 = { ContainerLogJournal.currentUnixNano() },
        emitWithoutTimestamps: Bool = false,
        writeOutput: (ByteBuffer) -> Void
    ) {
        guard !buffer.isEmpty, timestamps || emitWithoutTimestamps else { return }
        let unixNano = nowNanos()
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
