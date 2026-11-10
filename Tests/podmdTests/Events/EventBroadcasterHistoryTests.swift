import Foundation
import Testing

@testable import podmd

@Suite("EventBroadcaster — history replay")
struct EventBroadcasterHistoryTests {

    /// A DockerEvent with a controlled timeNano (the public constructors
    /// stamp `Date()`; replay logic is exercised against fixed instants).
    private func makeEvent(id: String, action: String, timeNano: UInt64) -> DockerEvent {
        DockerEvent(
            status: action, id: id, from: "", Type: "container", Action: action,
            Actor: DockerActor(ID: id, Attributes: ["name": id]),
            scope: "local", time: Int(timeNano / 1_000_000_000), timeNano: timeNano
        )
    }

    @Test("no since/until means no replay — the no-parameter request stays pure live")
    func noBoundsNoReplay() async {
        let broadcaster = EventBroadcaster()
        await broadcaster.broadcast(makeEvent(id: "a", action: "start", timeNano: 100))
        let replay = await broadcaster.snapshot(since: nil, until: nil)
        #expect(replay.isEmpty)
    }

    @Test("since-only replays events at or after the bound, oldest first")
    func sinceOnly() async {
        let broadcaster = EventBroadcaster()
        for (i, id) in ["a", "b", "c"].enumerated() {
            await broadcaster.broadcast(makeEvent(id: id, action: "start", timeNano: UInt64(100 + i * 10)))
        }
        let replay = await broadcaster.snapshot(since: 110, until: nil)
        #expect(replay.map(\.id) == ["b", "c"], "event exactly at since is included")
    }

    @Test("until-only replays events at or before the bound")
    func untilOnly() async {
        let broadcaster = EventBroadcaster()
        for (i, id) in ["a", "b", "c"].enumerated() {
            await broadcaster.broadcast(makeEvent(id: id, action: "start", timeNano: UInt64(100 + i * 10)))
        }
        let replay = await broadcaster.snapshot(since: nil, until: 110)
        #expect(replay.map(\.id) == ["a", "b"])
    }

    @Test("since and until bound both ends; the matching predicate filters replay")
    func windowAndPredicate() async {
        let broadcaster = EventBroadcaster()
        for (i, id) in ["a", "b", "c", "d"].enumerated() {
            await broadcaster.broadcast(makeEvent(id: id, action: i % 2 == 0 ? "start" : "die", timeNano: UInt64(100 + i * 10)))
        }
        let replay = await broadcaster.snapshot(
            since: 105, until: 130,
            matching: { $0.Action == "start" })
        #expect(replay.map(\.id) == ["c"], "only the start event inside the window")
    }

    @Test("history is capped at the last historyLimit events")
    func historyCap() async {
        let broadcaster = EventBroadcaster()
        let count = EventBroadcaster.historyLimit + 50
        for i in 0..<count {
            await broadcaster.broadcast(makeEvent(id: "ctr-\(i)", action: "start", timeNano: UInt64(i)))
        }
        let replay = await broadcaster.snapshot(since: 0, until: nil)
        #expect(replay.count == EventBroadcaster.historyLimit)
        #expect(replay.first?.id == "ctr-50", "oldest events were evicted")
        #expect(replay.last?.id == "ctr-\(count - 1)")
    }

    @Test("subscribe computes replay and registers the live stream in one hop")
    func subscribeIsAtomic() async {
        let broadcaster = EventBroadcaster()
        await broadcaster.broadcast(makeEvent(id: "a", action: "start", timeNano: 100))

        let subscription = await broadcaster.subscribe(since: 0, until: nil)
        #expect(subscription.replay.map(\.id) == ["a"])

        // Broadcast after subscribe returned: must arrive on the live stream,
        // never duplicated into the already-computed replay.
        await broadcaster.broadcast(makeEvent(id: "b", action: "die", timeNano: 200))
        #expect(subscription.replay.map(\.id) == ["a"], "replay is a frozen snapshot")

        let first = Task<DockerEvent?, Never> {
            for await event in subscription.stream { return event }
            return nil
        }
        let received = await withTimeout(first)
        first.cancel()
        #expect(received?.id == "b", "post-subscribe broadcast is delivered live exactly once")
    }
}

/// Returns the task's value, or nil after a 1s deadline (the existing events
/// tests use the same pattern).
private func withTimeout<T>(_ task: Task<T?, Never>) async -> T? {
    let timeout = Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
    }
    defer { timeout.cancel() }
    return await task.value ?? nil
}
