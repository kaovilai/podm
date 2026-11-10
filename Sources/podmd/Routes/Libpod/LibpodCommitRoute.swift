import ContainerAPIClient
import ContainerPersistence
import Foundation
import Vapor

/// libpod twin of `POST /commit` (podman's `CommitContainer` handler). Same
/// handler and body; only the response differs — podman writes
/// `http.StatusOK` where Docker compat answers moby's 201, and podman's
/// `stream=true` protocol needs `images.BuildResponse` record framing (see
/// `rewriteAsBuildStream`).
struct LibpodCommitRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let archiveClient: ClientArchiveProtocol
    let imageClient: ClientImageCommitProtocol

    /// Same default-argument bridge as `CommitRoute` — see the note there.
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
        let dockerHandler = CommitRoute.handler(
            containerClient: containerClient, archiveClient: archiveClient, imageClient: imageClient)
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/commit") { req in
            let response = try await dockerHandler(req)
            // podman's CommitContainer answers 200, not moby's 201.
            response.status = .ok
            // podman's client (pkg/bindings/containers.Commit) prefixes its
            // request path with /v<api>/libpod, so this is the endpoint it
            // hits — and with stream=true it decodes newline-delimited
            // images.BuildResponse records, rejecting a plain {"Id": ...}
            // body ("failed to parse build results stream, unexpected
            // input"). Without the parameter (or with stream=false) it
            // decodes the plain IDResponse body, which is what the shared
            // handler already produced.
            if MobyBool.queryValue(req.query["stream"] as String?) {
                try Self.rewriteAsBuildStream(response)
            }
            return response
        }
    }

    /// One record of podman's streamed commit/build protocol —
    /// `images.BuildResponse`. Only `stream` is ever set: podman's client
    /// scans it for the committed image's bare hex ID (its `iidRegex`
    /// requires twelve leading hex characters, so the digest's `sha256:`
    /// algorithm prefix must not ride along) and prints it as progress
    /// output before returning it as the commit result.
    private struct LibpodCommitBuildResponse: Content {
        let stream: String
    }

    /// Re-frames a finished commit's plain `{"Id": ...}` body as the
    /// single-record build stream podman's client expects from
    /// `stream=true`: podman's own handler muxes buildah's stdout into
    /// `stream` records and terminates with the image ID — a synchronous
    /// commit therefore produces exactly one record, newline-terminated the
    /// way Go's `json.Encoder` (which the handler writes through) does.
    private static func rewriteAsBuildStream(_ response: Response) throws {
        guard let buffer = response.body.buffer,
            let id = try? JSONDecoder().decode(RESTCommitIDResponse.self, from: Data(buffer: buffer)).Id
        else {
            throw Abort(.internalServerError, reason: "commit stream rewrite: undecodable response body")
        }
        // Strip the digest's algorithm prefix — podman's IDs are bare hex.
        let hexId =
            id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init)
            ?? id
        var data = try JSONEncoder().encode(LibpodCommitBuildResponse(stream: hexId))
        data.append(0x0A)
        response.body = .init(data: data)
        response.headers.replaceOrAdd(name: .contentType, value: "application/json")
        response.headers.replaceOrAdd(name: .contentLength, value: String(data.count))
    }
}
