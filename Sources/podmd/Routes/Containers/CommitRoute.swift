import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import Vapor

/// Query for `POST /commit` (both dialects). Docker compat (moby's
/// `postCommit`) carries container/repo/tag/comment/author/changes/pause;
/// podman's libpod twin adds format/squash/stream. Booleans stay raw strings
/// and go through `MobyBool` — moby's `httputils.BoolValue` treats any
/// non-empty non-false value as true, which `Bool` decoding would reject.
struct RESTCommitQuery: Content {
    let container: String?
    let repo: String?
    let tag: String?
    let comment: String?
    let author: String?
    let changes: [String]?
    let pause: String?
    let squash: String?
    let format: String?
    let stream: String?
}

/// The subset of moby's `container.Config` the commit body may set. The full
/// Docker Config carries runtime-only fields (Hostname, AttachStdin, Image,
/// …) that cannot affect the committed image; moby decodes a superset and
/// discards them, so they are accepted-and-ignored by omission here rather
/// than rejected.
struct RESTCommitConfig: Content {
    let User: String?
    let ExposedPorts: [String: EmptyObject]?
    let Env: [String]?
    let Entrypoint: [String]?
    let Cmd: [String]?
    let Volumes: [String: EmptyObject]?
    let WorkingDir: String?
    let Labels: [String: String]?

    func overrides() -> CommitConfigOverrides {
        CommitConfigOverrides(
            user: User,
            exposedPorts: ExposedPorts.map { Set($0.keys) },
            env: Env,
            entrypoint: Entrypoint,
            cmd: Cmd,
            volumes: Volumes.map { Set($0.keys) },
            workingDir: WorkingDir,
            labels: Labels
        )
    }
}

/// moby's `types.CommitResponse` — swagger generates the JSON key `Id`
/// (`common.IDResponse`), not `ID`.
struct RESTCommitIDResponse: Content {
    let Id: String
}

