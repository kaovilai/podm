import ContainerAPIClient
import ContainerBuild
import ContainerResource
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `GET /libpod/system/df` — `podman system df` / `podman system df -v`.
/// podman's remote client decodes this endpoint into `entities.SystemDfReport`
/// (per-item rows, `ContainerID`/`RWSize`/`Command []string`/`Created` as
/// time.Time). Before this route mapped the shape, the docker-dialect response
/// was a hard decode error on podman's side (`Time.UnmarshalJSON: input is
/// not a JSON string`).
@Suite("LibpodSystemDFRoute")
struct LibpodSystemDFRouteTests {

    // MARK: - Mocks (same shape as SystemDFRouteTests' private fixtures)

    private struct EmptyImageClient: ClientImageProtocol {
        func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
        func delete(id: String) async throws -> ImageDeletionResult { fatalError("not exercised by this test") }
        func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func pushManifestList(reference: String, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
            ([], 0)
        }
        func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
        func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
            URL(fileURLWithPath: "/dev/null")
        }
        func importImage(
            tarPath: URL, repo: String?, tag: String?, message: String?, changes: [String], platform: Platform,
            appleContainerAppSupportUrl: URL, logger: Logger
        ) async throws -> (reference: String?, digest: String) { fatalError("not exercised by this test") }
    }

    private struct EmptyVolumeClient: ClientVolumeProtocol {
        func create(request: RESTVolumeCreate) async throws -> Volume { fatalError("not exercised by this test") }
        func delete(name: String) async throws {}
        func list(filters: String?, logger: Logger) async throws -> [Volume] { [] }
        func inspect(name: String) async throws -> Volume { fatalError("not exercised by this test") }
    }

    private struct EmptyBuilderClient: ClientBuilderProtocol {
        func ensureReachable(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logging.Logger) async throws {}
        func connect(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logging.Logger) async throws -> Builder {
            fatalError("not exercised when the default (includeAll) query builds an empty BuildCache")
        }
        func prune(_ request: BuilderPruneRequest, logger: Logging.Logger) async throws -> BuilderPruneResult {
            fatalError("not exercised by this test")
        }
        func diskUsage(logger: Logging.Logger) async throws -> [BuilderCacheRecord] {
            fatalError("not exercised when the default (includeAll) query builds an empty BuildCache")
        }
    }

    private struct FixedDiskUsageProvider: ContainerDiskUsageProviding {
        let bytes: UInt64
        func diskUsage(id: String) async throws -> UInt64 { bytes }
    }

    private struct FixedImageLayerDiskUsageProvider: ImageLayerDiskUsageProviding {
        let totalSize: UInt64
        func calculateDiskUsage(activeReferences: Set<String>) async throws -> (
            totalCount: Int, activeCount: Int, totalSize: UInt64, reclaimableSize: UInt64
        ) {
            (0, 0, totalSize, 0)
        }
    }

    // MARK: - HTTP

    /// A snapshot with one volume mount, so the report's LocalVolumes count
    /// is exercised (podman counts the container's named volumes there).
    private func makeSnapshotWithVolumeMount() throws -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: ["-c", "sleep 600"], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "docker.io/library/busybox:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:abc", size: 0
            )
        )
        var config = ContainerConfiguration(id: "df-ctr", image: img, process: proc)
        config.mounts = [
            Filesystem.volume(
                name: "data-vol", format: "ext4", source: "data-vol", destination: "/data", options: [])
        ]
        return ContainerSnapshot(configuration: config, status: .stopped, networks: [])
    }

    @Test("podman system df decodes: per-item rows, RFC3339 times, sizes from the diskUsage seam")
    func libpodSystemDfShape() async throws {
        let snapshot = try makeSnapshotWithVolumeMount()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            try app.register(
                collection: LibpodSystemDFRoute(
                    dockerRoute: SystemDFRoute(
                        imageClient: EmptyImageClient(),
                        containerClient: StaticSnapshotClientMock(snapshot: snapshot),
                        volumeClient: EmptyVolumeClient(),
                        builderClient: EmptyBuilderClient(),
                        diskUsageProvider: FixedDiskUsageProvider(bytes: 4096),
                        imageLayerDiskUsageProvider: FixedImageLayerDiskUsageProvider(totalSize: 619_528_192)
                    )))

            try await app.testing().test(.GET, "/v1.51/libpod/system/df") { res async throws in
                #expect(res.status == .ok)
                let report = try res.content.decode(LibpodSystemDfReport.self)

                // ImagesSize mirrors podman's ImagesSize (all layer bytes).
                #expect(report.ImagesSize == 619_528_192)
                #expect(report.Images.isEmpty)
                #expect(report.Volumes.isEmpty)

                // Container row: podman's SystemDfContainerReport field names.
                let container = try #require(report.Containers.first)
                #expect(container.ContainerID == DockerContainerID.hexId(for: snapshot))
                #expect(container.Image == "sha256:abc")
                // The original argv survives: splitting the docker dialect's
                // space-joined display string would turn "sleep 600" into two
                // arguments and lose the -c boundary.
                #expect(container.Command == ["/bin/sh", "-c", "sleep 600"])
                #expect(container.LocalVolumes == 1)
                #expect(container.Size == 4096)
                #expect(container.RWSize == 4096)
                #expect(container.Status == "exited")
                #expect(container.Names == "df-ctr")
                // podman decodes Created as time.Time — a unix int is a hard
                // decode error, so it must be an RFC3339 string. (The shared
                // resolver emits fractional seconds, which Go's RFC3339
                // parser accepts; a bare ISO8601DateFormatter would not.)
                let rfc3339 = ISO8601DateFormatter()
                rfc3339.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                #expect(rfc3339.date(from: container.Created) != nil)
            }
        }
    }

    // MARK: - Row mapping (pure functions)

    @Test("Image row: repository/tag split survives registry ports; untagged reports <none>")
    func imageReportRepositoryTagSplit() throws {
        let tagged = LibpodSystemDfImageReport.from(
            RESTImageSummary(
                Id: "sha256:a46257e06c82", ParentId: "", RepoTags: ["localhost:5000/foo/bar:v1.2"],
                RepoDigests: [], Created: 1_777_000_000, Size: 1_921_355, SharedSize: 0,
                Labels: [:], Containers: 1, Manifests: nil, Descriptor: nil))
        #expect(tagged.Repository == "localhost:5000/foo/bar")
        #expect(tagged.Tag == "v1.2")
        #expect(tagged.ImageID == "sha256:a46257e06c82")
        #expect(tagged.Size == 1_921_355)
        // Apple exposes no layer-sharing accounting: everything is unique.
        #expect(tagged.SharedSize == 0)
        #expect(tagged.UniqueSize == 1_921_355)
        #expect(tagged.Containers == 1)
        let rfc3339 = ISO8601DateFormatter()
        rfc3339.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(rfc3339.date(from: tagged.Created) != nil)

        let untagged = LibpodSystemDfImageReport.from(
            RESTImageSummary(
                Id: "sha256:untagged", ParentId: "", RepoTags: [], RepoDigests: ["sha256:untagged"],
                Created: 0, Size: 100, SharedSize: 0, Labels: [:], Containers: 0,
                Manifests: nil, Descriptor: nil))
        #expect(untagged.Repository == "<none>")
        #expect(untagged.Tag == "<none>")
    }

    @Test("Volume row: unused volumes are fully reclaimable, attached ones are not")
    func volumeReportReclaimable() throws {
        let unused = Volume(
            Name: "unused-vol", Driver: "local", Mountpoint: "/volumes/unused-vol", CreatedAt: nil,
            Status: nil, Labels: nil, Scope: "local", ClusterVolume: nil, Options: [:],
            UsageData: VolumeUsageData(Size: 4096, RefCount: 0))
        let attached = Volume(
            Name: "attached-vol", Driver: "local", Mountpoint: "/volumes/attached-vol", CreatedAt: nil,
            Status: nil, Labels: nil, Scope: "local", ClusterVolume: nil, Options: [:],
            UsageData: VolumeUsageData(Size: 8192, RefCount: 1))

        #expect(LibpodSystemDfVolumeReport.from(unused).ReclaimableSize == 4096)
        #expect(LibpodSystemDfVolumeReport.from(attached).ReclaimableSize == 0)
        #expect(LibpodSystemDfVolumeReport.from(attached).Links == 1)
        #expect(LibpodSystemDfVolumeReport.from(attached).VolumeName == "attached-vol")
    }

    @Test("Container row: docker names lose their leading slash; LocalVolumes counts volume mounts only")
    func containerReportNamesAndVolumes() throws {
        // CommandArgv nil (a summary built without argv): the display string
        // is split as a fallback.
        let summary = RESTContainerSummary(
            Id: "0571d714e6ce", Names: ["/df-test"], Image: "docker.io/library/busybox:latest",
            ImageID: "sha256:a46257e06c82", ImageManifestDescriptor: nil, Command: "sleep 600",
            Created: 1_777_000_000, StartedAtUnix: nil, ExitCode: nil, ExitedAtUnix: nil, Ports: [],
            SizeRw: 4096, SizeRootFs: 4096, Labels: [:], State: "exited", Status: "exited",
            HostConfig: ContainerHostConfig(NetworkMode: "default", Annotations: nil),
            NetworkSettings: ContainerNetworkSummary(Networks: nil),
            Mounts: [
                ContainerMountPoint(
                    type: "volume", name: "data", source: "/volumes/data", destination: "/data",
                    driver: "local", mode: "rw", rw: true, propagation: ""),
                ContainerMountPoint(
                    type: "bind", name: nil, source: "/host/path", destination: "/host",
                    driver: nil, mode: "rw", rw: true, propagation: ""),
            ],
            Platform: "linux")
        let row = LibpodSystemDfContainerReport.from(summary)
        #expect(row.Names == "df-test")
        #expect(row.LocalVolumes == 1)
        #expect(row.Command == ["sleep", "600"])
    }

    @Test("Container row: the original argv is carried through, preserving argument boundaries")
    func containerReportCommandArgv() throws {
        // ["/bin/sh", "-c", "sleep 600"] joined for display as one string —
        // the libpod Command must keep the real argv, including the argument
        // containing a space, and empty arguments.
        var summary = RESTContainerSummary(
            Id: "0571d714e6ce", Names: ["/df-test"], Image: "busybox", ImageID: "sha256:abc",
            ImageManifestDescriptor: nil, Command: "/bin/sh -c sleep 600",
            Created: 1_777_000_000, StartedAtUnix: nil, ExitCode: nil, ExitedAtUnix: nil, Ports: [],
            SizeRw: 0, SizeRootFs: 0, Labels: [:], State: "exited", Status: "exited",
            HostConfig: ContainerHostConfig(NetworkMode: "default", Annotations: nil),
            NetworkSettings: ContainerNetworkSummary(Networks: nil),
            Mounts: [], Platform: "linux")
        summary.CommandArgv = ["/bin/sh", "-c", "sleep 600", ""]
        #expect(LibpodSystemDfContainerReport.from(summary).Command == ["/bin/sh", "-c", "sleep 600", ""])
    }

    @Test("Image row: a registry port without a tag is the whole repository, not a bogus split")
    func imageReportRegistryPortWithoutTag() throws {
        let untagged = LibpodSystemDfImageReport.from(
            RESTImageSummary(
                Id: "sha256:portonly", ParentId: "", RepoTags: ["localhost:5000/foo"],
                RepoDigests: [], Created: 0, Size: 100, SharedSize: 0, Labels: [:], Containers: 0,
                Manifests: nil, Descriptor: nil))
        // The last colon belongs to the registry port, not a tag separator:
        // the entry is the repository and the tag reports <none>.
        #expect(untagged.Repository == "localhost:5000/foo")
        #expect(untagged.Tag == "<none>")

        // A real tag after a registry port still splits correctly.
        let tagged = LibpodSystemDfImageReport.from(
            RESTImageSummary(
                Id: "sha256:porttag", ParentId: "", RepoTags: ["localhost:5000/foo:v1.2"],
                RepoDigests: [], Created: 0, Size: 100, SharedSize: 0, Labels: [:], Containers: 0,
                Manifests: nil, Descriptor: nil))
        #expect(tagged.Repository == "localhost:5000/foo")
        #expect(tagged.Tag == "v1.2")
    }
}
