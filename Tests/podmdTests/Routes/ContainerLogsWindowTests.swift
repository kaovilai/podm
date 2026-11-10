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

    private func journal(_ lines: [(nano: UInt64, line: String)]) -> [ContainerLogJournal.Entry] {
        lines.map { ContainerLogJournal.Entry(unixNano: $0.nano, streamType: 1, bytes: Data($0.line.utf8)) }
    }

    /// Drives the scanner over `stream` in fixed-size chunks and collects the
    /// framed payloads (non-TTY: an 8-byte stdcopy header precedes each).
    private func scan(
        _ stream: String,
        journal: [ContainerLogJournal.Entry] = [],
        since: UInt64? = nil,
        until: UInt64? = nil,
        tail: Int? = nil,
        timestamps: Bool = false,
        ttyMode: Bool = false,
        nowNanos: UInt64 = 999_999_999_999
    ) async throws -> (payloads: [String], remainder: Data) {
        let bytes = Array(stream.utf8)
        var offset = 0
        var payloads: [String] = []
        let remainder = try await ContainerLogsRoute.scanWindowedBacklog(
            read: {
                guard offset < bytes.count else { return nil }
                let next = min(offset + 3, bytes.count)  // tiny chunks split lines mid-way
                defer { offset = next }
                return Data(bytes[offset..<next])
            },
            journalEntries: journal,
            since: since,
            until: until,
            tail: tail,
            ttyMode: ttyMode,
            timestamps: timestamps,
            nowNanos: { nowNanos }
        ) { frame in
            var frame = frame
            if !ttyMode { frame.moveReaderIndex(forwardBy: 8) }  // skip the stdcopy header
            let payload = frame.readData(length: frame.readableBytes)!
            payloads.append(String(decoding: payload, as: UTF8.self))
        }
        return (payloads, remainder)
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
            journalEntries: fixture,
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
