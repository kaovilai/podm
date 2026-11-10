import ContainerAPIClient
import NIOCore
import Vapor

struct EventsRoute: RouteCollection {
    let client: ClientHealthCheckProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/events", use: EventsRoute.handler(client: client))
    }

}

extension EventsRoute {
    static func handler(client: ClientHealthCheckProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else {
                throw Abort(.internalServerError, reason: "EventBroadcaster not configured")
            }

            // --since/--until/--filter, moby's `getEvents` shape: resolved
            // timestamps, `until` fully in the past closes the response after
            // replaying history, and `since` after `until` is a 400.
            let since: DockerTimeParam.Timestamp?
            let until: DockerTimeParam.Timestamp?
            do {
                since = try DockerTimeParam.parse(req.query[String.self, at: "since"])
                until = try DockerTimeParam.parse(req.query[String.self, at: "until"])
            } catch let error as DockerTimeParam.ParseError {
                throw Abort(.badRequest, reason: "\(error)")
            }
            if let since, let until, until < since {
                throw Abort(
                    .badRequest,
                    reason:
                        "`since` time (\(req.query[String.self, at: "since"] ?? "")) cannot be after `until` time (\(req.query[String.self, at: "until"] ?? ""))"
                )
            }

            let filters = try DockerEventFilterUtility.parse(
                filtersParam: req.query[String.self, at: "filters"], logger: req.logger)
            // Rename overrides only matter when filtering by container name.
            let nameOverrides: [String: String] =
                filters["container"] != nil
                ? await ContainerNameOverrideStore.shared.snapshot() : [:]
            let matcher = DockerEventFilterUtility.makeMatcher(filters, nameOverrides: nameOverrides)

            let sinceNano = since?.unsignedNanoSinceEpoch
            let untilNano = until?.unsignedNanoSinceEpoch
            let onlyPastEvents = untilNano.map { $0 < currentNano() } ?? false

            // One actor hop: the replay slice and the live registration share
            // the broadcaster's isolation, so no event can fall between them.
            let subscription = await broadcaster.subscribe(
                since: sinceNano, until: untilNano, matching: matcher)
            let replay = subscription.replay
            let stream = subscription.stream

            let response = Response(status: .ok)
            response.headers.add(name: .contentType, value: "application/json")

            // idleTracked: keep the idle-exit monitor aware that this
            // long-lived events stream is an active client connection.
            response.body = .idleTracked(asyncStream: { writer in
                // Finite replay first — already time- and filter-bounded by
                // the broadcaster.
                for event in replay {
                    let clientGone = !(await writeEvent(event, to: writer, req: req))
                    if clientGone { return }
                }

                // `until` fully in the past: the response ends here, no
                // live stream is opened (moby's `onlyPastEvents`).
                if onlyPastEvents {
                    _ = try? await writer.write(.end)
                    return
                }

                // Vapor 4.121 runs this body callback in an unstructured task
                // and does NOT cancel it when the client disconnects, and with
                // no incoming events the for-await below never wakes — a quiet
                // events client that disconnects (docker events + Ctrl-C) would
                // hold the idle-exit activity token forever. A parallel
                // heartbeat writes an empty chunk every 30s: zero-length chunks
                // carry no JSON line so clients ignore them, and a failed write
                // (client gone) cancels the event loop so the token releases.
                let eventLoop = Task {
                    for await event in stream {
                        guard matcher?(event) ?? true else { continue }
                        // Live events past `until` close the stream — same
                        // guarantee moby's until-timer gives, without the race.
                        if let untilNano, event.timeNano > untilNano { break }
                        let clientGone = !(await writeEvent(event, to: writer, req: req))
                        if clientGone { return }
                    }
                }
                let heartbeat = Task {
                    while true {
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        do {
                            try await writer.write(.buffer(req.application.allocator.buffer(capacity: 0)))
                        } catch {
                            req.logger.debug("Events client disconnected (heartbeat write failed)")
                            eventLoop.cancel()
                            return
                        }
                    }
                }
                // moby arms a timer at `until` and closes the stream when it
                // fires even if no event arrives to trip the check above.
                let untilTimer: Task<Void, Never>? = untilNano.map { deadline in
                    Task {
                        let remaining = Int64(clamping: deadline) - currentNano()
                        if remaining > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(remaining))
                        }
                        eventLoop.cancel()
                    }
                }
                await eventLoop.value
                heartbeat.cancel()
                untilTimer?.cancel()
                _ = try? await writer.write(.end)
            })

            return response

        }
    }

    /// One JSON event as a body chunk, with the same disconnect handling the
    /// route always had. Returns false when the client is gone and the
    /// producer loop should stop consuming.
    private static func writeEvent(
        _ event: DockerEvent, to writer: AsyncBodyStreamWriter, req: Request
    ) async -> Bool {
        guard let json = try? JSONEncoder().encode(event) else { return true }
        var buffer = req.application.allocator.buffer(capacity: json.count + 1)
        buffer.writeBytes(json)
        buffer.writeString("\n")
        do {
            try await writer.write(.buffer(buffer))
            return true
        } catch is IOError {
            req.logger.debug("Client disconnected (broken pipe)")
            return false
        } catch let error as ChannelError where error == .ioOnClosedChannel {
            req.logger.debug("Client disconnected (closed channel)")
            return false
        } catch {
            req.logger.warning("\(event) raised '\(error)'")
            return true
        }
    }
}

/// Wall-clock nanoseconds since the epoch (event `timeNano`'s clock).
private func currentNano() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000_000_000).rounded())
}
