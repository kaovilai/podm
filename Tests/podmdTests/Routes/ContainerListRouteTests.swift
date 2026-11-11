import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

private struct MockContainerClient: ClientContainerProtocol {
    let containers: [ContainerSnapshot]

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { containers }
    func getContainer(id: String) async throws -> ContainerSnapshot? { containers.first { $0.id == id } }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private func makeRunningSnapshot(id: String, networks: [ContainerResource.Attachment]) -> ContainerSnapshot {
    let processConfig = ProcessConfiguration(
        executable: "/bin/sh",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )
    let imageDesc = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
    )
    let config = ContainerConfiguration(id: id, image: imageDesc, process: processConfig)
    return ContainerSnapshot(
        configuration: config,
        status: .running,
        networks: networks,
        startedDate: Date(timeIntervalSinceNow: -30)
    )
}

@Suite("ContainerListRoute network settings")
struct ContainerListRouteNetworkSettingsTests {

    private func withRoute(
        container: ContainerSnapshot,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            let client = MockContainerClient(containers: [container])
            try app.register(collection: ContainerListRoute(client: client))
            try await test(app)
        }
    }

    @Test("A running container with an IPv6 attachment lists GlobalIPv6Address and prefix length")
    func listReportsIPv6Attachment() async throws {
        let attachment = try ContainerResource.Attachment(
            network: "mynet",
            hostname: "c1",
            ipv4Address: CIDRv4("192.168.64.5/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Address: CIDRv6("fd18:2f24:9eff:1:1c1e:56ff:fe7c:1a2b/64"),
            macAddress: nil
        )
        let container = makeRunningSnapshot(id: "c1", networks: [attachment])
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async throws in
                let summaries = try res.content.decode([RESTContainerSummary].self)
                let endpoint = summaries.first?.NetworkSettings.Networks?["mynet"]
                #expect(endpoint?.IPAddress == "192.168.64.5")
                #expect(endpoint?.IPPrefixLen == 24)
                #expect(endpoint?.GlobalIPv6Address == "fd18:2f24:9eff:1:1c1e:56ff:fe7c:1a2b")
                #expect(endpoint?.GlobalIPv6PrefixLen == 64)
                #expect(endpoint?.IPv6Gateway == nil)
            }
        }
    }

    @Test("A running container without an IPv6 attachment lists no IPv6 fields")
    func listReportsNoIPv6ForIPv4OnlyAttachment() async throws {
        let attachment = try ContainerResource.Attachment(
            network: "mynet",
            hostname: "c1",
            ipv4Address: CIDRv4("192.168.64.5/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        let container = makeRunningSnapshot(id: "c1", networks: [attachment])
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async throws in
                let summaries = try res.content.decode([RESTContainerSummary].self)
                let endpoint = summaries.first?.NetworkSettings.Networks?["mynet"]
                #expect(endpoint?.GlobalIPv6Address == nil)
                #expect(endpoint?.GlobalIPv6PrefixLen == nil)
            }
        }
    }

    @Test("Duplicate live network names do not crash list")
    func duplicateLiveNetworkNamesDoNotCrash() async throws {
        let attachment = try ContainerResource.Attachment(
            network: "dup",
            hostname: "c1",
            ipv4Address: CIDRv4("192.168.64.5/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        let container = makeRunningSnapshot(id: "c1", networks: [attachment, attachment])
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async throws in
                let summaries = try res.content.decode([RESTContainerSummary].self)
                #expect(summaries.first?.NetworkSettings.Networks?.keys.contains("dup") == true)
            }
        }
    }
}

/// Scripted per-container disk usage for the size-reporting suites: fixed byte
/// counts by native id, with opt-in simulated lookup failures.
private struct ScriptedDiskUsageProvider: ContainerDiskUsageProviding {
    let bytesById: [String: UInt64]
    var failingIds: Set<String> = []

    func diskUsage(id: String) async throws -> UInt64 {
        if failingIds.contains(id) {
            throw Abort(.internalServerError, reason: "simulated disk usage lookup failure")
        }
        return bytesById[id] ?? 0
    }
}

@Suite("ContainerListRoute size reporting")
struct ContainerListRouteSizeTests {

    private func withRoute(
        containers: [ContainerSnapshot],
        diskUsageProvider: ContainerDiskUsageProviding,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            let client = MockContainerClient(containers: containers)
            try app.register(
                collection: ContainerListRoute(client: client, diskUsageProvider: diskUsageProvider))
            try await test(app)
        }
    }

    @Test("?size=1 reports Apple's aggregate usage as SizeRootFs and omits SizeRw")
    func sizeParamPopulatesSizeRootFs() async throws {
        let containers = [
            makeRunningSnapshot(id: "c1", networks: []),
            makeRunningSnapshot(id: "c2", networks: []),
        ]
        let provider = ScriptedDiskUsageProvider(bytesById: ["c1": 4096, "c2": 1_048_576])
        try await withRoute(containers: containers, diskUsageProvider: provider) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json?size=1") { res async throws in
                let summaries = try res.content.decode([RESTContainerSummary].self)
                let byName = Dictionary(uniqueKeysWithValues: summaries.map { ($0.Names.first ?? "", $0) })
                #expect(byName["/c1"]?.SizeRootFs == 4096)
                #expect(byName["/c2"]?.SizeRootFs == 1_048_576)
                // Apple exposes one aggregate figure, not Docker's rw/rootfs
                // split — SizeRw stays omitted rather than duplicating it.
                #expect(byName["/c1"]?.SizeRw == nil)
                #expect(byName["/c2"]?.SizeRw == nil)
            }
        }
    }

    @Test("Without the size param both size fields stay omitted")
    func noSizeParamOmitsSizes() async throws {
        let container = makeRunningSnapshot(id: "c1", networks: [])
        let provider = ScriptedDiskUsageProvider(bytesById: ["c1": 4096])
        try await withRoute(containers: [container], diskUsageProvider: provider) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async throws in
                let summaries = try res.content.decode([RESTContainerSummary].self)
                #expect(summaries.first?.SizeRootFs == nil)
                #expect(summaries.first?.SizeRw == nil)
            }
        }
    }

    @Test("size=false behaves like no size param")
    func sizeFalseOmitsSizes() async throws {
        let container = makeRunningSnapshot(id: "c1", networks: [])
        let provider = ScriptedDiskUsageProvider(bytesById: ["c1": 4096])
        try await withRoute(containers: [container], diskUsageProvider: provider) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json?size=false") { res async throws in
                let summaries = try res.content.decode([RESTContainerSummary].self)
                #expect(summaries.first?.SizeRootFs == nil)
                #expect(summaries.first?.SizeRw == nil)
            }
        }
    }

    @Test("A failed usage lookup skips that container's size instead of failing the listing")
    func failedLookupKeepsListing() async throws {
        let containers = [
            makeRunningSnapshot(id: "c1", networks: []),
            makeRunningSnapshot(id: "c2", networks: []),
        ]
        let provider = ScriptedDiskUsageProvider(bytesById: ["c1": 4096], failingIds: ["c2"])
        try await withRoute(containers: containers, diskUsageProvider: provider) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json?size=1") { res async throws in
                #expect(res.status == .ok)
                let summaries = try res.content.decode([RESTContainerSummary].self)
                let byName = Dictionary(uniqueKeysWithValues: summaries.map { ($0.Names.first ?? "", $0) })
                #expect(byName["/c1"]?.SizeRootFs == 4096)
                #expect(byName["/c2"]?.SizeRootFs == nil)
            }
        }
    }
}
