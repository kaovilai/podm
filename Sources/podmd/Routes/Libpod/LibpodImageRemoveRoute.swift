// SPDX-License-Identifier: Apache-2.0
import Vapor

/// `DELETE /libpod/images/remove` — podman's batch image removal endpoint, hit by
/// `podman rmi` / `podman image rm` over the remote (bindings) client.
///
/// Contract (verified against podman v6.1.1):
///   - `pkg/api/server/register_images.go` maps `DELETE /libpod/images/remove` to
///     `libpod.ImagesBatchRemove`, registered *before* the `/libpod/images/{name:.*}`
///     wildcard so the literal segment wins.
///   - `pkg/bindings/images/rm.go` sends the image list as repeated `images` **query
///     params** (plus `force`/`all`/`ignore`), with no request body.
///   - The handler always answers **200** with a single `LibpodImagesRemoveReport`
///     object (`pkg/api/handlers/types.go`): `entities.ImageRemoveReport`
///     (`Deleted`/`Untagged`/`ExitCode`, arrays omitempty) plus `Errors []string`.
///     Per-image failures ride in `Errors` and the `ExitCode` field (0 = success,
///     1 = image not found, 2 = other errors — podman rmi's man-page exit codes);
///     unlike the single-image endpoint they never change the HTTP status.
///
/// A JSON body `{"images": [...], "force": ..., "all": ...}` is also accepted as a
/// fallback for clients that send one; query params (what podman actually sends)
/// take precedence.
struct LibpodImageRemoveRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/images/remove", use: Self.handler(client: client))
    }
}

extension LibpodImageRemoveRoute {
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> LibpodImageRemoveReport {
        { req in
            // Query params are the primary transport (podman's bindings client).
            var images = (try? req.query.get([String].self, at: "images")) ?? []
            var force = (try? req.query.get(Bool.self, at: "force")) ?? false
            let ignore = (try? req.query.get(Bool.self, at: "ignore")) ?? false
            let all = (try? req.query.get(Bool.self, at: "all")) ?? false

            // Body fallback for clients that POST-style JSON bodies on DELETE.
            if images.isEmpty, let body = try? req.content.decode(LibpodImageRemoveBody.self) {
                images = body.images ?? []
                force = body.force ?? force
            }

            // `all` replaces the explicit list, as in podman: remove every image in
            // the store. Each image is deleted once, by digest (its stable ID).
            if all {
                let everyImage = try await client.list()
                images = Array(Set(everyImage.map(\.digest)))
            }

            var deleted: [String] = []
            var untagged: [String] = []
            var errors: [String] = []
            var exitCode = 0
            // podman's batch handler with an empty image list returns an empty report
            // with exit code 0 (the CLI itself rejects a bare `rmi`).
            guard !images.isEmpty else {
                return LibpodImageRemoveReport(Deleted: nil, Untagged: nil, ExitCode: 0, Errors: [])
            }

            // Delegate the actual deletion (dangling-image handling, untag/delete
            // events, response shaping) to the Docker-dialect single-image handler,
            // one invocation per image. `force` is accepted for API compatibility;
            // deletion severity is decided by the image client, which currently has
            // no force knob (the Docker dialect ignores `force` too).
            let deleteOne = ImageDeleteRoute.handler(client: client)
            for image in images {
                req.parameters.set("name", to: image)
                do {
                    let response = try await deleteOne(req)
                    guard let json = response.body.string else {
                        throw Abort(.internalServerError, reason: "image delete returned an unreadable body")
                    }
                    let items = try JSONDecoder().decode([ImageDeleteResponseItem].self, from: Data(json.utf8))
                    deleted += items.compactMap(\.Deleted)
                    untagged += items.compactMap(\.Untagged)
                } catch let abort as Abort {
                    switch abort.status {
                    case .notFound where ignore:
                        // `ignore` (podman's rmi --ignore): missing images are
                        // skipped silently, without failing the batch.
                        continue
                    case .notFound:
                        exitCode = max(exitCode, 1)
                        errors.append(abort.reason)
                    default:
                        exitCode = max(exitCode, 2)
                        errors.append(abort.reason)
                    }
                } catch {
                    exitCode = max(exitCode, 2)
                    errors.append("\(image): \(error)")
                }
            }
            return LibpodImageRemoveReport(
                Deleted: deleted.isEmpty ? nil : deleted,
                Untagged: untagged.isEmpty ? nil : untagged,
                ExitCode: exitCode,
                Errors: errors
            )
        }
    }
}

/// Request body fallback shape for `DELETE /libpod/images/remove`.
private struct LibpodImageRemoveBody: Content {
    let images: [String]?
    let force: Bool?
    let all: Bool?
}

/// Mirrors podman's `handlers.LibpodImagesRemoveReport` = `entities.ImageRemoveReport`
/// (`Deleted`/`Untagged` with `json:",omitempty"`, always-present `ExitCode`) plus
/// `Errors []string`. Field names must stay Go-style capitalized — podman's client
/// decodes them positionally by JSON name.
struct LibpodImageRemoveReport: Content {
    /// sha256 digests of images whose layers were actually freed. Omitted when empty.
    let Deleted: [String]?
    /// References that were untagged (can be longer than `Deleted`). Omitted when empty.
    let Untagged: [String]?
    /// 0 = success, 1 = image(s) not found, 2 = other errors (podman rmi man page).
    let ExitCode: Int
    /// Per-image error strings; the HTTP status stays 200 regardless.
    let Errors: [String]
}
