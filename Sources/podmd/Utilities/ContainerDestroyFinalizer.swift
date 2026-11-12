import Foundation

/// Exactly-once gate for a container's destroy-time cleanup, keyed by the
/// container's instance identity (its 64-char hex id). Three paths can reach
/// cleanup for the same deleted container:
///
/// - the DELETE route's synchronous success,
/// - the DELETE route's 404-after-vanish fallback (a client retry after
///   another request — or a late wedge-recovery success — removed it),
/// - the wedge recovery's late-success callback (the apiserver answered
///   after the request had already returned the wedged error).
///
/// Only the first runs the body, so exactly one destroy event fires and the
/// store teardowns happen once. A call that arrives while the body is
/// already running WAITS for it — the in-flight call owns the cleanup, and
/// answering the duplicate before the body finished would let its caller
/// (e.g. a DELETE 404 fallback) respond while the rename override still
/// exists, so a create of the same name in that window gets a spurious 409.
///
/// A completed finalization whose ownership lookup went unanswered keeps a
/// per-hex "native cleanup unresolved" marker (hex id → native id): the
/// hex-keyed cleanup ran, but the native-keyed teardown (log journal,
/// restart counter) was skipped because ownership could not be checked.
/// The marker outlives the `completed` entry's exactly-once gate — without
/// it, that gate would make the skip permanent, so a later DELETE 404
/// fallback could never re-attempt the native-keyed cleanup even after the
/// apiserver recovers. The marker is cleared when a re-check resolves
/// ownership (see `ContainerDestroyCleanup.retryUnresolvedNativeCleanup`)
/// and expires with the same TTL as `completed`.
actor ContainerDestroyFinalizer {
    static let shared = ContainerDestroyFinalizer()

    /// How long a completed finalization is remembered, so a delayed
    /// late-success callback (or a client retry) is recognized as a
    /// duplicate rather than running the cleanup a second time.
    private static let memoryTTL: TimeInterval = 3600
    private static let maxMemory = 4096

    private var inFlight: [String: Task<Void, Never>] = [:]
    private var completed: [String: Date] = [:]
    private var unresolvedNativeCleanup: [String: (nativeId: String, markedAt: Date)] = [:]

    /// Records that `hexId`'s finalization could not determine whether a
    /// same-name replacement owns the native-keyed state, so the
    /// native-keyed teardown is still pending.
    func markNativeCleanupUnresolved(hexId: String, nativeId: String) {
        unresolvedNativeCleanup[hexId] = (nativeId, Date())
    }

    /// The native id whose teardown is still pending for `hexId`, if any.
    func unresolvedNativeId(hexId: String) -> String? {
        unresolvedNativeCleanup[hexId]?.nativeId
    }

    /// Drops the pending marker — ownership was resolved (the teardown ran,
    /// or a live replacement proved the skip correct).
    func clearNativeCleanupUnresolved(hexId: String) {
        unresolvedNativeCleanup.removeValue(forKey: hexId)
    }

    /// Runs `body` for `key` unless this finalizer already ran (or is
    /// running) for it. The body is instance-scoped by construction: it is
    /// built from the deleted container's captured snapshot/hex id and must
    /// never touch a same-name replacement.
    func finalizeOnce(key: String, _ body: @escaping @Sendable () async -> Void) async {
        if completed[key] != nil { return }
        if let running = inFlight[key] {
            await running.value
            return
        }
        let task = Task<Void, Never> { await body() }
        inFlight[key] = task
        await task.value
        inFlight.removeValue(forKey: key)
        prune()
        completed[key] = Date()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.memoryTTL)
        completed = completed.filter { $0.value > cutoff }
        unresolvedNativeCleanup = unresolvedNativeCleanup.filter { $0.value.markedAt > cutoff }
        if completed.count > Self.maxMemory {
            let newest = completed.sorted { $0.value > $1.value }.prefix(Self.maxMemory)
            completed = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }
}
