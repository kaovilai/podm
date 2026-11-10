import Testing

@testable import podmd

/// Focused semantics tests for the shared race helper. The conformance test
/// depends on the DOUBLE-optional contract: `.some(nil)` (task completed,
/// recorded no response) must stay distinguishable from `nil` (deadline hit) —
/// see `AsyncRace.firstOrTimeout` for why `Task<T?, Never>` would collapse
/// them into one indistinguishable `nil`.
@Suite("AsyncRace — first-or-timeout semantics")
struct AsyncRaceTests {
    @Test("a task completing with nil yields .some(nil), not a timeout")
    func completedWithNilIsSomeNil() async {
        let task = Task<Int?, Never> { nil }
        let outcome = await AsyncRace.firstOrTimeout(task, timeoutNs: 1_000_000_000)
        #expect(outcome == .some(nil))
    }

    @Test("a task completing with a value yields .some(value) before the deadline")
    func completedWithValueIsSomeValue() async {
        let task = Task<String?, Never> { "winner" }
        let outcome = await AsyncRace.firstOrTimeout(task, timeoutNs: 1_000_000_000)
        #expect(outcome == .some("winner"))
    }

    @Test("a deadline hit yields outer nil even though the task later completes")
    func timeoutYieldsOuterNil() async {
        let task = Task<String?, Never> {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return "late"
        }
        // Deadline long before the task finishes: the race must resume with
        // nil, and the late task value must be discarded, not delivered.
        let outcome = await AsyncRace.firstOrTimeout(task, timeoutNs: 30_000_000)
        #expect(outcome == nil)
    }

    @Test("ResumeOnce ignores the second resume instead of trapping")
    func resumeOnceDropsSecondResume() async {
        // A double resume of a CheckedContinuation is a runtime trap; the
        // losing racer is guaranteed to fire late, so the wrapper must
        // silently drop it. First value wins.
        let value: String? = await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            once.resume(returning: "first")
            once.resume(returning: "second")
        }
        #expect(value == "first")
    }
}
