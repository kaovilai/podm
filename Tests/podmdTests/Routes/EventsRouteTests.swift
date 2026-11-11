import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `GET /events` since/until/filters — the finite (past-`until`) request is
/// fully testable: it replays the broadcaster's history and terminates. The
/// unbounded live stream is covered by the registration-race and delivery
/// unit tests and the route-conformance hang probe.
@Suite("EventsRoute — since/until/filters")
struct EventsRouteTests {

    private struct MockHealthCheckClient: ClientHealthCheckProtocol {
        func ping() async throws {}
    }

    /// A DockerEvent with a controlled timeNano, so replay windows are
    /// deterministic.
    private func makeEvent(
        type: String = "container", action: String, id: String, timeNano: UInt64
    ) -> DockerEvent {
        DockerEvent(
            status: action, id: id, from: "", Type: type, Action: action,
            Actor: DockerActor(ID: id, Attributes: ["name": id]),
            scope: "local", time: Int(timeNano / 1_000_000_000), timeNano: timeNano
        )
    }

    private func nanoNow() -> UInt64 {
        UInt64((Date().timeIntervalSince1970 * 1_000_000_000).rounded())
    }

    /// Formats nanoseconds since the epoch as moby's `sec.nsec` param.
    /// The fraction is LEFT-padded to nine digits — `padding(toLength:)`
    /// appends, turning a remainder of 60,000,000 ns into `.600000000`
    /// (540 ms off) instead of `.060000000`.
    private func param(_ nano: UInt64) -> String {
        let ns = String(nano % 1_000_000_000)
        return "\(nano / 1_000_000_000)." + String(repeating: "0", count: 9 - ns.count) + ns
    }

    private func decodeEvents(_ body: ByteBuffer) -> [DockerEvent] {
        body.string
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(DockerEvent.self, from: Data($0.utf8)) }
    }

    @Test("a fully past until replays buffered events and terminates the response")
    func pastUntilReplaysAndTerminates() async throws {
        let broadcaster = EventBroadcaster()
        let now = nanoNow()
        await broadcaster.broadcast(makeEvent(action: "create", id: "ctr-a", timeNano: now - 2_000_000_000))
        await broadcaster.broadcast(makeEvent(action: "start", id: "ctr-a", timeNano: now - 1_000_000_000))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: EventsRoute(client: MockHealthCheckClient()))

            // until is 0.5s in the past: both events are older, and the
            // response must end (onlyPastEvents) instead of streaming.
            try await app.testing().test(
                .GET, "/v1.51/events?since=0&until=\(param(now - 500_000_000))"
            ) { res async in
                #expect(res.status == .ok)
                let events = self.decodeEvents(res.body)
                #expect(events.map(\.id) == ["ctr-a", "ctr-a"], "replay is oldest-first")
                #expect(events.map(\.Action) == ["create", "start"])
            }
        }
    }

    @Test("a future until terminates the response when the deadline passes")
    func futureUntilTerminates() async throws {
        let broadcaster = EventBroadcaster()
        let now = nanoNow()
        await broadcaster.broadcast(makeEvent(action: "create", id: "replayed", timeNano: now - 1_000_000_000))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: EventsRoute(client: MockHealthCheckClient()))

            // until is 400ms in the future: the replayed in-window event is
            // delivered, then the response ends when the deadline timer
            // fires — instead of streaming forever.
            try await app.testing().test(
                .GET, "/v1.51/events?since=0&until=\(param(now + 400_000_000))"
            ) { res async in
                #expect(res.status == .ok)
                let events = self.decodeEvents(res.body)
                #expect(events.map(\.id) == ["replayed"])
            }
        }
    }

    @Test("a live event broadcast after subscribe is delivered within a future until")
    func liveEventWithinFutureUntil() async throws {
        let broadcaster = EventBroadcaster()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: EventsRoute(client: MockHealthCheckClient()))

            // The request runs; shortly after the subscription is live, an
            // event is broadcast and must appear in the response body
            // before the until deadline ends it. Generous margins (2s
            // deadline, 150ms broadcast) keep this stable under parallel
            // suite load: whether the broadcast lands before subscribe
            // (delivered via the replay snapshot) or after (delivered via
            // the live stream), the event is in the body either way.
            let deadline = nanoNow() + 2_000_000_000
            Task {
                try await Task.sleep(nanoseconds: 150_000_000)
                await broadcaster.broadcast(
                    self.makeEvent(action: "start", id: "live-ctr", timeNano: self.nanoNow()))
            }
            try await app.testing().test(
                .GET, "/v1.51/events?since=0&until=\(param(deadline))"
            ) { res async in
                #expect(res.status == .ok)
                let events = self.decodeEvents(res.body)
                #expect(events.map(\.id).contains("live-ctr"), "the live broadcast must be delivered")
            }
        }
    }

    @Test("an unparseable since or until is a 400")
    func unparseableBoundsRejected() async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: EventsRoute(client: MockHealthCheckClient()))

            try await app.testing().test(.GET, "/v1.51/events?since=not-a-time") { res async in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.GET, "/v1.51/events?until=yesterday") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("since bounds the replay window")
    func sinceBoundsReplay() async throws {
        let broadcaster = EventBroadcaster()
        let now = nanoNow()
        await broadcaster.broadcast(makeEvent(action: "create", id: "old", timeNano: now - 2_000_000_000))
        await broadcaster.broadcast(makeEvent(action: "start", id: "new", timeNano: now - 1_000_000_000))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: EventsRoute(client: MockHealthCheckClient()))

            try await app.testing().test(
                .GET, "/v1.51/events?since=\(param(now - 1_500_000_000))&until=\(param(now - 500_000_000))"
            ) { res async in
                #expect(res.status == .ok)
                let events = self.decodeEvents(res.body)
                #expect(events.map(\.id) == ["new"])
            }
        }
    }

    @Test("filters narrow the replayed events")
    func filtersNarrowReplay() async throws {
        let broadcaster = EventBroadcaster()
        let now = nanoNow()
        await broadcaster.broadcast(makeEvent(action: "start", id: "ctr-a", timeNano: now - 2_000_000_000))
        await broadcaster.broadcast(
            makeEvent(type: "network", action: "create", id: "net-1", timeNano: now - 1_000_000_000))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: EventsRoute(client: MockHealthCheckClient()))

            let filters = #"{"type":{"network":true}}"#.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed)!
            try await app.testing().test(
                .GET, "/v1.51/events?since=0&until=\(param(now - 500_000_000))&filters=\(filters)"
            ) { res async in
                #expect(res.status == .ok)
                let events = self.decodeEvents(res.body)
                #expect(events.map { $0.Type } == ["network"])
            }
        }
    }

    @Test("since after until is a 400, like moby")
    func sinceAfterUntilRejected() async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: EventsRoute(client: MockHealthCheckClient()))

            try await app.testing().test(
                .GET, "/v1.51/events?since=200&until=100"
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("cannot be after"))
            }
        }
    }

    @Test("an unknown filter key is a 400")
    func unknownFilterKeyRejected() async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: EventsRoute(client: MockHealthCheckClient()))

            let filters = #"{"bogus":{"x":true}}"#.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed)!
            try await app.testing().test(
                .GET, "/v1.51/events?filters=\(filters)"
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }
}
