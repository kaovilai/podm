// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import Vapor

/// `POST /libpod/images/{name}/untag` — real podman's `podman untag` / `podman image untag`
/// (pkg/api/handlers/libpod/images.go `UntagImage`): removes a name from a locally-stored
/// image WITHOUT deleting the image itself, in contrast to `DELETE /libpod/images/{name}`
/// (which removes the reference AND reclaims whatever content that frees).
///
/// Query parameters follow podman's own "parameter dance" (identical to the one on
/// `POST .../tag`): `tag` without `repo` is a 400; `repo` alone defaults the tag to
/// `latest`; neither present means "remove ALL names of the image" (podman's own documented
/// `podman untag <image>` behavior).
///
/// In this daemon's image store every tag of an image is its own reference row pointing at
/// the shared content descriptor, so "untag" is exactly removing that one row with
/// garbage collection disabled: the content blobs and snapshots stay put (the image's other
/// references still need them), which is the analogue of podman's `store.RemoveNames`. No
/// 501 is needed — the store CAN remove a single reference while keeping the image.
///
/// Status: 201 Created with an empty body, matching real podman's UntagImage
/// handler (any 2xx satisfies podman's bindings client, which only checks
/// `IsSuccess` — 201 is the faithful choice).
struct RESTImageUntagQuery: Content {
    let repo: String?
    let tag: String?
}

/// Seam abstracting the static `ClientImage` calls the untag handler makes, so tests can
/// inject an in-memory fake — same pattern as `ImageDeletionStore` for the delete route.
/// The real implementation talks to Apple Container's apiserver over XPC.
protocol ImageUntagStore: Sendable {
    /// Resolve `name` (as the user gave it — reference, short name, …) to the reference as
    /// ACTUALLY stored plus the image digest. Throws when the image is unknown.
    func resolve(name: String, systemConfig: ContainerSystemConfig) async throws -> (reference: String, digest: String)
    /// All live stored references sharing `digest` — the image's "names" in podman terms.
    func references(forDigest digest: String) async throws -> [String]
    /// Remove exactly one reference row; must never touch content blobs or snapshots.
    func delete(reference: String) async throws
}

/// Production implementation — delegates to Apple Container's `ClientImage` XPC API.
struct LiveImageUntagStore: ImageUntagStore {
    func resolve(name: String, systemConfig: ContainerSystemConfig) async throws -> (reference: String, digest: String) {
        // `ClientImage.get`'s own raw/normalized fallback search resolves however the
        // reference is actually stored (e.g. a bare tag from a local build), which a
        // pre-normalized guess would miss.
        let image = try await ClientImage.get(reference: name, containerSystemConfig: systemConfig)
        return (image.reference, image.digest)
    }

    func references(forDigest digest: String) async throws -> [String] {
        try await ClientImage.list().filter { $0.digest == digest }.map(\.reference)
    }

    func delete(reference: String) async throws {
        // garbageCollect: false — the blobs may still be referenced by the image's other
        // tags (or left on disk for a later prune, mirroring podman's dangling image);
        // this must only remove the reference row itself.
        try await ClientImage.delete(reference: reference, garbageCollect: false)
    }
}

struct LibpodImageUntagRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig
    let store: ImageUntagStore

    init(systemConfig: ContainerSystemConfig, store: ImageUntagStore = LiveImageUntagStore()) {
        self.systemConfig = systemConfig
        self.store = store
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/{name:.*}/untag") { [systemConfig, store] req in
            try await LibpodImageUntagRoute.handler(req, systemConfig: systemConfig, store: store)
        }
    }

    static func handler(_ req: Request, systemConfig: ContainerSystemConfig, store: ImageUntagStore) async throws -> Response {
        guard let name = req.parameters.get("name"), !name.isEmpty else {
            throw Abort(.badRequest, reason: "Missing image name parameter")
        }
        let query = try req.query.decode(RESTImageUntagQuery.self)

        // Real podman's parameter dance (UntagImage): `tag` without `repo` is a client
        // error; `repo` alone defaults the tag to `latest`; neither means "all names".
        var untagTargets: [String] = []
        if let repo = query.repo, !repo.isEmpty {
            let tagName = if let tag = query.tag, !tag.isEmpty { tag } else { "latest" }
            untagTargets = ["\(repo):\(tagName)"]
        } else if let tag = query.tag, !tag.isEmpty {
            throw Abort(.badRequest, reason: "repo parameter is required to tag an image")
        }

        // Resolve the image first — an unknown image is a 404 (real podman maps
        // storage.ErrImageUnknown to its ImageNotFound response here).
        let resolved: (reference: String, digest: String)
        do {
            resolved = try await store.resolve(name: name, systemConfig: systemConfig)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw Abort(.notFound, reason: "No such image: \(name)")
        }

        let allReferences = try await store.references(forDigest: resolved.digest)

        // Neither repo nor tag: remove every name of the image, as real podman does. The
        // content blobs stay on disk (delete never garbage-collects) — the analogue of
        // podman keeping the untagged, dangling image record, which likewise disappears
        // from default image listings while remaining in storage until pruned.
        guard let target = untagTargets.first else {
            for reference in allReferences {
                try await store.delete(reference: reference)
                await broadcastUntag(req: req, digest: resolved.digest, reference: reference)
            }
            return Response(status: .created)
        }

        // libimage's Image.Untag refuses a digest-pinned target — it is ambiguous against
        // every repository tag the image may carry.
        if target.hasPrefix("sha256:") {
            throw Abort(.badRequest, reason: "\(target): cannot untag a digest reference")
        }
        let normalized: String
        do {
            normalized = try ClientImage.normalizeReference(target, containerSystemConfig: systemConfig)
        } catch {
            throw Abort(.badRequest, reason: "invalid reference \(target): \(error)")
        }
        // Match how the reference is ACTUALLY stored: locally-built images can carry a
        // bare, non-normalized tag (see LiveImageUntagStore.resolve for the same caveat),
        // so accept either spelling, restricted to this image's own references.
        guard let stored = allReferences.first(where: { $0 == target || $0 == normalized }) else {
            throw Abort(.notFound, reason: "\(target) is not a tag of \(name)")
        }

        try await store.delete(reference: stored)
        await broadcastUntag(req: req, digest: resolved.digest, reference: stored)
        return Response(status: .created)
    }

    /// Emits the docker-shaped `image untag` event the delete/tag routes already emit for
    /// the same operation, so `docker events` / `podman events` listeners see the untag.
    private static func broadcastUntag(req: Request, digest: String, reference: String) async {
        if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
            await broadcaster.broadcast(
                DockerEvent.make(type: "image", action: "untag", actorID: digest, attributes: ["name": reference])
            )
        }
    }
}
