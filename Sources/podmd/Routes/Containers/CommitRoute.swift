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
/// than rejected. `StopSignal`/`Healthcheck` carry moby's exact JSON keys
/// (`StopSignal` string; `Healthcheck` with Test/Interval/Timeout/
/// StartPeriod/Retries — and Docker 25+ StartInterval).
struct RESTCommitConfig: Content {
    let User: String?
    let ExposedPorts: [String: EmptyObject]?
    let Env: [String]?
    let Entrypoint: [String]?
    let Cmd: [String]?
    let Volumes: [String: EmptyObject]?
    let WorkingDir: String?
    let Labels: [String: String]?
    let StopSignal: String?
    let Healthcheck: HealthcheckConfig?

    func overrides() -> CommitConfigOverrides {
        CommitConfigOverrides(
            user: User,
            exposedPorts: ExposedPorts.map { Set($0.keys) },
            env: Env,
            entrypoint: Entrypoint,
            cmd: Cmd,
            volumes: Volumes.map { Set($0.keys) },
            workingDir: WorkingDir,
            labels: Labels,
            stopSignal: StopSignal,
            healthcheck: Healthcheck
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

    /// Default arguments exist only so tests and the route-conformance probe
    /// can construct the collection without wiring the daemon's clients — a
    /// probe never gets past the container lookup. The real registration in
    /// `RouteRegistry` passes the daemon's actual clients, so this default
    /// path is never exercised in production.
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
            // Content-Type doesn't reject an otherwise valid body. The body
            // is AWAITED with the configured cap — `collect()` with no max
            // silently caps at Vapor's 16 KB default, and discarding the
            // future would race a streamed body (the Config overrides would
            // read as nil before collection finishes); the RegexRouter
            // bypasses the defaultMaxBodySize collection Vapor's registered
            // routes do, so the cap must be passed explicitly (same pattern
            // as `ContainerCreateRoute`).
            let overrides: CommitConfigOverrides?
            if let bodyData = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get(),
                bodyData.readableBytes > 0
            {
                // docker CLI v20.10.7 sends a literal JSON `null` for a nil
                // Config — that is "no body" semantically (moby's
                // CheckForJSON yields an empty config there), not a 400.
                let trimmed =
                    String(data: Data(buffer: bodyData), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed == "null" {
                    overrides = nil
                } else {
                    let restConfig: RESTCommitConfig
                    do {
                        restConfig = try JSONDecoder().decode(RESTCommitConfig.self, from: Data(buffer: bodyData))
                    } catch {
                        throw Abort(.badRequest, reason: "invalid commit config body: \(error.localizedDescription)")
                    }
                    overrides = restConfig.overrides()
                }
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
            // `stream` (podman's streamed progress protocol) is a no-op for
            // the Docker-compat dialect — the response is a single JSON
            // object. The libpod twin (LibpodCommitRoute) re-frames it into
            // podman's BuildResponse record stream when the client asks for
            // it.

            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
            }

            // The CONTAINER's platform, not the host's: create persists the
            // requested platform (amd64 containers run under Rosetta), and
            // the committed image must label its filesystem with that
            // architecture — an amd64 rootfs labeled arm64 could not exec its
            // own binaries. Defaults to the host platform for containers
            // created before the field existed.
            let platform = container.configuration.platform

            // Best-effort parent config, resolved by DIGEST — the tag may
            // have been re-pulled or retagged since the container was
            // created, but the digest the container was created from
            // addresses immutable content. nil (image pruned, blob
            // unreadable) degrades to container-only seeding.
            let parentConfig = await imageClient.commitParentConfig(
                digest: container.configuration.image.descriptor.digest,
                platform: platform,
                appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                logger: req.logger
            )

            let config: SynthesizedImageConfig
            do {
                config = try ContainerCommitConfig.make(
                    container: container,
                    parent: parentConfig?.config,
                    parentExposedPorts: parentConfig?.exposedPorts ?? [],
                    parentVolumes: parentConfig?.volumes ?? [],
                    overrides: overrides,
                    changes: query.changes ?? []
                )
            } catch let error as DockerfileChangeError {
                throw Abort(.badRequest, reason: error.localizedDescription)
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
