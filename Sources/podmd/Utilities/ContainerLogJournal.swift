import Foundation
import Logging

/// Per-container timestamped log journal backing `docker logs --since/--until`
/// and accurate historical `--timestamps`.
///
/// Apple Container's log API (`ContainerClient().logs(id:)`) is a forward-only
/// raw byte stream with no per-line write-time metadata, so time-windowed log
/// reads are impossible from the stream alone. While a container runs,
/// `ContainerLogFollower` mirrors each completed output line into this journal
/// together with its arrival time; the logs route then recovers a line's write
/// time by aligning stream lines against journal entries (see `Alignment`).
///
/// Storage follows the app-support layout discipline of
/// `ContainerNameOverrideStore`/`RestartPolicyOverrideStore`, but is keyed by
/// the NATIVE container id (one file per container) because the journal
/// shadows the native Apple log stream, which is per native id. Apple
/// truncates the log file at every boot, so `beginBoot` drops the previous
/// boot's entries — the journal deliberately holds only the current boot.
///
/// Entry framing is `[unixNano: UInt64 LE][streamType: UInt8][len: UInt32 LE]
/// [bytes]` — a length-prefixed record whose payload is exactly one complete
/// newline-terminated stream line, so replayed entries feed straight into
/// `ByteBuffer.writeDockerFrame`. Each container is capped at
/// `maxJournalBytes` (drop-oldest); a crash-truncated file is salvaged to its
/// last complete entry at load.
actor ContainerLogJournal {
    static let shared = ContainerLogJournal()

    struct Entry: Sendable, Equatable {
        let unixNano: UInt64
        let streamType: UInt8
        /// One complete newline-terminated log line, verbatim from the Apple
        /// log stream (including the trailing `\n`).
        let bytes: Data

        static let headerByteCount = 13
        var framedByteCount: Int { Entry.headerByteCount + bytes.count }
    }

    /// Drop-oldest cap per container, counted in framed (on-disk) bytes.
    static let maxJournalBytes = 4 * 1024 * 1024

    /// A single entry payload may never exceed this; a corrupt length field
    /// must not make load allocate gigabytes.
    private static let maxEntryBytes = 16 * 1024 * 1024

    private static let magic = Data("PDLJ".utf8)
    private static let version: UInt32 = 1

    private struct State {
        var entries: [Entry] = []
        var totalFramedBytes = 0
        var fileHandle: FileHandle?
    }

    private var states: [String: State] = [:]
    private var configuredDirectory: URL?
    private let log = Logger(label: "podm.container-log-journal")

    /// Points the journal at a test-controlled storage directory (mirrors the
    /// override stores' `configure`). Unconfigured, the journal lazily defaults
    /// to the same Apple container app-support root `RouteRegistry` uses.
    func configure(storageDirectory: URL) {
        for state in states.values { try? state.fileHandle?.close() }
        states.removeAll()
        configuredDirectory = storageDirectory.appendingPathComponent("podm-log-journals", isDirectory: true)
    }

    private var baseDirectory: URL {
        configuredDirectory
            ?? URL(
                fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/com.apple.container",
                isDirectory: true
            )
            .appendingPathComponent("podm-log-journals", isDirectory: true)
    }

    private func fileURL(_ nativeId: String) -> URL {
        baseDirectory.appendingPathComponent("\(nativeId).journal")
    }

    /// Current-boot journal entries for the container, in stream order.
    /// Loads (and salvage-rewrites) the persisted file on first use.
    func entries(nativeId: String) -> [Entry] {
        loadIfNeeded(nativeId)
        return states[nativeId]?.entries ?? []
    }

    /// Resets the journal for a new container boot: Apple truncates the log
    /// file at every boot, so previous-boot entries can never align with the
    /// new stream and are dropped instead of risking false timestamp matches.
    /// Epoch-gated like `append` so a superseded follower cannot wipe its
    /// replacement's entries.
    func beginBoot(nativeId: String, epoch: UInt64, isCurrentEpoch: @Sendable () async -> Bool) async {
        guard await isCurrentEpoch() else { return }
        loadIfNeeded(nativeId)
        guard states[nativeId] != nil else { return }
        try? states[nativeId]?.fileHandle?.close()
        states[nativeId]?.fileHandle = nil
        states[nativeId]?.entries = []
        states[nativeId]?.totalFramedBytes = 0
        do {
            try FileManager.default.removeItem(at: fileURL(nativeId))
        } catch {
            // A missing file is the common case (first boot of this container).
        }
    }

    /// Appends follower-recorded entries, enforcing the drop-oldest cap.
    /// Epoch-gated: only the follower holding the registry's current epoch for
    /// this container may write, so a superseded follower exiting its poll
    /// loop can never interleave stale entries into a newer boot's journal.
    func append(
        nativeId: String,
        epoch: UInt64,
        _ newEntries: [Entry],
        isCurrentEpoch: @Sendable () async -> Bool
    ) async {
        guard await isCurrentEpoch() else { return }
        guard !newEntries.isEmpty else { return }
        loadIfNeeded(nativeId)
        var state = states[nativeId] ?? State()
        state.entries.append(contentsOf: newEntries)
        state.totalFramedBytes += newEntries.reduce(0) { $0 + $1.framedByteCount }
        var trimmed = false
        while state.totalFramedBytes > Self.maxJournalBytes, let oldest = state.entries.first {
            state.totalFramedBytes -= oldest.framedByteCount
            state.entries.removeFirst()
            trimmed = true
        }
        persist(state: &state, nativeId: nativeId, trimmed: trimmed, appended: newEntries)
        states[nativeId] = state
    }

    /// Deletes the journal (and its file) for a container — called from the
    /// delete/auto-remove cleanup paths, where the container is going away.
    func remove(nativeId: String) {
        if var state = states[nativeId] {
            try? state.fileHandle?.close()
            state.fileHandle = nil
        }
        states[nativeId] = nil
        try? FileManager.default.removeItem(at: fileURL(nativeId))
    }

    // MARK: - Persistence

    private func loadIfNeeded(_ nativeId: String) {
        guard states[nativeId] == nil else { return }
        var state = State()
        let url = fileURL(nativeId)
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            let (entries, salvaged) = Self.parse(data)
            state.entries = entries
            state.totalFramedBytes = entries.reduce(0) { $0 + $1.framedByteCount }
            if salvaged {
                // A crash mid-write left a partial trailing entry; keep the
                // parseable prefix so appends land on a valid boundary again.
                log.warning("log journal for \(nativeId) had a partial trailing entry — salvaged \(entries.count) entries")
                rewriteFile(url, entries: entries)
            }
        }
        states[nativeId] = state
    }

    private func persist(state: inout State, nativeId: String, trimmed: Bool, appended: [Entry]) {
        let url = fileURL(nativeId)
        if trimmed {
            rewriteFile(url, entries: state.entries)
            return
        }
        if state.fileHandle == nil {
            do {
                try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: Self.headerData()) else {
                        log.error("could not create log journal file at \(url.path)")
                        return
                    }
                }
                state.fileHandle = try FileHandle(forWritingTo: url)
            } catch {
                log.error("could not open log journal file at \(url.path): \(error)")
                return
            }
            _ = try? state.fileHandle?.seekToEnd()
        }
        var blob = Data()
        for entry in appended { blob.append(Self.encode(entry)) }
        do {
            try state.fileHandle?.write(contentsOf: blob)
        } catch {
            log.error("could not append to log journal for \(nativeId): \(error)")
        }
    }

    private func rewriteFile(_ url: URL, entries: [Entry]) {
        var contents = Self.headerData()
        for entry in entries { contents.append(Self.encode(entry)) }
        if !FileManager.default.createFile(atPath: url.path, contents: contents, attributes: nil) {
            log.error("could not rewrite log journal file at \(url.path)")
        }
    }

    // MARK: - Framing

    private static func headerData() -> Data {
        var data = magic
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Encodes one entry with its length-prefixed framing. Internal so the
    /// tests can pin the on-disk format.
    static func encode(_ entry: Entry) -> Data {
        var data = Data(capacity: entry.framedByteCount)
        withUnsafeBytes(of: entry.unixNano.littleEndian) { data.append(contentsOf: $0) }
        data.append(entry.streamType)
        withUnsafeBytes(of: UInt32(clamping: entry.bytes.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(entry.bytes)
        return data
    }

    /// Parses a journal file image. Returns the complete entries and whether
    /// the file had to be salvaged (bad magic/version, or a truncated or
    /// oversized trailing record).
    static func parse(_ data: Data) -> (entries: [Entry], salvaged: Bool) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return ([], true) }
        guard Data(bytes[0..<4]) == magic else { return ([], true) }
        let version = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        guard version == Self.version else { return ([], true) }
        var entries: [Entry] = []
        var offset = 8
        while offset + Entry.headerByteCount <= bytes.count {
            let nano =
                UInt64(bytes[offset])
                | UInt64(bytes[offset + 1]) << 8 | UInt64(bytes[offset + 2]) << 16 | UInt64(bytes[offset + 3]) << 24
                | UInt64(bytes[offset + 4]) << 32 | UInt64(bytes[offset + 5]) << 40
                | UInt64(bytes[offset + 6]) << 48 | UInt64(bytes[offset + 7]) << 56
            let streamType = bytes[offset + 8]
            let payloadLength =
                UInt32(bytes[offset + 9]) | UInt32(bytes[offset + 10]) << 8
                | UInt32(bytes[offset + 11]) << 16 | UInt32(bytes[offset + 12]) << 24
            let payloadStart = offset + Entry.headerByteCount
            let payloadByteCount = Int(payloadLength)
            guard payloadByteCount >= 0, payloadByteCount <= maxEntryBytes, payloadStart + payloadByteCount <= bytes.count else {
                return (entries, true)
            }
            entries.append(
                Entry(unixNano: nano, streamType: streamType, bytes: Data(bytes[payloadStart..<(payloadStart + payloadByteCount)])))
            offset = payloadStart + payloadByteCount
        }
        return (entries, offset != bytes.count)
    }

    /// Wall-clock unix nanoseconds — the arrival timestamp a follower stamps
    /// journal entries (and the fallback stamp for unjournaled lines) with.
    static func currentUnixNano() -> UInt64 {
        let seconds = Date().timeIntervalSince1970
        guard seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000)
    }
}

extension ContainerLogJournal {
    /// Sequentially matches Apple log stream lines against journal entries so
    /// a reader can recover each line's write time. The follower journals every
    /// completed line of a boot in order, so while the journal covers the
    /// stream, the k-th stream line equals the k-th entry. The first mismatch
    /// (journal stale relative to the stream, a superseded boot, corruption)
    /// disables matching for the rest of the scan instead of returning wrong
    /// times for coincidentally identical lines.
    struct Alignment {
        private let entries: [Entry]
        private var index = 0
        private var usable = true

        init(entries: [Entry]) {
            self.entries = entries
        }

        /// The journal-recorded time for `line`, or nil when the line is not
        /// covered by the journal (follower behind) or alignment has failed.
        mutating func timestamp(for line: Data) -> UInt64? {
            guard usable, index < entries.count else { return nil }
            let entry = entries[index]
            guard entry.bytes == line else {
                usable = false
                return nil
            }
            index += 1
            return entry.unixNano
        }
    }
}
