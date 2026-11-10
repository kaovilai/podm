import ContainerAPIClient
import Foundation
import Logging

/// Background journal-writer per running container: the counterpart of
/// `ContainerStartRoute.observeExit` for logs. It does what the logs route
/// does today (read the Apple log handle, split on newline) but records each
/// completed line into `ContainerLogJournal` with its ARRIVAL timestamp, and
/// stops once the container is no longer running.
///
/// Arming happens in `ContainerStartRoute.armRestartObserver` — the single
/// choke point shared by `/start`, `/restart`, and the internal
/// restart-policy restart — because every container lifecycle that produces
/// output goes through it (a foreground `docker run` still receives a `/start`
/// after the attach route bootstraps the container). Followers are
/// epoch-guarded: each arm bumps a per-container epoch, and both
/// `beginBoot`/`append` journal writes and the follower loop itself check it,
/// so a superseded follower (redundant `/start`, restart racing a slow poll)
/// can never interleave entries into a newer boot's journal.
actor ContainerLogFollowerRegistry {
    static let shared = ContainerLogFollowerRegistry()

    private var epochs: [String: UInt64] = [:]
    private var tasks: [String: (task: Task<Void, Never>, epoch: UInt64)] = [:]
    private var nextEpoch: UInt64 = 0

    /// True while `epoch` is still the current generation for `nativeId`.
    func isCurrent(nativeId: String, epoch: UInt64) -> Bool {
        epochs[nativeId] == epoch
    }

    /// Whether a follower task is registered for `nativeId` (it may still be
    /// winding down after its container stopped).
    func isArmed(nativeId: String) -> Bool {
        tasks[nativeId] != nil
    }

    /// Arms a journal follower for the container's current boot.
    ///
    /// - Parameter freshBoot: true when the container just (re)started — Apple
    ///   truncates the log file at every boot, so the journal must reset and a
    ///   new follower must take over even if an old one has not noticed the
    ///   restart yet. False for a plain `/start`, where a live current-epoch
    ///   follower means the container was already running under this boot and
    ///   must not be disturbed.
    func arm(
        nativeId: String,
        client: ClientContainerProtocol,
        logger: Logger,
        freshBoot: Bool,
        journal: ContainerLogJournal = .shared,
        openLogStream: (@Sendable (String) async throws -> FileHandle)? = nil
    ) {
        if !freshBoot,
            let existing = tasks[nativeId],
            existing.epoch == epochs[nativeId],
            !existing.task.isCancelled
        {
            return  // a current-boot follower is already watching this container
        }
        nextEpoch += 1
        let epoch = nextEpoch
        epochs[nativeId] = epoch
        tasks[nativeId]?.task.cancel()
        let task = Task.detached {
            await ContainerLogFollower.follow(
                nativeId: nativeId, epoch: epoch, client: client, logger: logger,
                journal: journal, openLogStream: openLogStream)
        }
        tasks[nativeId] = (task, epoch)
        Task.detached {
            _ = await task.value
            await self.reap(nativeId: nativeId, epoch: epoch)
        }
    }

    /// Stops the follower (if any) for a container about to be removed.
    func disarm(nativeId: String) {
        epochs[nativeId] = nil
        tasks[nativeId]?.task.cancel()
        tasks[nativeId] = nil
    }

    private func reap(nativeId: String, epoch: UInt64) {
        if let existing = tasks[nativeId], existing.epoch == epoch {
            tasks[nativeId] = nil
        }
    }
}

enum ContainerLogFollower {
    /// How long the follower sleeps between polls of the Apple log handle —
    /// the same cadence the logs route's follow loop uses.
    static let pollIntervalNs: UInt64 = 150_000_000

    /// Tears a container's log-following state down along with it — called
    /// from the delete and --rm auto-remove cleanup paths.
    static func teardown(nativeId: String) async {
        await ContainerLogFollowerRegistry.shared.disarm(nativeId: nativeId)
        await ContainerLogJournal.shared.remove(nativeId: nativeId)
    }

    /// Mirrors the container's Apple log stream into the journal until the
    /// container stops. Re-opening the stream per arm (rather than sharing a
    /// handle with the route) keeps ownership simple: each follower reads from
    /// byte 0 and skips lines the journal already covers by content
    /// alignment, which also self-heals after cap evictions.
    ///
    /// `journal`, `openLogStream` and `isCurrentEpoch` are seams for tests:
    /// production runs use the shared journal, Apple's log stream, and the
    /// follower registry's epoch check respectively.
    static func follow(
        nativeId: String,
        epoch: UInt64,
        client: ClientContainerProtocol,
        logger: Logger,
        journal: ContainerLogJournal = .shared,
        openLogStream: (@Sendable (String) async throws -> FileHandle)? = nil,
        isCurrentEpoch: (@Sendable () async -> Bool)? = nil
    ) async {
        let isCurrent: @Sendable () async -> Bool =
            isCurrentEpoch ?? { await ContainerLogFollowerRegistry.shared.isCurrent(nativeId: nativeId, epoch: epoch) }

        // Reset the journal for this boot. Gated on the epoch so a follower
        // superseded before it starts (concurrent re-arm) wipes nothing.
        await journal.beginBoot(nativeId: nativeId, epoch: epoch, isCurrentEpoch: isCurrent)
        guard await isCurrent() else { return }

        let handle: FileHandle
        do {
            if let openLogStream {
                handle = try await openLogStream(nativeId)
            } else {
                guard let appleHandle = try await ContainerClient().logs(id: nativeId).first else { return }
                handle = appleHandle
            }
        } catch {
            logger.debug("log follower: could not open Apple log stream for \(nativeId): \(error)")
            return
        }
        defer { try? handle.close() }

        var alignment = ContainerLogJournal.Alignment(entries: await journal.entries(nativeId: nativeId))
        var pending = Data()

        /// Reads everything currently available, journaling each complete line
        /// (skipping lines already covered by the journal) with the arrival
        /// time of this pass. Appends are awaited so journal order always
        /// matches stream order. Returns whether any bytes were read.
        func readAvailable() async -> Bool {
            var gotData = false
            var newLines: [Data] = []
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                gotData = true
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    newLines.append(pending.subdata(in: pending.startIndex..<pending.index(after: newline)))
                    pending = pending.subdata(in: pending.index(after: newline)..<pending.endIndex)
                }
            }
            guard !newLines.isEmpty else { return gotData }
            let arrivalNano = ContainerLogJournal.currentUnixNano()
            var fresh: [ContainerLogJournal.Entry] = []
            for line in newLines where alignment.timestamp(for: line) == nil {
                fresh.append(
                    ContainerLogJournal.Entry(
                        unixNano: arrivalNano,
                        streamType: DockerStreamFrame.StreamType.stdout.rawValue,
                        bytes: line
                    ))
            }
            if !fresh.isEmpty {
                await journal.append(nativeId: nativeId, epoch: epoch, fresh, isCurrentEpoch: isCurrent)
            }
            return gotData
        }

        while !Task.isCancelled {
            guard await isCurrent() else { return }
            let gotData = await readAvailable()
            if gotData { continue }
            let current = try? await client.getContainer(id: nativeId)
            guard await isCurrent() else { return }
            if current == nil || current?.status != .running {
                // Give the exit path the same flush grace the process exit
                // monitor grants pipe readers, journal the final writes, stop.
                try? await Task.sleep(nanoseconds: ContainerProcessExitMonitor.outputFlushGraceNs)
                guard await isCurrent() else { return }
                _ = await readAvailable()
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
    }
}
