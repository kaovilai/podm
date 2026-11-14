import ContainerAPIClient
import ContainerPersistence
import Vapor

/// `podman info` — the PODMAN (libpod) dialect of /info.
///
/// This must NOT reuse the Docker-dialect payload: podman's CLI unmarshals
/// the response into `define.Info`, whose `Host` and `Store` are POINTERS
/// (podman v6 libpod/define/info.go), then writes
/// `info.Host.ServiceIsRemote = remote` (cmd/podman/system/info.go:83). A
/// flat docker-style payload leaves `Host` nil, and that write is a
/// nil-pointer PANIC in the client — `podman info`, the first command anyone
/// runs for diagnostics, used to crash the CLI outright.
///
/// Values are honest: what Apple Container exposes is reported; per-host
/// statistics it does not (free memory, swap, uptime) stay zero rather than
/// invented, and podm-specific realities (rootless=false, no cgroups manager
/// at this layer, the service socket) are stated as they are.
struct LibpodInfoRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let imageClient: ClientImageProtocol
    let volumeClient: ClientVolumeProtocol

    func boot(routes: RoutesBuilder) throws {
        let containerClient = self.containerClient
        let imageClient = self.imageClient
        let volumeClient = self.volumeClient
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/info") { req in
            try await LibpodInfoRoute.handle(
                req, containerClient: containerClient, imageClient: imageClient, volumeClient: volumeClient)
        }
    }

    // MARK: - Schema types (mirror podman's libpod/define/info.go field names)

    struct Info: Content {
        let host: HostInfo
        let store: StoreInfo
        // Empty until a registries mapping is loaded — podman renders {} fine.
        let registries: [String: String]
        let plugins: Plugins
        let version: VersionInfo
    }

    struct HostInfo: Content {
        let arch: String
        let buildahVersion: String
        let cgroupManager: String
        let cgroupVersion: String
        let cgroupControllers: [String]
        let cdiSpecDirs: [String]
        let conmon: ConmonInfo
        let cpus: Int
        let databaseBackend: String
        let distribution: DistributionInfo
        let eventLogger: String
        let hostname: String
        let idMappings: IDMappings
        let kernel: String
        let logDriver: String
        let memFree: Int64
        let memAvailable: Int64
        let memTotal: Int64
        let networkBackend: String
        let ociRuntime: OCIRuntimeInfo
        let os: String
        let remoteSocket: RemoteSocket
        let rootlessNetworkCmd: String
        let runtimeInfo: [String: String]
        let serviceIsRemote: Bool
        let security: SecurityInfo
        let swapFree: Int64
        let swapTotal: Int64
        let uptime: String
        let variant: String
        let linkmode: String
    }

    struct ConmonInfo: Content {
        let package: String
        let path: String
        let version: String
    }

    struct DistributionInfo: Content {
        let distribution: String
        let version: String
    }

    struct IDMappings: Content {
        let gidmap: [String]
        let uidmap: [String]
    }

    struct OCIRuntimeInfo: Content {
        let name: String
        let package: String
        let path: String
        let version: String
    }

    struct RemoteSocket: Content {
        let path: String
        let exists: Bool
    }

    struct SecurityInfo: Content {
        let apparmorEnabled: Bool
        let capabilities: String
        let rootless: Bool
        let seccompEnabled: Bool
        let seccompProfilePath: String
        let selinuxEnabled: Bool
    }

    struct StoreInfo: Content {
        let containerStore: ContainerStore
        let imageStore: ImageStore
        let volumeStore: VolumeStore
        let graphDriver: GraphDriver
    }

    struct ContainerStore: Content {
        let number: Int
        let paused: Int
        let running: Int
        let stopped: Int
    }

    struct ImageStore: Content {
        let number: Int
    }

    struct VolumeStore: Content {
        let number: Int
    }

    struct GraphDriver: Content {
        let name: String
    }

    struct Plugins: Content {
        let volume: [String]
        let network: [String]
        let log: [String]
        let authorization: [String]
    }

    struct VersionInfo: Content {
        let APIVersion: String
        let Version: String
        let GoVersion: String
        let GitCommit: String
        /// podman's define.Version.Built is an INT64 unix timestamp (the
        /// client fails to unmarshal a string); BuiltTime carries the human
        /// form.
        let Built: Int64
        let BuiltTime: String
        let OsArch: String
        let Os: String
    }

    /// `getBuildTime()` is an RFC3339 string; podman wants Built as unix
    /// seconds. Unparseable build metadata degrades to 0, not an error.
    static func buildTimeUnixSeconds(raw: String = getBuildTime()) -> Int64 {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: raw) else { return 0 }
        return Int64(date.timeIntervalSince1970)
    }

    // MARK: - Handler

    static func handle(
        _ req: Request,
        containerClient: ClientContainerProtocol,
        imageClient: ClientImageProtocol,
        volumeClient: ClientVolumeProtocol
    ) async throws -> Response {
        do {
            let allContainers = try await containerClient.list(showAll: true, filters: [:])
            let images = try await imageClient.list()
            let volumes = try await volumeClient.list(filters: nil, logger: req.logger)

            let platform = currentPlatform()
            let home = ProcessInfo.processInfo.environment["HOME"] ?? ""

            let info = Info(
                host: HostInfo(
                    arch: platform.architecture,
                    // Not applicable to Apple Container; podman's schema has
                    // no omit — empty strings render honestly as blank.
                    buildahVersion: "",
                    cgroupManager: "",
                    cgroupVersion: "",
                    cgroupControllers: [],
                    cdiSpecDirs: [],
                    conmon: ConmonInfo(package: "", path: "", version: ""),
                    cpus: hostCPUCoreCount(),
                    databaseBackend: "apple-container",
                    distribution: DistributionInfo(distribution: "", version: ""),
                    eventLogger: "journald",
                    hostname: hostName(),
                    idMappings: IDMappings(gidmap: [], uidmap: []),
                    kernel: (try? await getLinuxDefaultKernelName()) ?? "",
                    logDriver: "k8s-file",
                    // Per-host free-memory/swap statistics aren't exposed by
                    // Apple Container — zero rather than invented values.
                    memFree: 0,
                    memAvailable: 0,
                    memTotal: Int64(hostPhysicalMemory()),
                    networkBackend: "apple-container",
                    ociRuntime: OCIRuntimeInfo(
                        name: "vminit", package: "", path: "", version: ""),
                    os: "linux",
                    remoteSocket: RemoteSocket(
                        path: containerSocketPath(homeDirectory: home), exists: true),
                    rootlessNetworkCmd: "",
                    runtimeInfo: [:],
                    // The client overwrites this from its own view; stating
                    // the truth here keeps raw-API consumers honest too.
                    serviceIsRemote: true,
                    security: SecurityInfo(
                        apparmorEnabled: false,
                        capabilities: "",
                        rootless: false,
                        seccompEnabled: true,
                        seccompProfilePath: "",
                        selinuxEnabled: false
                    ),
                    swapFree: 0,
                    swapTotal: 0,
                    uptime: "",
                    variant: "",
                    linkmode: ""
                ),
                store: StoreInfo(
                    containerStore: ContainerStore(
                        number: allContainers.count,
                        paused: 0,
                        running: allContainers.filter { $0.status == .running }.count,
                        stopped: allContainers.filter { $0.status == .stopped }.count
                    ),
                    imageStore: ImageStore(number: images.count),
                    volumeStore: VolumeStore(number: volumes.count),
                    graphDriver: GraphDriver(name: "apple-container")
                ),
                registries: [:],
                plugins: Plugins(volume: [], network: [], log: [], authorization: []),
                version: VersionInfo(
                    APIVersion: "5.0.0",
                    Version: getBuildVersion(),
                    GoVersion: "",
                    GitCommit: getBuildGitCommit(),
                    Built: LibpodInfoRoute.buildTimeUnixSeconds(),
                    BuiltTime: getBuildTime(),
                    OsArch: "linux/\(platform.architecture)",
                    Os: "linux"
                )
            )
            return try await info.encodeResponse(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.error("LibpodInfoRoute handler failed: \(error)")
            let response = Response(status: .internalServerError)
            response.headers.add(name: .contentType, value: "application/json")
            response.body = .init(string: "{\"message\": \"Failed to generate system information\"}\n")
            return response
        }
    }
}
