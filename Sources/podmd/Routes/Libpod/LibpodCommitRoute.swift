import ContainerAPIClient
import ContainerPersistence
import Foundation
import Vapor

/// libpod twin of `POST /commit` (podman's `CommitContainer` handler). Same
/// handler and body; only the response status differs — podman writes
/// `http.StatusOK` with `{"Id": ...}` where Docker compat answers moby's 201.
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
            return response
        }
    }
}
