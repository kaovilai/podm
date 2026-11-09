import ContainerPersistence
import ContainerizationError
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import pacmand

/// Route-level coverage for `POST /libpod/images/{name}/untag` (`podman untag`) via a fake
/// `ImageUntagStore` — no XPC dependency. Exercises the HTTP layer: the repo/tag "parameter
/// dance", reference resolution (raw vs normalized storage), single-reference deletion
/// without touching the image's other references, and error statuses.
@Suite("LibpodImageUntagRoute")
struct LibpodImageUntagRouteTests {
    // MARK: - Fake untag store

    /// In-memory stand-in for Apple Container's image persistence layer. Every tag of an
    /// image is its own reference row (as in the real store), so `delete(reference:)`
    /// removing one row while `alive` keeps the rest models exactly what untag must do.
    final class FakeUntagStore: ImageUntagStore, @unchecked Sendable {
        let storedReference: String
        let digest: String
        private(set) var deleted: [String] = []
        private var alive: [String]
        var resolveError: Error?

        init(reference: String, digest: String = "sha256:abc123", otherReferences: [String] = []) {
            self.storedReference = reference
            self.digest = digest
            self.alive = [reference] + otherReferences
        }

        func resolve(name: String, systemConfig: ContainerSystemConfig) async throws -> (reference: String, digest: String) {
            if let resolveError { throw resolveError }
            return (storedReference, digest)
        }

        func references(forDigest digest: String) async throws -> [String] {
            digest == self.digest ? alive : []
        }

        func delete(reference: String) async throws {
            deleted.append(reference)
            alive.removeAll { $0 == reference }
        }

        var aliveReferences: [String] { alive }
    }

    // MARK: - Happy paths

    @Test("repo+tag removes exactly that reference, keeping the image's other tags")
    func untagOneReference() async throws {
        let store = FakeUntagStore(
            reference: "docker.io/library/myimg:v1",
            otherReferences: ["docker.io/library/myimg:v2"])

        try await withUntagApp(store: store) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/images/myimg/untag?repo=myimg&tag=v1") { res async throws in
                #expect(res.status == .created)
            }
        }
        #expect(store.deleted == ["docker.io/library/myimg:v1"])
        #expect(store.aliveReferences == ["docker.io/library/myimg:v2"])
    }

    @Test("repo without tag defaults the tag to latest, matching podman's parameter dance")
    func untagDefaultsToLatest() async throws {
        let store = FakeUntagStore(reference: "docker.io/library/myimg:latest")

        try await withUntagApp(store: store) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/images/myimg/untag?repo=myimg") { res async throws in
                #expect(res.status == .created)
            }
        }
        #expect(store.deleted == ["docker.io/library/myimg:latest"])
    }

    @Test("a bare (non-normalized) stored reference is matched by its raw spelling")
    func untagBareStoredReference() async throws {
        // Locally-built images can be tagged verbatim without a registry/library prefix;
        // the raw-or-normalized match must find them (same resolution the delete route
        // performs via ClientImage.get before deleting).
        let store = FakeUntagStore(reference: "myimg:v1", otherReferences: ["myimg:v2"])

        try await withUntagApp(store: store) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/images/myimg/untag?repo=myimg&tag=v1") { res async throws in
                #expect(res.status == .created)
            }
        }
        #expect(store.deleted == ["myimg:v1"])
        #expect(store.aliveReferences == ["myimg:v2"])
    }

    @Test("neither repo nor tag removes every reference of the image, like podman untag <image>")
    func untagAllReferences() async throws {
        let store = FakeUntagStore(
            reference: "docker.io/library/myimg:v1",
            otherReferences: ["docker.io/library/myimg:v2", "registry.example.com/other:latest"])

        try await withUntagApp(store: store) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/images/myimg/untag") { res async throws in
                #expect(res.status == .created)
            }
        }
        #expect(Set(store.deleted) == Set(["docker.io/library/myimg:v1", "docker.io/library/myimg:v2", "registry.example.com/other:latest"]))
        #expect(store.aliveReferences.isEmpty)
    }

    // MARK: - Errors

    @Test("tag without repo is a 400, matching podman's own parameter dance")
    func tagWithoutRepoIs400() async throws {
        let store = FakeUntagStore(reference: "docker.io/library/myimg:v1")

        try await withUntagApp(store: store) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/images/myimg/untag?tag=v1") { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("repo parameter is required"))
            }
        }
        #expect(store.deleted.isEmpty)
    }

    @Test("an unknown image is a 404")
    func unknownImageIs404() async throws {
        let store = FakeUntagStore(reference: "docker.io/library/myimg:v1")
        store.resolveError = ContainerizationError(.notFound, message: "image with reference ghost:latest")

        try await withUntagApp(store: store) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/images/ghost/untag?repo=ghost&tag=v1") { res async throws in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("No such image"))
            }
        }
        #expect(store.deleted.isEmpty)
    }

    @Test("a tag that belongs to a different image (or no image) is a 404, not a silent no-op")
    func unknownTagIs404() async throws {
        let store = FakeUntagStore(reference: "docker.io/library/myimg:v1")

        try await withUntagApp(store: store) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/images/myimg/untag?repo=myimg&tag=doesnotexist") { res async throws in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("is not a tag of"))
            }
        }
        #expect(store.deleted.isEmpty)
    }

    @Test("a digest-pinned untag target is a 400, matching libimage's errUntagDigest")
    func digestTargetIs400() async throws {
        let store = FakeUntagStore(reference: "docker.io/library/myimg:v1")

        try await withUntagApp(store: store) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/images/myimg/untag?repo=sha256:aaa&tag=blob") { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("cannot untag a digest reference"))
            }
        }
        #expect(store.deleted.isEmpty)
    }

    // MARK: - Helper

    private func withUntagApp(store: ImageUntagStore, test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodImageUntagRoute(systemConfig: ContainerSystemConfig(), store: store))
            try await test(app)
        }
    }
}
