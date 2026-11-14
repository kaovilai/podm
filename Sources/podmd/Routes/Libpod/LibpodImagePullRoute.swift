import Foundation
import Vapor

struct LibpodImagePullRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/pull", use: LibpodImagePullRoute.handler(client: client))
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let reference = req.query["reference"] as String?, !reference.isEmpty else {
                throw Abort(.badRequest, reason: "Missing reference query parameter")
            }
            let (image, tag) = parseReference(reference)

            let platform = try LibpodImagePullRoute.platform(from: req)

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")
            let progressStream = try await client.pull(
                image: image, tag: tag, platform: platform, logger: req.logger)

            struct PullStreamLine: Encodable {
                var stream: String?
                var images: [String]?
                var id: String?
                var error: String?
            }
            let encoder = JSONEncoder()
            @Sendable func encodeLine(_ line: PullStreamLine) -> ByteBuffer {
                guard let data = try? encoder.encode(line) else {
                    return ByteBuffer(string: "{\"error\": \"failed to encode progress\"}\n")
                }
                var buffer = ByteBuffer(bytes: data)
                buffer.writeString("\n")
                return buffer
            }

            response.body = .idleTracked(stream: { writer in
                Task {
                    do {
                        for try await progress in progressStream {
                            let message: String
                            switch progress {
                            case .message(let text): message = text
                            case .downloading(let current, let total): message = "Downloading \(current)/\(total)"
                            case .extracting(let current, let total): message = "Extracting \(current)/\(total)"
                            }
                            _ = writer.write(.buffer(encodeLine(PullStreamLine(stream: message + "\n"))))
                        }
                        let imageRef = tag.isEmpty ? image : "\(image):\(tag)"
                        _ = writer.write(.buffer(encodeLine(PullStreamLine(images: [imageRef], id: imageRef))))
                        _ = writer.write(.end)
                    } catch {
                        _ = writer.write(.buffer(encodeLine(PullStreamLine(error: error.localizedDescription))))
                        _ = writer.write(.error(error))
                    }
                }
            })
            return response
        }
    }

    /// Resolves the platform a pull asks for.
    ///
    /// podman does NOT send a `platform` query parameter: `podman pull --platform
    /// linux/amd64` arrives as separate `os`/`arch`/`variant` parameters. Reading
    /// only `platform` fell back to the host platform for every `--platform` ask —
    /// `podman pull --platform linux/amd64` fetched the arm64 image, and
    /// `podman run --platform linux/amd64|linux/s390x` silently ran arm64 (the run
    /// only pulls with the platform the pull was given). `platform` stays first:
    /// other libpod clients (compose) do send the combined form.
    static func platform(from req: Request) throws -> Platform {
        if let platformString: String = req.query["platform"], !platformString.isEmpty {
            do {
                return try platformOrThrow(platformString)
            } catch {
                throw Abort(
                    .badRequest, reason: "Failed to parse platform '\(platformString)': \(error.localizedDescription)")
            }
        }

        let os: String? = req.query["os"]
        let arch: String? = req.query["arch"]
        let variant: String? = req.query["variant"]
        let requestedOS = os.flatMap { $0.isEmpty ? nil : $0 }
        let requestedArch = arch.flatMap { $0.isEmpty ? nil : $0 }
        let requestedVariant = variant.flatMap { $0.isEmpty ? nil : $0 }
        // Nothing platform-shaped asked for — the host's platform. A variant
        // alone IS an ask (it is validated against the host's os/arch rather
        // than silently discarded).
        guard requestedOS != nil || requestedArch != nil || requestedVariant != nil else { return currentPlatform() }

        let host = currentPlatform()
        let resolvedOS = requestedOS ?? host.os
        let resolvedArch = requestedArch ?? host.architecture
        let resolvedVariant = requestedVariant
        let spec = resolvedVariant.map { "\(resolvedOS)/\(resolvedArch)/\($0)" } ?? "\(resolvedOS)/\(resolvedArch)"
        do {
            return try Platform(from: spec)
        } catch {
            throw Abort(.badRequest, reason: "Failed to parse platform '\(spec)': \(error.localizedDescription)")
        }
    }

    private static func parseReference(_ reference: String) -> (image: String, tag: String) {
        let decoded = reference.removingPercentEncoding ?? reference
        // A digest reference (name@sha256:...) has no tag component — the colon inside
        // the digest is not a tag separator.
        if decoded.contains("@") {
            return (decoded, "")
        }
        if let colonIndex = decoded.lastIndex(of: ":"),
            !decoded[colonIndex...].contains("/")
        {
            let image = String(decoded[..<colonIndex])
            let tag = String(decoded[decoded.index(after: colonIndex)...])
            return (image, tag)
        }
        return (decoded, "")
    }
}
