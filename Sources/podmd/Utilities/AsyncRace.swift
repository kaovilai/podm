import Foundation

/// Racing helpers shared by the daemon and tests.
enum AsyncRace {
    /// Resumes with the task's result, or `nil` if the timeout elapses first.
    /// The task's success type `T` may itself be an Optional — the result is
    /// then a DOUBLE optional, keeping "completed with nil" distinguishable
    /// from "timed out": `.some(nil)` vs `nil`. (Taking `Task<T?, Never>`
    /// instead would collapse both into one `nil`.) The loser is never awaited
    /// on the winning path: whichever finishes second finds the continuation
    /// already consumed and is ignored. Use this INSTEAD of a task group when
    /// the loser may never finish — a group's scope waits for every child at
    /// exit, so a stalled child would defeat the timeout.
    static func firstOrTimeout<T: Sendable>(_ task: Task<T, Never>, timeoutNs: UInt64) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(cont)
            Task {
                once.resume(returning: await task.value)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                once.resume(returning: nil)
            }
        }
    }
}

/// One-shot continuation wrapper — the second resume is a no-op instead of a
/// fatal error (the losing racer is guaranteed to fire late).
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}
