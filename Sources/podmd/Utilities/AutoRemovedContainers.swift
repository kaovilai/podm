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

    /// Records the exit of a `--rm` container under the Docker 64-hex id the
    /// CLI was handed at create.
    ///
    /// Deliberately NOT keyed by Apple's native id: native ids are reusable
    /// NAMES (a create without `--name` passes the container name through), so
    /// a tombstone under a name would answer for a later container reusing it.
    /// The hex id embeds the creation date and is instance-unique.
    func record(hexId: String, code: Int32) {
        let now: ContinuousClock.Instant = .now
        prune(now: now)
        entries[hexId] = Entry(code: code, recordedAt: now)
    }

    /// The recorded exit code, while the tombstone is still fresh.
    ///
    /// Accepts a case-insensitive hex-id prefix, matching how `/containers/{id}`
    /// resolution treats ids elsewhere (a client may hand back a short id from
    /// `docker ps`, or spell it in upper case). An ambiguous prefix resolves to
    /// nothing, like the container routes.
    func exitCode(for id: String) -> Int32? {
        prune()
        if let exact = entries[id] { return exact.code }
        if let exact = entries[id.lowercased()] { return exact.code }
        guard Self.isHexIdPrefix(id) else { return nil }
        let needle = id.lowercased()
        let matches = entries.filter { $0.key.hasPrefix(needle) && Self.isHexId($0.key) }
        guard matches.count == 1 else { return nil }
        return matches.first?.value.code
    }

    /// The recorded exit code, waiting briefly for it to appear.
    ///
    /// A late `/start` can beat the exit observer: the container is already
    /// gone (so the route's preflight sees nothing) but the tombstone has not
    /// been written yet — the observer records the code, then waits out the
    /// output-flush grace before the `--rm` cleanup funnel runs. Poll that
    /// short window instead of 404ing a run that is about to be accounted for.
    ///
    /// Stops as soon as the caller is cancelled (the client disconnected, the
    /// server is shutting down): a cancelled `Task.sleep` returns immediately,
    /// and continuing the loop would busy-spin until the deadline.
    func waitForExitCode(
        for id: String,
        timeout: Duration? = nil,
        pollInterval: Duration = .milliseconds(50)
    ) async -> Int32? {
        let deadline = ContinuousClock.Instant.now + (timeout ?? defaultWait)
        while true {
            if let code = exitCode(for: id) { return code }
            guard !Task.isCancelled, ContinuousClock.Instant.now < deadline else { return nil }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                // Cancelled — the caller will never answer; stop polling.
                return nil
            }
        }
    }

    private static func isHexId(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func isHexIdPrefix(_ value: String) -> Bool {
        value.count >= 6 && value.allSatisfy { $0.isHexDigit }
    }

    /// Test/reset seam.
    func removeAll() {
        entries.removeAll()
    }
}
