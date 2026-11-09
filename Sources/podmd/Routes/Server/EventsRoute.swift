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
            let stream = await broadcaster.stream()

            let response = Response(status: .ok)
            response.headers.add(name: .contentType, value: "application/json")

            // idleTracked: keep the idle-exit monitor aware that this
            // long-lived events stream is an active client connection.
            response.body = .idleTracked(asyncStream: { writer in
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
                        if let json = try? JSONEncoder().encode(event) {
                            var buffer = req.application.allocator.buffer(capacity: json.count + 1)
                            buffer.writeBytes(json)
                            buffer.writeString("\n")
                            do {
                                try await writer.write(.buffer(buffer))
                            } catch is IOError {
                                req.logger.debug("Client disconnected (broken pipe)")
                                return
                            } catch let error as ChannelError where error == .ioOnClosedChannel {
                                req.logger.debug("Client disconnected (closed channel)")
                                return
                            } catch {
                                req.logger.warning("\(event) raised '\(error)'")
                            }
                        }
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
                await eventLoop.value
                heartbeat.cancel()
                _ = try? await writer.write(.end)
            })

            return response

        }
    }
}
