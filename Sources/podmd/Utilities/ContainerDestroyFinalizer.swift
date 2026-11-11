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
/// already running returns immediately — the in-flight call owns the
/// cleanup.
actor ContainerDestroyFinalizer {
    static let shared = ContainerDestroyFinalizer()

    /// How long a completed finalization is remembered, so a delayed
    /// late-success callback (or a client retry) is recognized as a
    /// duplicate rather than running the cleanup a second time.
    private static let memoryTTL: TimeInterval = 3600
    private static let maxMemory = 4096

    private var inProgress: Set<String> = []
    private var completed: [String: Date] = [:]

    /// Runs `body` for `key` unless this finalizer already ran (or is
    /// running) for it. The body is instance-scoped by construction: it is
    /// built from the deleted container's captured snapshot/hex id and must
    /// never touch a same-name replacement.
    func finalizeOnce(key: String, _ body: @Sendable () async -> Void) async {
        if completed[key] != nil { return }
        guard inProgress.insert(key).inserted else { return }
        await body()
        inProgress.remove(key)
        prune()
        completed[key] = Date()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.memoryTTL)
        completed = completed.filter { $0.value > cutoff }
        if completed.count > Self.maxMemory {
            let newest = completed.sorted { $0.value > $1.value }.prefix(Self.maxMemory)
            completed = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }
}
