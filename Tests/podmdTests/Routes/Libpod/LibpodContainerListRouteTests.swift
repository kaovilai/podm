import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `GET /libpod/containers/json` — `podman ps`. Size coverage: podman's
/// `entities.ListContainer` carries sizes as a nested
/// `Size *define.ContainerSize` ({"rootFsSize", "rwSize"}), not Docker's
/// flat SizeRw/SizeRootFs, so `podman ps -s` decoded zero from the
/// docker-shaped summary before this mapping existed.
@Suite("LibpodContainerListRoute")
struct LibpodContainerListRouteTests {

    private struct FixedDiskUsageProvider: ContainerDiskUsageProviding {
        let bytes: UInt64
        func diskUsage(id: String) async throws -> UInt64 { bytes }
    }

    private func withRoute(
        client: ClientContainerProtocol,
        diskUsageProvider: ContainerDiskUsageProviding,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            try app.register(
                collection: LibpodContainerListRoute(
                    client: client, diskUsageProvider: diskUsageProvider))
            try await test(app)
        }
    }

    @Test("?size=1 maps the summary's SizeRootFs into podman's nested Size object")
    func sizeParamPopulatesNestedSize() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "c1", networks: [], labels: [:], status: .stopped)
        let provider = FixedDiskUsageProvider(bytes: 8192)
        try await withRoute(client: StaticSnapshotClientMock(snapshot: snapshot), diskUsageProvider: provider) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/json?size=1&all=1") { res async throws in
                #expect(res.status == .ok)
                let containers = try res.content.decode([LibpodListContainer].self)
                #expect(containers.count == 1)
                // podman's define.ContainerSize: rootFsSize carries Apple's
                // aggregate figure (mapped to SizeRootFs on the docker summary);
                // rwSize stays 0 because Apple exposes no rw-vs-rootfs split.
                #expect(containers.first?.Size?.rootFsSize == 8192)
                #expect(containers.first?.Size?.rwSize == 0)
            }
        }
    }

    @Test("Without the size param the nested Size object is omitted, matching podman")
    func noSizeParamOmitsSizeObject() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "c1", networks: [], labels: [:], status: .stopped)
        let provider = FixedDiskUsageProvider(bytes: 8192)
        try await withRoute(client: StaticSnapshotClientMock(snapshot: snapshot), diskUsageProvider: provider) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/json?all=1") { res async throws in
                #expect(res.status == .ok)
                let containers = try res.content.decode([LibpodListContainer].self)
                // podman's own handler only populates Size when size=true; a
                // JSON null here would decode into a non-nil check mismatch,
                // so assert the key is absent rather than null.
                #expect(containers.first?.Size == nil)
            }
        }
    }

    @Test("A disk-usage lookup failure omits the size instead of failing the listing")
    func failedLookupOmitsSize() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "c1", networks: [], labels: [:], status: .stopped)
        struct FailingProvider: ContainerDiskUsageProviding {
            func diskUsage(id: String) async throws -> UInt64 {
                throw Abort(.internalServerError, reason: "simulated lookup failure")
            }
        }
        try await withRoute(client: StaticSnapshotClientMock(snapshot: snapshot), diskUsageProvider: FailingProvider()) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/json?size=1&all=1") { res async throws in
                #expect(res.status == .ok)
                let containers = try res.content.decode([LibpodListContainer].self)
                #expect(containers.first?.Size == nil)
            }
        }
    }
}