/// `POST /commit` — `docker commit`. Lives with the container routes (moby
/// registers it on the container router too) because it needs the container,
/// archive, and image clients together.
///
/// Semantics mirror moby's `postCommit` + `daemon/commit.go
/// CreateImageFromContainer`:
/// - the container is looked up FIRST, before any body/tarball work, so a
///   bogus reference 404s fast;
/// - the optional body carries a sparse container Config, `--change`
///   Dockerfile instructions apply on top, and still-unset fields fill from
///   the container + parent image config (`ContainerCommitConfig`);
/// - the layer is the container's `rootfs.ext4` exported as a tarball — the
///   same volatile read `docker export` performs;
/// - the result is a single flattened layer, so `squash` is a no-op by
///   construction;
/// - `pause` is accepted and ignored (podm has no pause primitive; the
///   volatile read gives the same guarantee export does).
struct CommitRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let archiveClient: ClientArchiveProtocol
    let imageClient: ClientImageCommitProtocol

    /// The default-argument bridge keeps `RouteRegistry`'s historical
    /// `CommitRoute()` registration compiling: the real clients connect lazily
    /// (boot-safe per the registry's own docs) and a probe never gets past the
    /// container lookup. The registry should pass the daemon's actual clients
    /// — notably the real `imageClient`, whose system config carries registry
    /// mirrors — when this goes live.
    init(
        containerClient: ClientContainerProtocol = ClientContainerService(),
        archiveClient: ClientArchiveProtocol = ClientArchiveService(
            appSupportPath: URL(
                fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/com.apple.container")
        ),
        imageClient: ClientImageCommitProtocol = ClientImageService(
            containerSystemConfig: ContainerSystemConfig())
    ) {
        self.containerClient = containerClient
        self.archiveClient = archiveClient
        self.imageClient = imageClient
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST,
            pattern: "/commit",
            use: CommitRoute.handler(
                containerClient: containerClient, archiveClient: archiveClient, imageClient: imageClient)
        )
    }

    static func handler(
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol,
        imageClient: ClientImageCommitProtocol
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(RESTCommitQuery.self)

            // Container lookup FIRST — before the body is parsed or any
            // tarball work starts — so a bogus reference 404s fast (moby
            // resolves the container inside CreateImageFromContainer after
            // only cheap request parsing; the route-conformance probe relies
            // on this ordering). Both daemons route a missing/empty reference
            // through their lookup, which 404s.
            guard let containerReference = query.container, !containerReference.isEmpty else {
                throw Abort(.notFound, reason: "No such container: \(query.container ?? "")")
            }
            let resolved: ContainerSnapshot?
            do {
                resolved = try await containerClient.getContainer(id: containerReference)
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                throw Abort(
                    .badRequest,
                    reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
            }
            guard let container = resolved else {
                throw Abort(.notFound, reason: "No such container: \(containerReference)")
            }

            // Optional container Config body. moby decodes it with
            // CheckForJSON semantics: an empty body is fine (EOF ignored),
            // a malformed one is a 400. Parsed directly so a missing
            // Content-Type doesn't reject an otherwise valid body.
            _ = req.body.collect()
            let overrides: CommitConfigOverrides?
            if let bodyData = req.body.data, bodyData.readableBytes > 0 {
                let restConfig: RESTCommitConfig
                do {
                    restConfig = try JSONDecoder().decode(RESTCommitConfig.self, from: Data(buffer: bodyData))
                } catch {
                    throw Abort(.badRequest, reason: "invalid commit config body: \(error.localizedDescription)")
                }
                overrides = restConfig.overrides()
            } else {
                overrides = nil
            }

            // repo/tag — the same grammar import uses (moby's
            // httputils.RepoTagReference): no repo → untagged, empty tag →
            // latest, digest references rejected.
            let repo = query.repo ?? ""
            let tag = query.tag ?? ""
            switch ClientImageService.validateImportReference(repo: repo, tag: tag) {
            case .valid:
                break
            case .digestNotAllowed:
                throw Abort(.badRequest, reason: "cannot reference \(repo) by digest")
            case .malformed(let reason):
                throw Abort(.badRequest, reason: "invalid reference format: \(reason)")
            }

            // podman-only knobs, accepted on both dialects (the Docker-side
            // decoder simply never sees them). `format`: oci (default) and
            // docker both map onto the single OCI layout the store ingests —
            // podm always writes OCI, so podman's "comment needs docker
            // format" restriction doesn't apply (the comment rides the OCI
            // history entry, which is what moby does). Anything else is
            // rejected like podman's "unrecognized image format".
            if let format = query.format, !format.isEmpty, format != "oci", format != "docker" {
                throw Abort(.badRequest, reason: "unrecognized image format \"\(format)\"")
            }
            if MobyBool.queryValue(query.pause) {
                req.logger.debug(
                    "commit: pause requested and ignored — podm has no pause primitive; rootfs.ext4 is read as a volatile snapshot, the same guarantee export gives"
                )
            }
            if MobyBool.queryValue(query.squash) {
                // Satisfied by construction: the committed image is always a
                // single flattened layer.
                req.logger.debug("commit: squash requested — the committed image is a single layer by construction")
            }
            // `stream` (podman's streamed progress protocol) is ignored: the
            // response is a single JSON object either way.

            let platform = currentPlatform()
            // Best-effort parent config; nil (image deleted, config blob
            // unreadable) degrades to container-only seeding.
            let parentConfig = await imageClient.commitParentConfig(
                reference: container.configuration.image.reference,
                platform: platform
            )

            let config: SynthesizedImageConfig
            do {
                config = try ContainerCommitConfig.make(
                    container: container,
                    parent: parentConfig,
                    overrides: overrides,
                    changes: query.changes ?? []
                )
            } catch let error as DockerfileChangeError {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }

            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
            }

            // Volatile snapshot of the container's rootfs — the same file
            // `docker export` streams. The caller owns the returned file.
            let tarPath: URL
            do {
                tarPath = try await archiveClient.exportRootfs(containerId: container.id)
            } catch ClientArchiveError.rootfsNotFound {
                throw Abort(.notFound, reason: "Rootfs not found for container: \(container.id)")
            } catch ClientArchiveError.containerNotFound(let id) {
                throw Abort(.notFound, reason: "Container not found: \(id)")
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                throw Abort(.internalServerError, reason: "Error exporting container \(containerReference): \(description)")
            }
            defer { try? FileManager.default.removeItem(at: tarPath) }

            let imageReference: String?
            let digest: String
            do {
                (imageReference, digest) = try await imageClient.commitImage(
                    tarPath: tarPath,
                    repo: repo.isEmpty ? nil : repo,
                    tag: tag.isEmpty ? nil : tag,
                    comment: (query.comment?.isEmpty ?? true) ? nil : query.comment,
                    author: (query.author?.isEmpty ?? true) ? nil : query.author,
                    config: config,
                    platform: platform,
                    appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                    logger: req.logger
                )
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                throw Abort(.internalServerError, reason: "Error committing container \(containerReference): \(description)")
            }

            // moby's commit event: LogContainerEventWithAttributes with
            // comment/imageID/imageRef on top of the standard container
            // attributes (image = the PARENT image reference, name, labels).
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(
                    DockerEvent.containerEvent(
                        "commit",
                        container: container,
                        extraAttributes: [
                            "comment": query.comment ?? "",
                            "imageID": digest,
                            "imageRef": imageReference ?? "",
                        ]))
            }

            return try await RESTCommitIDResponse(Id: digest).encodeResponse(status: .created, for: req)
        }
    }
}
