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
/// `maxJournalBytes` (drop-oldest, with hysteresis); a crash-truncated file is
/// salvaged to its last complete entry at load.
///
/// The file header is `PDLJ` + version (u32 LE) + droppedLines (u64 LE,
/// version 2 only): the count of stream lines the cap has evicted before the
/// first retained entry, so a reloaded journal can still align its retained
/// suffix against a log read from byte zero. Version 1 files (no count) load
/// with a count of zero.
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

    /// The journal's current-boot view of one container: the retained
    /// entries plus the count of stream lines the cap evicted before
    /// `entries.first` — alignment must skip that many log lines to line
    /// the suffix up with a stream read from byte zero.
    struct Contents: Sendable {
        let entries: [Entry]
        let droppedLines: Int

        init(entries: [Entry] = [], droppedLines: Int = 0) {
            self.entries = entries
            self.droppedLines = droppedLines
        }
    }

    /// Drop-oldest cap per container, counted in framed (on-disk) bytes.
    static let maxJournalBytes = 4 * 1024 * 1024

    /// A single entry payload may never exceed this; a corrupt length field
    /// must not make load allocate gigabytes.
    private static let maxEntryBytes = 16 * 1024 * 1024

    private static let magic = Data("PDLJ".utf8)
    private static let version: UInt32 = 2

    private struct State {
        var entries: [Entry] = []
        var totalFramedBytes = 0
        var droppedLines = 0
        var fileHandle: FileHandle?
    }

    private var states: [String: State] = [:]
    /// The follower epoch currently allowed to write each container's
    /// journal. Checked synchronously inside the actor so the gate and the
    /// mutation are one step — a superseded follower that passed an external
    /// check before suspending can never interleave a stale write.
    private var writerEpochs: [String: UInt64] = [:]
    /// The epoch at which each container was torn down (`remove`): later
    /// activations must carry a strictly higher epoch, so a stale follower
    /// cannot recreate a deleted container's journal.
    private var tombstoneEpochs: [String: UInt64] = [:]
    private var configuredDirectory: URL?
    private let log = Logger(label: "podm.container-log-journal")

    /// Points the journal at a test-controlled storage directory (mirrors the
    /// override stores' `configure`). Unconfigured, the journal lazily defaults
    /// to the same Apple container app-support root `RouteRegistry` uses.
    func configure(storageDirectory: URL) {
        for state in states.values { try? state.fileHandle?.close() }
        states.removeAll()
        writerEpochs.removeAll()
        tombstoneEpochs.removeAll()
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

    /// Current-boot journal contents for the container: the retained entries
    /// plus the evicted-prefix line count alignment must skip. Loads (and
    /// salvage-rewrites) the persisted file on first use.
    func contents(nativeId: String) -> Contents {
        loadIfNeeded(nativeId)
        guard let state = states[nativeId] else { return Contents() }
        return Contents(entries: state.entries, droppedLines: state.droppedLines)
    }

    /// Current-boot journal entries for the container, in stream order.
    /// Loads (and salvage-rewrites) the persisted file on first use.
    func entries(nativeId: String) -> [Entry] {
        contents(nativeId: nativeId).entries
    }

    /// Resets the journal for a new container boot: Apple truncates the log
    /// file at every boot, so previous-boot entries can never align with the
    /// new stream and are dropped instead of risking false timestamp matches.
    /// Epoch-gated inside the actor: a superseded (older-epoch) follower can
    /// never wipe its replacement's entries.
    func beginBoot(nativeId: String, epoch: UInt64) {
        activate(nativeId: nativeId, epoch: epoch, reset: true)
    }

    /// Adopts the persisted journal for the container's CURRENT boot — the
    /// daemon-restart/resume path. Registers `epoch` as the journal's writer
    /// without dropping entries, so a resumed follower keeps aligning against
    /// what the previous process recorded.
    func resumeBoot(nativeId: String, epoch: UInt64) {
        activate(nativeId: nativeId, epoch: epoch, reset: false)
    }

    private func activate(nativeId: String, epoch: UInt64, reset: Bool) {
        guard epoch > tombstoneEpochs[nativeId] ?? 0 else { return }
        guard epoch >= writerEpochs[nativeId] ?? 0 else { return }
        writerEpochs[nativeId] = epoch
        guard reset else { return }
        loadIfNeeded(nativeId)
        guard states[nativeId] != nil else { return }
        try? states[nativeId]?.fileHandle?.close()
        states[nativeId]?.fileHandle = nil
        states[nativeId]?.entries = []
        states[nativeId]?.totalFramedBytes = 0
        states[nativeId]?.droppedLines = 0
        do {
            try FileManager.default.removeItem(at: fileURL(nativeId))
        } catch {
            // A missing file is the common case (first boot of this container).
        }
    }

    /// Appends follower-recorded entries, enforcing the drop-oldest cap with
    /// hysteresis (a trim goes to 75% of the cap, so a container sitting at
    /// the cap does not rewrite the whole file on every follower pass).
    /// Epoch-gated inside the actor: only the follower whose epoch was
    /// accepted by `beginBoot`/`resumeBoot` may write, so a superseded
    /// follower exiting its poll loop can never interleave stale entries into
    /// a newer boot's journal — the check and the mutation are one
    /// synchronous step, with no suspension in between.
    func append(nativeId: String, epoch: UInt64, _ newEntries: [Entry]) {
        guard writerEpochs[nativeId] == epoch else { return }
        guard !newEntries.isEmpty else { return }
        loadIfNeeded(nativeId)
        var state = states[nativeId] ?? State()
        state.entries.append(contentsOf: newEntries)
        state.totalFramedBytes += newEntries.reduce(0) { $0 + $1.framedByteCount }
        var trimmed = false
        if state.totalFramedBytes > Self.maxJournalBytes {
            // Evict the counted prefix in ONE removal — removeFirst() per
            // evicted entry is quadratic in the evicted line count.
            let targetBytes = Self.maxJournalBytes * 3 / 4
            var evicted = 0
            while state.totalFramedBytes > targetBytes, evicted < state.entries.count {
                state.totalFramedBytes -= state.entries[evicted].framedByteCount
                evicted += 1
            }
            if evicted > 0 {
                state.entries.removeFirst(evicted)
                state.droppedLines += evicted
                trimmed = true
            }
        }
        persist(state: &state, nativeId: nativeId, trimmed: trimmed, appended: newEntries)
        states[nativeId] = state
    }

    /// Deletes the journal (and its file) for a container — called from the
    /// delete/auto-remove/prune cleanup paths, where the container is going
    /// away. Tombstones the writer epoch so a stale follower that already
    /// passed its gate cannot recreate the state or the file.
    func remove(nativeId: String) {
        try? states[nativeId]?.fileHandle?.close()
        tombstoneEpochs[nativeId] = max(tombstoneEpochs[nativeId] ?? 0, writerEpochs[nativeId] ?? 0)
        writerEpochs[nativeId] = nil
        states[nativeId] = nil
        try? FileManager.default.removeItem(at: fileURL(nativeId))
    }

    // MARK: - Persistence

    private func loadIfNeeded(_ nativeId: String) {
        guard states[nativeId] == nil else { return }
        var state = State()
        let url = fileURL(nativeId)
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            let (entries, droppedLines, salvaged) = Self.parse(data)
            state.entries = entries
            state.droppedLines = droppedLines
            state.totalFramedBytes = entries.reduce(0) { $0 + $1.framedByteCount }
            if salvaged {
                // A crash mid-write left a partial trailing entry; keep the
                // parseable prefix so appends land on a valid boundary again.
                log.warning("log journal for \(nativeId) had a partial trailing entry — salvaged \(entries.count) entries")
                rewriteFile(url, entries: entries, droppedLines: droppedLines)
            }
        }
        states[nativeId] = state
    }

    private func persist(state: inout State, nativeId: String, trimmed: Bool, appended: [Entry]) {
        let url = fileURL(nativeId)
        if trimmed {
            // The rewrite replaces the file; the cached handle would keep
            // writing at its stale offset into the old inode. Close and clear
            // it so the next append reopens and seeks to the actual end.
            try? state.fileHandle?.close()
            state.fileHandle = nil
            rewriteFile(url, entries: state.entries, droppedLines: state.droppedLines)
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

    private func rewriteFile(_ url: URL, entries: [Entry], droppedLines: Int) {
        // The first append of a container can already exceed the cap (a huge
        // backlog batch), landing here before the plain append path has ever
        // created the journal directory — createFile does not create parents.
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        var contents = Self.headerData(droppedLines: droppedLines)
        for entry in entries { contents.append(Self.encode(entry)) }
        if !FileManager.default.createFile(atPath: url.path, contents: contents, attributes: nil) {
            log.error("could not rewrite log journal file at \(url.path)")
        }
    }

    // MARK: - Framing

    private static func headerData(droppedLines: Int = 0) -> Data {
        var data = magic
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(droppedLines).littleEndian) { data.append(contentsOf: $0) }
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

    /// Parses a journal file image. Returns the complete entries, the evicted
    /// prefix's line count (0 for version-1 files), and whether the file had
    /// to be salvaged (bad magic/version, or a truncated or oversized
    /// trailing record).
    static func parse(_ data: Data) -> (entries: [Entry], droppedLines: Int, salvaged: Bool) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return ([], 0, true) }
        guard Data(bytes[0..<4]) == magic else { return ([], 0, true) }
        let version = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        var droppedLines = 0
        var offset = 8
        if version == 2 {
            // Version 2 carries the evicted-prefix line count; a short header
            // is a truncated file, salvaged to nothing.
            guard bytes.count >= 16 else { return ([], 0, true) }
            droppedLines =
                Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
                | Int(bytes[12]) << 32 | Int(bytes[13]) << 40 | Int(bytes[14]) << 48 | Int(bytes[15]) << 56
            offset = 16
        } else {
            guard version == 1 else { return ([], 0, true) }
        }
        var entries: [Entry] = []
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
                return (entries, droppedLines, true)
            }
            entries.append(
                Entry(unixNano: nano, streamType: streamType, bytes: Data(bytes[payloadStart..<(payloadStart + payloadByteCount)])))
            offset = payloadStart + payloadByteCount
        }
        return (entries, droppedLines, offset != bytes.count)
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
    /// a reader can recover each line's write time. The follower journals
    /// every completed line of a boot in order, so while the journal covers
    /// the stream, the k-th stream line equals the k-th entry — except for
    /// the `droppedLines` the cap evicted, which are skipped up front so the
    /// retained suffix still lines up with a stream read from byte zero. The
    /// first mismatch (journal stale relative to the stream, a superseded
    /// boot, corruption) disables matching for the rest of the scan instead
    /// of returning wrong times for coincidentally identical lines.
    struct Alignment {
        private let entries: [Entry]
        private let droppedLines: Int
        private var index = 0
        private var skipped = 0
        private var usable = true

        init(entries: [Entry], droppedLines: Int = 0) {
            self.entries = entries
            self.droppedLines = droppedLines
        }

        /// How one stream line relates to the journal.
        enum Coverage {
            /// Journal-recorded write time for the line.
            case covered(UInt64)
            /// The line falls in the evicted prefix: no time is recoverable,
            /// but it was already accounted for — a follower must not
            /// re-journal it.
            case evicted
            /// Not covered by the journal (follower behind, or alignment
            /// failed) — a follower records it, a reader falls back to read
            /// time.
            case fresh
        }

        mutating func classify(_ line: Data) -> Coverage {
            guard usable else { return .fresh }
            if skipped < droppedLines {
                skipped += 1
                return .evicted
            }
            guard index < entries.count else { return .fresh }
            let entry = entries[index]
            guard entry.bytes == line else {
                usable = false
                return .fresh
            }
            index += 1
            return .covered(entry.unixNano)
        }

        /// The journal-recorded time for `line`, or nil when the line is not
        /// covered by the journal (follower behind, evicted, or alignment
        /// has failed).
        mutating func timestamp(for line: Data) -> UInt64? {
            if case .covered(let unixNano) = classify(line) { return unixNano }
            return nil
        }

        /// Whether a content mismatch has disabled matching — the journal is
        /// provably not from this boot. The follower uses this to self-heal
        /// (reset the stale journal) instead of restamping history.
        var failed: Bool { !usable }
    }
}
