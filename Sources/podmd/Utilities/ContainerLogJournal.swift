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
/// version 2+): the count of stream lines the cap has evicted before the
/// first retained entry, so a reloaded journal can still align its retained
/// suffix against a log read from byte zero. Version 1 files (no count) load
/// with a count of zero. Version 3 appends the evicted prefix's per-line
/// arrival stamps (`evictedNanoCount: u32 LE` + `unixNano: u64 LE` each,
/// bounded by `maxEvictedNanos`): without them, a windowed reader could only
/// stamp evicted lines with the CURRENT read time, so a recent `--since`
/// included old output and a past `--until` excluded output that belonged in
/// the window. Version 2 files load with no stamps (read-time fallback).
/// Version 4 appends the boot identity (`hasBootId: u8` + `bootIdNano:
/// u64 LE` when the flag is nonzero — the boot's `startedDate` in unix
/// nanoseconds): a resumed follower compares it against the container's
/// CURRENT startedDate and resets the journal when they differ, so a
/// container that rebooted while podmd was down cannot lend its previous
/// boot's timestamps to identical startup lines (a coincidence the
/// first-mismatch self-heal can never catch). Older versions load with no
/// boot identity and keep the alignment-based detection.
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

        /// A gap marker: records that ONE stream line was consumed without
        /// retaining its bytes — the follower's oversized-line discard path.
        /// Encoded as an entry with an EMPTY payload (a real line always
        /// carries at least its trailing `\n`), so alignment can consume the
        /// skipped line's ordinal — and its discard time — without ever
        /// holding the oversized payload.
        static func gapMarker(unixNano: UInt64) -> Entry {
            // streamType is meaningless for a marker (no payload is framed);
            // stdin's raw value keeps the encoding uniform.
            Entry(unixNano: unixNano, streamType: 0, bytes: Data())
        }

        /// Whether this entry is a gap marker rather than a retained line.
        var isGapMarker: Bool { bytes.isEmpty }
    }

    /// The journal's current-boot view of one container: the retained
    /// entries plus the count of stream lines the cap evicted before
    /// `entries.first` — alignment must skip that many log lines to line
    /// the suffix up with a stream read from byte zero — and the evicted
    /// prefix's retained arrival stamps (see `maxEvictedNanos`), which let
    /// a windowed reader judge evicted lines by WHEN they were written
    /// instead of by the current read time.
    struct Contents: Sendable {
        let entries: [Entry]
        let droppedLines: Int
        /// Arrival stamps of the most recently evicted lines, in stream
        /// order — a suffix of the evicted prefix (older evictions beyond
        /// the bound are dropped; see `maxEvictedNanos`).
        let evictedNanos: [UInt64]

        init(entries: [Entry] = [], droppedLines: Int = 0, evictedNanos: [UInt64] = []) {
            self.entries = entries
            self.droppedLines = droppedLines
            self.evictedNanos = evictedNanos
        }
    }

    /// Drop-oldest cap per container, counted in framed (on-disk) bytes.
    static let maxJournalBytes = 4 * 1024 * 1024

    /// How many evicted lines' arrival stamps are retained (drop-oldest,
    /// with hysteresis, like the entry cap): 8 bytes per line keeps the
    /// windowed readers' `--since`/`--until` judgments exact for the most
    /// recent evictions while bounding the metadata a chatty container can
    /// accumulate. Evictions older than the retained window fall back to
    /// the oldest retained stamp — an upper bound on their write time.
    static let maxEvictedNanos = 65_536

    /// A single entry payload may never exceed this; a corrupt length field
    /// must not make load allocate gigabytes.
    private static let maxEntryBytes = 16 * 1024 * 1024

    private static let magic = Data("PDLJ".utf8)
    private static let version: UInt32 = 4

    private struct State {
        var entries: [Entry] = []
        var totalFramedBytes = 0
        var droppedLines = 0
        var evictedNanos: [UInt64] = []
        /// The boot identity (`startedDate` unix nanos) this journal belongs
        /// to, when known — see the version-4 header above. Nil means the
        /// boot was never identified (no `startedDate` available), and
        /// identity comparisons fall back to content alignment.
        var bootIdNano: UInt64?
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
    ///
    /// IDEMPOTENT per directory: reconfiguring the SAME directory is a no-op.
    /// Clearing live state on a same-dir reconfigure would close the cached
    /// writers and drop the writer epochs of followers other test suites
    /// armed, silently discarding their appends — the route lifecycle suite
    /// relies on this when every test installs the same process-wide test
    /// directory.
    func configure(storageDirectory: URL) {
        let newDirectory = storageDirectory.appendingPathComponent("podm-log-journals", isDirectory: true)
        guard newDirectory != configuredDirectory else { return }
        for state in states.values { try? state.fileHandle?.close() }
        states.removeAll()
        writerEpochs.removeAll()
        tombstoneEpochs.removeAll()
        configuredDirectory = newDirectory
    }

    /// The storage root this journal writes to — test observation for the
    /// isolation installer in the route lifecycle suite.
    func currentStorageDirectory() -> URL {
        baseDirectory
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
        return Contents(
            entries: state.entries, droppedLines: state.droppedLines, evictedNanos: state.evictedNanos)
    }

    /// Current-boot journal entries for the container, in stream order.
    /// Loads (and salvage-rewrites) the persisted file on first use.
    func entries(nativeId: String) -> [Entry] {
        contents(nativeId: nativeId).entries
    }

    /// Converts a boot's `startedDate` to the identity persisted in the
    /// version-4 header. Nil (Apple did not report a start date) stays nil:
    /// an unidentified boot never forces a mismatch reset.
    static func bootIdNano(from startedAt: Date?) -> UInt64? {
        guard let startedAt else { return nil }
        let seconds = startedAt.timeIntervalSince1970
        guard seconds > 0 else { return nil }
        return UInt64(seconds * 1_000_000_000)
    }

    /// Resets the journal for a new container boot: Apple truncates the log
    /// file at every boot, so previous-boot entries can never align with the
    /// new stream and are dropped instead of risking false timestamp matches.
    /// Epoch-gated inside the actor: a superseded (older-epoch) follower can
    /// never wipe its replacement's entries.
    ///
    /// `droppedLines` accounts stream lines that were already consumed
    /// against the wiped journal (covered/evicted by it) but are not
    /// retained in the replacement: a later scan from byte zero skips
    /// exactly that prefix, so the retained suffix still aligns. The stale
    /// journal's self-heal path uses this so a mid-read reset does not
    /// orphan the lines read before the mismatch was detected.
    ///
    /// `bootIdNano` records which boot the replacement journal belongs to
    /// (see the version-4 header); nil leaves the boot unidentified.
    func beginBoot(nativeId: String, epoch: UInt64, droppedLines: Int = 0, bootIdNano: UInt64? = nil) {
        activate(nativeId: nativeId, epoch: epoch, reset: true, droppedLines: droppedLines, bootIdNano: bootIdNano)
    }

    /// Adopts the persisted journal for the container's CURRENT boot — the
    /// daemon-restart/resume path. Registers `epoch` as the journal's writer
    /// without dropping entries, so a resumed follower keeps aligning against
    /// what the previous process recorded.
    ///
    /// `bootIdNano` (the container's CURRENT `startedDate`) is compared with
    /// the persisted boot identity: a container that REBOOTED while no
    /// follower was armed (podmd was down) has a different identity, and its
    /// new boot's log can never align with the old journal — reset it like a
    /// fresh boot instead of lending the old timestamps to identical startup
    /// lines. A nil on either side cannot prove a mismatch and adopts.
    func resumeBoot(nativeId: String, epoch: UInt64, bootIdNano: UInt64? = nil) {
        activate(nativeId: nativeId, epoch: epoch, reset: false, bootIdNano: bootIdNano)
    }

    /// Fills in the boot identity of a journal whose writer is ALREADY
    /// active, without touching entries, alignment state or the writer
    /// epoch. The registry's redundant-arm path uses this: the original arm
    /// happened before Apple reported a start date (the attach paths arm
    /// immediately after bootstrap), and the lifecycle request that follows
    /// (`/start`) carries the real `startedDate`. Without persisting it, the
    /// journal stays unidentified — a container that later reboots while
    /// podmd is down can never prove the mismatch, and the old journal
    /// lends its timestamps to identical startup lines.
    ///
    /// Only an UNIDENTIFIED journal adopts here: a recorded identity that
    /// matches is a no-op, and one that differs is left alone (proving a
    /// mismatch is the arm/activation paths' job, not a redundant arm's).
    func adoptBootIdentity(nativeId: String, epoch: UInt64, bootIdNano: UInt64?) {
        guard let bootIdNano else { return }
        guard epoch >= writerEpochs[nativeId] ?? 0 else { return }
        loadIfNeeded(nativeId)
        persistLearnedIdentity(nativeId: nativeId, bootIdNano: bootIdNano)
    }

    /// Writes a newly learned boot identity into the persisted header — the
    /// shared tail of both adoption paths (`resumeBoot` and the registry's
    /// redundant arm). The plain append path in `persist` never rewrites the
    /// header, so an identity that only lands in `states` dies with the
    /// process: after the next daemon restart `loadIfNeeded` reads nil
    /// again, adopts the journal, and cannot detect a reboot that happened
    /// while podmd was down. The rewrite swaps the file, so the cached
    /// writer handle must go with it — it would keep writing at its stale
    /// offset into the old inode (same rule as `persist` on a trim).
    private func persistLearnedIdentity(nativeId: String, bootIdNano: UInt64) {
        guard var state = states[nativeId], state.bootIdNano == nil else { return }
        state.bootIdNano = bootIdNano
        states[nativeId] = state
        let url = fileURL(nativeId)
        guard !state.entries.isEmpty || FileManager.default.fileExists(atPath: url.path) else { return }
        try? state.fileHandle?.close()
        states[nativeId]?.fileHandle = nil
        rewriteFile(
            url, entries: state.entries, droppedLines: state.droppedLines, evictedNanos: state.evictedNanos,
            bootIdNano: bootIdNano)
    }

    private func activate(nativeId: String, epoch: UInt64, reset: Bool, droppedLines: Int = 0, bootIdNano: UInt64? = nil) {
        guard epoch > tombstoneEpochs[nativeId] ?? 0 else { return }
        guard epoch >= writerEpochs[nativeId] ?? 0 else { return }
        if !reset {
            loadIfNeeded(nativeId)
            guard let persisted = states[nativeId]?.bootIdNano, let bootIdNano, persisted != bootIdNano else {
                writerEpochs[nativeId] = epoch
                // Adopting the current boot also adopts its identity when the
                // caller knows it — a later resume can then detect a reboot.
                // The identity must reach the FILE, not just memory (see
                // persistLearnedIdentity): an in-memory-only adoption is
                // forgotten on the next daemon restart, which is exactly
                // when the reboot detection needs it.
                if let bootIdNano { persistLearnedIdentity(nativeId: nativeId, bootIdNano: bootIdNano) }
                return
            }
        }
        writerEpochs[nativeId] = epoch
        try? states[nativeId]?.fileHandle?.close()
        var state = states[nativeId] ?? State()
        state.entries = []
        state.totalFramedBytes = 0
        state.droppedLines = droppedLines
        state.evictedNanos = []
        state.bootIdNano = bootIdNano
        // The closed handle must NOT survive into the new State: `persist`
        // would skip reopening and write through the dead descriptor, so
        // the new boot's entries would live only in memory until a cap
        // rewrite happened to reopen the file.
        state.fileHandle = nil
        states[nativeId] = state
        do {
            try FileManager.default.removeItem(at: fileURL(nativeId))
        } catch {
            // A missing file is the common case (first boot of this container).
        }
        if droppedLines > 0 {
            // Persist the accounted prefix: a reload must keep the count, or
            // the retained suffix stops aligning with a scan from byte zero.
            // The replacement journal holds no evicted stamps — the stale
            // boot's lines (and their times) are gone for good.
            rewriteFile(
                fileURL(nativeId), entries: [], droppedLines: droppedLines, evictedNanos: [],
                bootIdNano: bootIdNano)
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
        // Take the state OUT of the dictionary while mutating it: copying the
        // value out leaves `states` holding the original entries array, so
        // the append below would trigger copy-on-write of the ENTIRE retained
        // journal on every batch — including each small polling flush —
        // making the work grow with the historical entry count instead of
        // the new batch. This method has no suspension points, so the gap in
        // the dictionary is invisible to other calls.
        var state = states.removeValue(forKey: nativeId) ?? State()
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
                // Retain the evicted lines' arrival stamps (drop-oldest, with
                // hysteresis): a windowed reader uses them to judge evicted
                // lines by their write time rather than the read time.
                state.evictedNanos.append(
                    contentsOf: state.entries[0..<evicted].map(\.unixNano))
                if state.evictedNanos.count > Self.maxEvictedNanos {
                    state.evictedNanos.removeFirst(
                        state.evictedNanos.count - Self.maxEvictedNanos / 2)
                }
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

    /// Closes the cached writer handle for a container whose follower has
    /// FINISHED — the follower closes its Apple log handle at exit, but the
    /// journal's writer would otherwise stay open until the next reset,
    /// trim or container deletion, accumulating one descriptor per stopped
    /// container and exhausting the daemon's fd limit. Epoch-gated inside
    /// the actor: an old follower cannot close its replacement's handle.
    /// The entries (and the file) stay for later windowed reads; a later
    /// append reopens the handle on demand.
    func closeWriter(nativeId: String, epoch: UInt64) {
        guard writerEpochs[nativeId] == epoch else { return }
        try? states[nativeId]?.fileHandle?.close()
        states[nativeId]?.fileHandle = nil
    }

    /// Whether the cached writer handle for `nativeId` is open — test
    /// observation for the follower-exit release path above.
    func writerIsOpen(nativeId: String) -> Bool {
        loadIfNeeded(nativeId)
        return states[nativeId]?.fileHandle != nil
    }

    // MARK: - Persistence

    private func loadIfNeeded(_ nativeId: String) {
        guard states[nativeId] == nil else { return }
        var state = State()
        let url = fileURL(nativeId)
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            let (entries, droppedLines, evictedNanos, bootIdNano, salvaged) = Self.parse(data)
            state.entries = entries
            state.droppedLines = droppedLines
            state.evictedNanos = evictedNanos
            state.bootIdNano = bootIdNano
            state.totalFramedBytes = entries.reduce(0) { $0 + $1.framedByteCount }
            if salvaged {
                // A crash mid-write left a partial trailing entry; keep the
                // parseable prefix so appends land on a valid boundary again.
                log.warning("log journal for \(nativeId) had a partial trailing entry — salvaged \(entries.count) entries")
                rewriteFile(
                    url, entries: entries, droppedLines: droppedLines, evictedNanos: evictedNanos,
                    bootIdNano: bootIdNano)
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
            rewriteFile(
                url, entries: state.entries, droppedLines: state.droppedLines, evictedNanos: state.evictedNanos,
                bootIdNano: state.bootIdNano)
            return
        }
        if state.fileHandle == nil {
            do {
                try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    // The in-memory state's evicted count and stamps must land
                    // in the recreated header too (the file vanished under a
                    // live state), or a reload would lose the prefix metadata.
                    guard
                        FileManager.default.createFile(
                            atPath: url.path,
                            contents: Self.headerData(
                                droppedLines: state.droppedLines, evictedNanos: state.evictedNanos,
                                bootIdNano: state.bootIdNano))
                    else {
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

    private func rewriteFile(
        _ url: URL, entries: [Entry], droppedLines: Int, evictedNanos: [UInt64], bootIdNano: UInt64? = nil
    ) {
        // The first append of a container can already exceed the cap (a huge
        // backlog batch), landing here before the plain append path has ever
        // created the journal directory — createFile does not create parents.
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        var contents = Self.headerData(droppedLines: droppedLines, evictedNanos: evictedNanos, bootIdNano: bootIdNano)
        for entry in entries { contents.append(Self.encode(entry)) }
        if !FileManager.default.createFile(atPath: url.path, contents: contents, attributes: nil) {
            log.error("could not rewrite log journal file at \(url.path)")
        }
    }

    // MARK: - Framing

    private static func headerData(
        droppedLines: Int = 0, evictedNanos: [UInt64] = [], bootIdNano: UInt64? = nil
    ) -> Data {
        var data = magic
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        // Clamping, not trapping: a negative count can only come from a
        // caller bug, and a trap here would take the daemon down while
        // writing a header.
        withUnsafeBytes(of: UInt64(clamping: max(0, droppedLines)).littleEndian) {
            data.append(contentsOf: $0)
        }
        withUnsafeBytes(of: UInt32(evictedNanos.count).littleEndian) { data.append(contentsOf: $0) }
        for nano in evictedNanos {
            withUnsafeBytes(of: nano.littleEndian) { data.append(contentsOf: $0) }
        }
        // Version 4: the boot identity (see the header doc above). A missing
        // identity costs one flag byte; a present one nine.
        if let bootIdNano {
            data.append(1)
            withUnsafeBytes(of: bootIdNano.littleEndian) { data.append(contentsOf: $0) }
        } else {
            data.append(0)
        }
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
    /// prefix's line count (0 for version-1 files), the evicted prefix's
    /// retained arrival stamps (empty before version 3), the persisted boot
    /// identity (nil before version 4), and whether the file had to be
    /// salvaged (bad magic/version, or a truncated or oversized trailing
    /// record).
    static func parse(_ data: Data) -> (
        entries: [Entry], droppedLines: Int, evictedNanos: [UInt64], bootIdNano: UInt64?, salvaged: Bool
    ) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return ([], 0, [], nil, true) }
        guard Data(bytes[0..<4]) == magic else { return ([], 0, [], nil, true) }
        let version = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        var droppedLines = 0
        var evictedNanos: [UInt64] = []
        var bootIdNano: UInt64? = nil
        var offset = 8
        if version >= 2 {
            // Version 2+ carries the evicted-prefix line count; a short header
            // is a truncated file, salvaged to nothing.
            guard bytes.count >= 16 else { return ([], 0, [], nil, true) }
            // Decode as UInt64 and reject counts that cannot be a nonnegative
            // Int: decoding straight into Int turns a damaged high bit into
            // a NEGATIVE count (or traps on the shift), and a subsequent
            // salvage rewrite would trap in UInt64(droppedLines) below —
            // crashing the daemon instead of recovering the journal.
            var dropped: UInt64 = 0
            for i in 0..<8 { dropped |= UInt64(bytes[8 + i]) << (8 * UInt64(i)) }
            guard let count = Int(exactly: dropped) else { return ([], 0, [], nil, true) }
            droppedLines = count
            offset = 16
        } else {
            guard version == 1 else { return ([], 0, [], nil, true) }
        }
        if version >= 3 {
            // Version 3 appends the evicted prefix's retained arrival stamps:
            // a u32 count followed by that many u64 nanosecond stamps. A
            // count running past the file is a truncated header — salvaged
            // to nothing, like a truncated entry (the stamps are a suffix
            // window; losing them only degrades evicted lines to the
            // read-time fallback).
            guard bytes.count >= offset + 4 else { return ([], 0, [], nil, true) }
            let stampCount =
                Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
                | Int(bytes[offset + 3]) << 24
            offset += 4
            let stampsEnd = offset + stampCount * 8
            guard stampsEnd <= bytes.count else { return ([], 0, [], nil, true) }
            for _ in 0..<stampCount {
                var nano: UInt64 = 0
                for i in 0..<8 {
                    nano |= UInt64(bytes[offset + i]) << (8 * i)
                }
                evictedNanos.append(nano)
                offset += 8
            }
        }
        if version >= 4 {
            // Version 4 appends the boot identity: a presence flag followed,
            // when set, by the boot's startedDate in unix nanoseconds. A
            // truncated identity is a truncated header — salvaged to nothing
            // like the sections above (losing it only degrades reboot
            // detection to the alignment-based fallback).
            guard bytes.count >= offset + 1 else { return ([], 0, [], nil, true) }
            if bytes[offset] != 0 {
                guard bytes.count >= offset + 9 else { return ([], 0, [], nil, true) }
                var bootId: UInt64 = 0
                for i in 0..<8 { bootId |= UInt64(bytes[offset + 1 + i]) << (8 * i) }
                bootIdNano = bootId
            }
            offset += bytes[offset] != 0 ? 9 : 1
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
                return (entries, droppedLines, evictedNanos, bootIdNano, true)
            }
            entries.append(
                Entry(unixNano: nano, streamType: streamType, bytes: Data(bytes[payloadStart..<(payloadStart + payloadByteCount)])))
            offset = payloadStart + payloadByteCount
        }
        return (entries, droppedLines, evictedNanos, bootIdNano, offset != bytes.count)
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
    /// retained suffix still lines up with a stream read from byte zero, and
    /// for oversized lines, which the journal records as gap markers (empty
    /// payload) consumed via `consumeGapMarker` rather than compared. The
    /// first mismatch (journal stale relative to the stream, a superseded
    /// boot, corruption) disables matching for the rest of the scan instead
    /// of returning wrong times for coincidentally identical lines.
    struct Alignment {
        private let entries: [Entry]
        private let droppedLines: Int
        /// Arrival stamps retained for the most recently evicted lines — a
        /// SUFFIX of the evicted prefix (see `maxEvictedNanos`), so the stamp
        /// for evicted ordinal `i` is `evictedNanos[i - base]` with
        /// `base = droppedLines - evictedNanos.count`.
        private let evictedNanos: [UInt64]
        private var index = 0
        private var skipped = 0
        private var usable = true

        init(entries: [Entry], droppedLines: Int = 0, evictedNanos: [UInt64] = []) {
            self.entries = entries
            self.droppedLines = droppedLines
            self.evictedNanos = evictedNanos
        }

        /// How one stream line relates to the journal.
        enum Coverage {
            /// Journal-recorded write time for the line.
            case covered(UInt64)
            /// The line falls in the evicted prefix: it was already
            /// accounted for (a follower must not re-journal it), and its
            /// write time is the retained evicted stamp when the journal
            /// still holds one — nil only when no stamps are recoverable.
            /// `isUpperBound` is true for evictions OLDER than the retained
            /// stamp window: the reported stamp is the oldest retained one,
            /// so the line was written at or before it — window consumers
            /// must not treat it as the line's exact write time.
            case evicted(unixNano: UInt64?, isUpperBound: Bool)
            /// Not covered by the journal (follower behind, or alignment
            /// failed) — a follower records it, a reader falls back to read
            /// time.
            case fresh

            /// The journal-recorded time, when this line is covered by one.
            var recordedNano: UInt64? {
                switch self {
                case .covered(let unixNano): return unixNano
                case .evicted(let unixNano, _): return unixNano
                case .fresh: return nil
                }
            }

            /// The journal-recorded time including whether it is exact: nil
            /// when the line is not covered by one.
            var recordedTime: RecordedTime? {
                switch self {
                case .covered(let unixNano): return RecordedTime(unixNano: unixNano, isUpperBound: false)
                case .evicted(let unixNano, let isUpperBound):
                    return unixNano.map { RecordedTime(unixNano: $0, isUpperBound: isUpperBound) }
                case .fresh: return nil
                }
            }
        }

        /// A journal-recovered write time for one line: exact when the
        /// journal retained the line (or its evicted stamp / gap marker), or
        /// only an UPPER BOUND when the line predates the retained stamp
        /// window — the line was written at or before `unixNano`, and a
        /// window consumer cannot prove more than that.
        struct RecordedTime: Equatable {
            let unixNano: UInt64
            let isUpperBound: Bool
        }

        mutating func classify(_ line: Data) -> Coverage {
            guard usable else { return .fresh }
            if skipped < droppedLines {
                let time = evictedTime(at: skipped)
                skipped += 1
                return .evicted(unixNano: time?.unixNano, isUpperBound: time?.isUpperBound ?? false)
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

        /// The retained stamp for evicted ordinal `ordinal` (exact), the
        /// oldest retained stamp (an UPPER BOUND on the write time) for
        /// evictions older than the retained window, or nil when no stamps
        /// are held.
        private func evictedTime(at ordinal: Int) -> RecordedTime? {
            guard !evictedNanos.isEmpty else { return nil }
            let base = max(droppedLines - evictedNanos.count, 0)
            if ordinal < base { return RecordedTime(unixNano: evictedNanos.first!, isUpperBound: true) }
            let index = ordinal - base
            if index < evictedNanos.count {
                return RecordedTime(unixNano: evictedNanos[index], isUpperBound: false)
            }
            return RecordedTime(unixNano: evictedNanos.last!, isUpperBound: false)
        }

        /// The journal-recorded time for `line`, or nil when the line is not
        /// covered by the journal (follower behind, or alignment has failed).
        /// Evicted lines report their retained evicted stamp — treating them
        /// as newly written (read time) let a recent `--since` include old
        /// output and a past `--until` exclude in-window output.
        mutating func timestamp(for line: Data) -> UInt64? {
            recordedTime(for: line)?.unixNano
        }

        /// Like `timestamp(for:)` but also reports whether the time is exact
        /// or only an upper bound (see `RecordedTime`): the windowed readers
        /// need that distinction — an evicted line past the retained stamp
        /// window inherits the oldest retained stamp, and treating that
        /// bound as exact wrongly excluded lines from a past `--until`.
        mutating func recordedTime(for line: Data) -> RecordedTime? {
            classify(line).recordedTime
        }

        /// Consumes the gap marker recording one oversized stream line the
        /// journal skipped without retaining. Readers call this INSTEAD of
        /// `classify`/`timestamp` for a line beyond the retention bound: the
        /// marker holds the line's ordinal (and its discard time) without
        /// the payload, so the entries behind it stay aligned. Without the
        /// consumption, the oversized stream line would be compared against
        /// the NEXT retained entry, fail, and disable timestamp recovery for
        /// every later line.
        ///
        /// The oversized line may instead sit in the EVICTED prefix — the
        /// cap evicted its marker along with it. That ordinal is consumed
        /// here too (classify never sees this line), or the next retained
        /// line would classify as evicted and lose its recorded timestamp,
        /// and a resumed follower would append a duplicate marker for a
        /// line the evicted prefix already accounts. Returns `.covered`
        /// with the marker's recorded time, `.evicted` when the line was in
        /// the evicted prefix (already accounted, with its retained evicted
        /// stamp when one is held), or `.fresh` when no marker is at the
        /// head (the journal does not cover this line — follower behind, or
        /// a pre-marker journal).
        ///
        /// A retained ORDINARY entry at the head is an alignment mismatch —
        /// the journal expects the oversized line's marker but holds a real
        /// line instead — and disables matching, exactly like a `classify`
        /// mismatch: a stale journal whose retained line sits right behind
        /// the stream's oversized line would otherwise stay usable and lend
        /// its old timestamps to the new boot's lines. Only exhaustion (no
        /// entry at all — the follower is simply behind the stream) leaves
        /// the alignment usable.
        mutating func consumeGapMarker() -> Coverage {
            guard usable else { return .fresh }
            if skipped < droppedLines {
                let time = evictedTime(at: skipped)
                skipped += 1
                return .evicted(unixNano: time?.unixNano, isUpperBound: time?.isUpperBound ?? false)
            }
            guard index < entries.count else { return .fresh }
            guard entries[index].isGapMarker else {
                usable = false
                return .fresh
            }
            let unixNano = entries[index].unixNano
            index += 1
            return .covered(unixNano)
        }

        /// Whether a content mismatch has disabled matching — the journal is
        /// provably not from this boot. The follower uses this to self-heal
        /// (reset the stale journal) instead of restamping history.
        var failed: Bool { !usable }
    }
}
