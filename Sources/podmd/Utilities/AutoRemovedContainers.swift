import Foundation

/// Tombstones for containers Apple Container has already reaped on `--rm` exit.
///
/// `docker run --rm` is a client RACE by design: the CLI creates, attaches, then
/// issues `/start` and `/wait` — while the attached container may exit and be
/// reaped (Apple Container's own `autoRemove`) before those late calls land. The
/// daemon then answered "No such container" and the CLI exited **125 for a run
/// that actually succeeded** (output printed, exit code lost) — every
/// `docker run --rm ...` script saw failure.
///
/// The race is milliseconds wide (exit → reap → the CLI's next request), and
/// podm records the real exit code at exit time, before the reap is
/// observable, so a short-lived tombstone lets the late `/start` and `/wait`
/// answer with what really happened instead of 404.
///
/// Only containers podm itself watched exit through the `--rm` cleanup funnel
/// are recorded — a container removed by `docker rm` never gets a tombstone, so
/// `docker wait <removed-id>` still 404s as Docker does.
actor AutoRemovedContainers {
    static let shared = AutoRemovedContainers()

    private struct Entry {
        let code: Int32
        let recordedAt: ContinuousClock.Instant
    }

    /// How long a tombstone answers late calls. The CLI's follow-up requests
    /// arrive within milliseconds; the generous window also covers a loaded
    /// runner where the attach stream's flush grace and the exit-code wait's
    /// retries stretch the gap between exit and the last call.
    private let ttl: Duration
    /// How long a route waits for a tombstone to appear on a missing container
    /// before it answers 404. The tombstone is written after the exit observer
    /// records the code and waits out the output-flush grace, so a late
    /// `/start` can beat it by a fraction of a second.
    private let defaultWait: Duration

    private var entries: [String: Entry] = [:]

    init(ttl: Duration = .seconds(120), defaultWait: Duration = .seconds(5)) {
        self.ttl = ttl
        self.defaultWait = defaultWait
    }

    private func prune(now: ContinuousClock.Instant = .now) {
        entries = entries.filter { now - $0.value.recordedAt < ttl }
    }

    /// Records the exit of a `--rm` container under both ids it can be called
    /// by (the Docker 64-hex id the CLI was handed at create, and Apple's
    /// native id).
    func record(hexId: String, nativeId: String, code: Int32) {
        let now = ContinuousClock.Instant.now
        prune(now: now)
        let entry = Entry(code: code, recordedAt: now)
        entries[hexId] = entry
        entries[nativeId] = entry
    }

    /// The recorded exit code, while the tombstone is still fresh.
    func exitCode(for id: String) -> Int32? {
        prune()
        return entries[id]?.code
    }

    /// The recorded exit code, waiting briefly for it to appear.
    ///
    /// A late `/start` can beat the exit observer: the container is already
    /// gone (so the route's preflight sees nothing) but the tombstone has not
    /// been written yet — the observer records the code, then waits out the
    /// output-flush grace before the `--rm` cleanup funnel runs. Poll that
    /// short window instead of 404ing a run that is about to be accounted for.
    func waitForExitCode(
        for id: String,
        timeout: Duration? = nil,
        pollInterval: Duration = .milliseconds(50)
    ) async -> Int32? {
        let deadline = ContinuousClock.Instant.now + (timeout ?? defaultWait)
        while true {
            if let code = exitCode(for: id) {
                return code
            }
            guard ContinuousClock.Instant.now < deadline else { return nil }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Test/reset seam.
    func removeAll() {
        entries.removeAll()
    }
}
