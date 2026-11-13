import ContainerAPIClient
import ContainerBuild
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import NIO
import Vapor

struct BuilderPruneRequest: Sendable {
    let all: Bool
    let filters: [String: [String]]
    let keepStorage: Int64?
    let reservedSpace: Int64?
    let maxUsedSpace: Int64?
    let minFreeSpace: Int64?
}

struct BuilderPruneResult: Sendable {
    let deletedCaches: [String]
    let spaceReclaimed: Int64
}

struct BuilderCacheRecord: Sendable {
    let id: String
    let parents: [String]
    let kind: String
    let description: String
    let inUse: Bool
    let shared: Bool
    let size: Int64
    let createdAt: String
    let lastUsedAt: String?
    let usageCount: Int
}

protocol ClientBuilderProtocol: Sendable {
    /// Verify the builder is reachable (starting it if necessary).
    /// Pass `qemu: true` when the build requires platforms other than arm64/amd64
    /// (e.g. s390x, ppc64le) so that a QEMU-enabled builder container is used.
    func ensureReachable(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logger) async throws
    /// Connect to the builder, starting it if necessary.
    /// Pass `qemu: true` when the build requires platforms other than arm64/amd64.
    func connect(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logger) async throws -> Builder
    /// Size-aware variants: `requested` carries the build's explicit
    /// --memory / --cpu-quota / --cpu-period ask (nil when the user passed
    /// no resource flags — never a default). Implementations size a builder
    /// they have to create at max(configured, requested) and may recreate a
    /// running builder that is smaller than an explicit ask.
    func ensureReachable(
        timeout: Duration, retryInterval: Duration, qemu: Bool, requested: BuilderResourceRequest?, logger: Logger
    ) async throws
    func connect(
        timeout: Duration, retryInterval: Duration, qemu: Bool, requested: BuilderResourceRequest?, logger: Logger
    ) async throws -> Builder
    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult
    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord]
}

extension ClientBuilderProtocol {
    // Backward-compatible overloads that default to Rosetta mode (qemu: false).
    func ensureReachable(timeout: Duration, retryInterval: Duration, logger: Logger) async throws {
        try await ensureReachable(timeout: timeout, retryInterval: retryInterval, qemu: false, logger: logger)
    }
    func connect(timeout: Duration, retryInterval: Duration, logger: Logger) async throws -> Builder {
        try await connect(timeout: timeout, retryInterval: retryInterval, qemu: false, logger: logger)
    }

    // Default size-aware behavior: no explicit ask, so the 4-argument form
    // applies. Existing mocks only implement the 4-argument requirements.
    func ensureReachable(
        timeout: Duration, retryInterval: Duration, qemu: Bool, requested: BuilderResourceRequest?, logger: Logger
    ) async throws {
        try await ensureReachable(timeout: timeout, retryInterval: retryInterval, qemu: qemu, logger: logger)
    }
    func connect(
        timeout: Duration, retryInterval: Duration, qemu: Bool, requested: BuilderResourceRequest?, logger: Logger
    ) async throws -> Builder {
        try await connect(timeout: timeout, retryInterval: retryInterval, qemu: qemu, logger: logger)
    }
}

struct ClientBuilderService: ClientBuilderProtocol {
    private let containerClient = ReconnectingContainerClient(makeClient: { ContainerClient() })
    private let networkClient = ReconnectingContainerClient(makeClient: { NetworkClient() })
    private let builderContainerId: String
    private let builderPort: UInt32
    /// Per-flavor sizing floors from PODM_BUILDER_* / PODM_QEMU_BUILDER_*
    /// env knobs (boot-time); explicit per-build requests escalate on top.
    private let rosettaResources: BuilderResourceRequest
    private let qemuResources: BuilderResourceRequest
    private let appSupportURL: URL
    private let containerSystemConfig: ContainerSystemConfig

    init(
        builderContainerId: String = "buildkit",
        builderPort: UInt32 = 8088,
        rosettaResources: BuilderResourceRequest = BuilderResourceRequest(
            memoryInBytes: BuilderResourceKnobs.defaultMemoryInBytes,
            cpus: BuilderResourceKnobs.defaultCPUs
        ),
        qemuResources: BuilderResourceRequest = BuilderResourceRequest(
            memoryInBytes: BuilderResourceKnobs.defaultMemoryInBytes,
            cpus: BuilderResourceKnobs.defaultCPUs
        ),
        appSupportURL: URL,
        containerSystemConfig: ContainerSystemConfig
    ) {
        self.builderContainerId = builderContainerId
        self.builderPort = builderPort
        self.rosettaResources = rosettaResources
        self.qemuResources = qemuResources
        self.appSupportURL = appSupportURL
        self.containerSystemConfig = containerSystemConfig
    }

    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult {
        let command = try BuildctlUtility.pruneCommand(from: request)
        var deletedIds: [String] = []
        var reclaimed: Int64 = 0
        var attempted = false
        var succeeded = false
        var lastError: Error?

        // Neither builder is provisioned just to report/reclaim nothing — a fresh install
        // that's never built anything shouldn't have `docker builder prune` spin up a VM only
        // to say "0 bytes freed".
        for qemu in [false, true] {
            let container: ContainerSnapshot?
            do {
                container = try await existingRunningBuilderContainer(qemu: qemu)
            } catch {
                // A lookup failure is itself a real, attempted-but-failed outcome — unlike
                // the container genuinely not running (the ordinary, benign `nil` case
                // below), this must count toward `attempted` or a lookup-only failure on
                // both builders would silently return an empty success.
                attempted = true
                logger.error("buildctl prune\(qemu ? " (qemu)" : "") lookup failed: \(error)")
                lastError = error
                continue
            }
            guard let container else { continue }
            attempted = true
            do {
                let stdoutText = try await execute(command: command, in: container, actionName: "buildctl prune\(qemu ? " (qemu)" : "")", logger: logger)
                let entries = BuildctlUtility.parsePruneOutput(stdoutText, logger: logger)
                deletedIds.append(contentsOf: entries.compactMap(\.id))
                reclaimed += entries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
                succeeded = true
            } catch {
                // One builder's transient failure shouldn't hide a successful prune of the
                // other — log and keep going instead of propagating and losing everything
                // already accumulated. Only rethrown below if EVERY attempted builder failed.
                logger.error("buildctl prune\(qemu ? " (qemu)" : "") failed: \(error)")
                lastError = error
            }
        }

        // Every builder that was actually running failed — an empty success result here
        // would silently read as "nothing to prune" instead of "the operation failed".
        if attempted, !succeeded, let lastError {
            throw lastError
        }

        return BuilderPruneResult(deletedCaches: deletedIds, spaceReclaimed: reclaimed)
    }

    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord] {
        let command = BuildctlUtility.duCommand()
        var records: [BuilderCacheRecord] = []
        var attempted = false
        var succeeded = false
        var lastError: Error?

        for qemu in [false, true] {
            let container: ContainerSnapshot?
            do {
                container = try await existingRunningBuilderContainer(qemu: qemu)
            } catch {
                attempted = true
                logger.error("buildctl du\(qemu ? " (qemu)" : "") lookup failed: \(error)")
                lastError = error
                continue
            }
            guard let container else { continue }
            attempted = true
            do {
                let stdoutText = try await execute(command: command, in: container, actionName: "buildctl du\(qemu ? " (qemu)" : "")", logger: logger)
                records.append(contentsOf: Self.parseDuRecords(from: stdoutText, logger: logger))
                succeeded = true
            } catch {
                logger.error("buildctl du\(qemu ? " (qemu)" : "") failed: \(error)")
                lastError = error
            }
        }

        if attempted, !succeeded, let lastError {
            throw lastError
        }

        return records
    }

    private static func parseDuRecords(from stdoutText: String, logger: Logger) -> [BuilderCacheRecord] {
        BuildctlUtility.parseDuOutput(stdoutText, logger: logger).compactMap { record in
            guard let id = record.id else { return nil }
            return BuilderCacheRecord(
                id: id,
                parents: record.parents ?? [],
                kind: record.recordType ?? "regular",
                description: record.recordDescription ?? "",
                inUse: record.inUse ?? false,
                shared: record.shared ?? false,
                size: record.size ?? 0,
                createdAt: record.createdAt ?? "",
                lastUsedAt: record.lastUsedAt,
                usageCount: record.usageCount ?? 0
            )
        }
    }

    /// Returns the QEMU (or Rosetta) builder container only if it's already running — never
    /// creates/starts it, unlike `runningBuilderContainer`. Used by reporting/cleanup
    /// operations (`prune`/`diskUsage`) that shouldn't provision a builder VM just to say
    /// there's nothing to report for it.
    private func existingRunningBuilderContainer(qemu: Bool) async throws -> ContainerSnapshot? {
        let containerID = resolvedContainerId(qemu: qemu)
        let container: ContainerSnapshot
        do {
            container = try await containerClient.withClient { try await $0.get(id: containerID) }
        } catch let error as ContainerizationError where error.code == .notFound {
            return nil
        }
        return container.status == .running ? container : nil
    }

    func ensureReachable(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logger) async throws {
        try await ensureReachable(timeout: timeout, retryInterval: retryInterval, qemu: qemu, requested: nil, logger: logger)
    }

    func ensureReachable(
        timeout: Duration, retryInterval: Duration, qemu: Bool, requested: BuilderResourceRequest?, logger: Logger
    ) async throws {
        _ = try await runningBuilderContainer(qemu: qemu, requested: requested, logger: logger)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?

        while clock.now < deadline {
            do {
                let socket = try await dialBuilderSocket(qemu: qemu, requested: requested)
                try? socket.close()
                return
            } catch {
                lastError = error
                logger.debug("Builder reachability check failed: \(error)")
            }

            try await Task.sleep(for: retryInterval)
        }

        if let lastError {
            throw ContainerizationError(.timeout, message: "Timeout waiting for builder reachability: \(lastError)")
        }
        throw ContainerizationError(.timeout, message: "Timeout waiting for builder reachability")
    }

    func connect(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logger) async throws -> Builder {
        try await connect(timeout: timeout, retryInterval: retryInterval, qemu: qemu, requested: nil, logger: logger)
    }

    func connect(
        timeout: Duration, retryInterval: Duration, qemu: Bool, requested: BuilderResourceRequest?, logger: Logger
    ) async throws -> Builder {
        _ = try await runningBuilderContainer(qemu: qemu, requested: requested, logger: logger)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?

        while clock.now < deadline {
            do {
                let socket = try await dialBuilderSocket(qemu: qemu, requested: requested)
                let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
                let builder = try await Builder(socket: socket, group: group, logger: logger)
                do {
                    _ = try await builder.info()
                    return builder
                } catch {
                    try? await group.shutdownGracefully()
                    throw error
                }
            } catch {
                lastError = error
                logger.debug("Builder connection attempt failed: \(error)")
            }

            try await Task.sleep(for: retryInterval)
        }

        if let lastError {
            throw ContainerizationError(.timeout, message: "Timeout waiting for connection to builder: \(lastError)")
        }
        throw ContainerizationError(.timeout, message: "Timeout waiting for connection to builder")
    }

    private func dialBuilderSocket(qemu: Bool, requested: BuilderResourceRequest? = nil) async throws -> FileHandle {
        let container = try await runningBuilderContainer(qemu: qemu, requested: requested, logger: nil)
        return try await containerClient.withClient { try await $0.dial(id: container.id, port: builderPort) }
    }

    /// Serializes builder lookup/replace decisions per process: a ONE-SLOT
    /// `VMLifecycleAdmission`, deliberately NOT a bare actor — actor methods
    /// are reentrant across await points, so an actor method that awaits a
    /// closure does not exclude other callers while that closure runs.
    /// Concurrent resizing calls would then read the same stale snapshot and
    /// delete each other's fresh VM (each seeing the other's replacement as
    /// an undersized leftover). The admission's continuation-based slot is
    /// held for the whole closure — lookup, replacement, and startup all
    /// happen under it.
    private let replacementSerializer = VMLifecycleAdmission(limit: 1)

    private func runningBuilderContainer(
        qemu: Bool, requested: BuilderResourceRequest? = nil, logger: Logger?
    ) async throws -> ContainerSnapshot {
        let containerID = resolvedContainerId(qemu: qemu)
        // Everything inside the slot is a quick get/create/replace decision —
        // never a reachability wait — so holding it can't stall the other
        // flavor's cold start for long.
        return try await replacementSerializer.withSlot { [self] in
            let container: ContainerSnapshot
            do {
                container = try await containerClient.withClient { try await $0.get(id: containerID) }
            } catch let error as ContainerizationError where error.code == .notFound {
                logger?.info("Builder container not found, creating a new builder instance")
                do {
                    let resources = Self.desiredResources(
                        requested: requested, configured: configuredResources(qemu: qemu), existing: nil)
                    return try await createAndStartBuilder(qemu: qemu, resources: resources, logger: logger)
                } catch {
                    // A concurrent caller may have created it between our own `get` miss and this
                    // `create` call — this codebase's own split-build (see BuildRoute) can now
                    // issue genuinely concurrent build requests, some of which may need the same
                    // cold-started builder. If someone else won the race, use what they created
                    // instead of failing this request — but still through the sizing logic below,
                    // because the winner may have provisioned SMALLER than this caller's ask;
                    // if `get` also fails, this wasn't a race — propagate the original error.
                    guard let existing = try? await containerClient.withClient({ try await $0.get(id: containerID) }) else {
                        throw error
                    }
                    return try await sizedExistingBuilder(existing, qemu: qemu, requested: requested, logger: logger)
                }
            }

            return try await sizedExistingBuilder(container, qemu: qemu, requested: requested, logger: logger)
        }
    }

    /// Applies the sizing decision to a builder that exists: keep it when it
    /// already covers what this build wants, replace it — never shrinking a
    /// field it already has — when an explicit ask or a raised env floor
    /// exceeds its current allocation.
    private func sizedExistingBuilder(
        _ container: ContainerSnapshot, qemu: Bool, requested: BuilderResourceRequest?, logger: Logger?
    ) async throws -> ContainerSnapshot {
        let containerID = resolvedContainerId(qemu: qemu)
        let current = Self.effectiveResources(of: container)
        let desired = Self.desiredResources(
            requested: requested, configured: configuredResources(qemu: qemu), existing: current)
        // `desired` folds `current` in per field, so this fires exactly when
        // the explicit ask or the env floor exceeds what the builder has —
        // never when they merely redistribute between fields.
        if current.memoryInBytes < desired.memoryInBytes || current.cpus < desired.cpus {
            logger?.warning(
                """
                Builder '\(containerID)' (\(current.memoryInBytes) bytes / \(current.cpus) vCPU) is smaller \
                than wanted (\(desired.memoryInBytes) bytes / \(desired.cpus) vCPU) — recreating it at the \
                larger size. The BuildKit cache inside the old builder is reset; a build concurrently \
                in flight on this builder may fail.
                """
            )
            do {
                try await containerClient.withClient { try await $0.stop(id: container.id) }
            } catch {
                logger?.warning("Stopping undersized builder '\(containerID)' failed (\(error)) — trying to delete it anyway")
            }
            try? await containerClient.withClient { try await $0.delete(id: container.id) }
            return try await createAndStartBuilder(qemu: qemu, resources: desired, logger: logger)
        }
        return try await ensureRunning(container, qemu: qemu, resources: desired, logger: logger)
    }

    /// The floor for this flavor: env knobs at boot (RouteRegistry).
    private func configuredResources(qemu: Bool) -> BuilderResourceRequest {
        qemu ? qemuResources : rosettaResources
    }

    /// Per-field max of the build's explicit ask, the env floor, and the
    /// builder's current allocation, clamped to the host — replacement never
    /// shrinks a field the running builder already has. A blank/absent
    /// request contributes nothing; `existing` may be nil (fresh creation).
    static func desiredResources(
        requested: BuilderResourceRequest?, configured: BuilderResourceRequest, existing: BuilderResourceRequest?
    ) -> BuilderResourceRequest {
        let ask = (requested?.isBlank == false) ? requested : nil
        return BuilderResourceRequest(
            memoryInBytes: max(ask?.memoryInBytes ?? 0, max(configured.memoryInBytes, existing?.memoryInBytes ?? 0)),
            cpus: max(ask?.cpus ?? 0, max(configured.cpus, existing?.cpus ?? 0))
        ).clampedToHost()
    }

    /// The resources a builder snapshot effectively has. A pre-existing
    /// builder that reports unset/zero fields counts as the historical
    /// default (2 vCPU / 2048 MiB) so it isn't needlessly recreated.
    static func effectiveResources(of container: ContainerSnapshot) -> BuilderResourceRequest {
        let resources = container.configuration.resources
        let cpus = resources.cpus > 0 ? Int64(resources.cpus) : BuilderResourceKnobs.defaultCPUs
        let memory =
            resources.memoryInBytes > 0
            ? Int64(resources.memoryInBytes) : BuilderResourceKnobs.defaultMemoryInBytes
        return BuilderResourceRequest(memoryInBytes: memory, cpus: cpus)
    }

    /// `resources` is the sizing decision already made for this caller — the
    /// `.unknown` recovery path recreates at it, so recovery can't silently
    /// drop a validated per-build ask down to the configured floor.
    private func ensureRunning(
        _ container: ContainerSnapshot, qemu: Bool, resources: BuilderResourceRequest, logger: Logger?
    ) async throws -> ContainerSnapshot {
        let containerID = resolvedContainerId(qemu: qemu)
        guard container.status == .running else {
            switch container.status {
            case .running:
                return container
            case .stopped:
                logger?.info("Builder container is stopped, starting it")
                try await startBuildKit(containerId: container.id)
                return try await containerClient.withClient { try await $0.get(id: container.id) }
            case .stopping:
                throw ContainerizationError(.invalidState, message: "BuildKit container '\(containerID)' is stopping")
            case .unknown:
                logger?.warning("Builder container has unknown state, recreating it")
                try? await containerClient.withClient { try await $0.delete(id: container.id) }
                return try await createAndStartBuilder(qemu: qemu, resources: resources, logger: logger)
            @unknown default:
                throw ContainerizationError(.invalidState, message: "BuildKit container '\(containerID)' is in an unsupported state")
            }
        }

        return container
    }

    /// Returns the container ID for a given mode.
    /// QEMU-mode builder uses a distinct ID (base ID + "-qemu") so both builders can
    /// coexist and be looked up independently.
    private func resolvedContainerId(qemu: Bool) -> String {
        qemu ? "\(builderContainerId)-qemu" : builderContainerId
    }

    private func createAndStartBuilder(
        qemu: Bool, resources: BuilderResourceRequest, logger: Logger?
    ) async throws -> ContainerSnapshot {
        let containerID = resolvedContainerId(qemu: qemu)
        let exportsMount = appSupportURL.appendingPathComponent("builder")
        if !FileManager.default.fileExists(atPath: exportsMount.path) {
            try FileManager.default.createDirectory(at: exportsMount, withIntermediateDirectories: true)
        }

        let builderImage = containerSystemConfig.build.image
        let builderPlatform = Platform(arch: "arm64", os: "linux", variant: "v8")
        // QEMU mode: register binfmt handlers inside the VM kernel for all foreign
        // architectures (s390x, ppc64le, riscv64, etc.).  Rosetta is disabled because
        // it and QEMU binfmt registration are mutually exclusive in the builder shim.
        let useRosetta = qemu ? false : containerSystemConfig.build.rosetta

        let image = try await ClientImage.fetch(reference: builderImage, platform: builderPlatform, containerSystemConfig: containerSystemConfig)
        _ = try await image.getCreateSnapshot(platform: builderPlatform)
        let imageDesc = ImageDescription(reference: builderImage, descriptor: image.descriptor)

        let imageConfig = try await image.config(for: builderPlatform).config
        guard let defaultNetwork = try await networkClient.withClient({ try await $0.builtin }) else {
            throw ContainerizationError(.invalidState, message: "default network is not present")
        }
        let nameserver = IPv4Address(defaultNetwork.status.ipv4Subnet.lower.value + 1).description

        let config = try Self.builderContainerConfiguration(
            builderContainerId: containerID,
            imageDescription: imageDesc,
            imageEnv: imageConfig?.env,
            useRosetta: useRosetta,
            qemu: qemu,
            resources: resources,
            exportsMountPath: exportsMount.path,
            networkId: defaultNetwork.id,
            nameserver: nameserver
        )

        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        try await containerClient.withClient { try await $0.create(configuration: config, options: .default, kernel: kernel) }
        try await startBuildKit(containerId: containerID)
        return try await containerClient.withClient { try await $0.get(id: containerID) }
    }

    /// Pure construction of the BuildKit guest's ContainerConfiguration — no real service
    /// calls, so it's directly unit-testable without a live daemon. Kept separate from
    /// `createAndStartBuilder` (which resolves the image/network inputs this needs).
    static func builderContainerConfiguration(
        builderContainerId: String,
        imageDescription: ImageDescription,
        imageEnv: [String]?,
        useRosetta: Bool,
        qemu: Bool,
        resources: BuilderResourceRequest,
        exportsMountPath: String,
        networkId: String,
        nameserver: String
    ) throws -> ContainerConfiguration {
        let processConfig = ProcessConfiguration(
            executable: "/usr/local/bin/container-builder-shim",
            // `--enable-qemu` depends solely on which builder instance this is — NOT on
            // `useRosetta`, which independently reflects the user's own rosetta config and
            // can be false even for the non-qemu builder (e.g. `build.rosetta` disabled).
            // Deriving it from `!useRosetta` would register QEMU binfmt handlers on the
            // Rosetta builder too in that case, which this type's own doc comment says are
            // mutually exclusive in the shim.
            arguments: ["--debug", "--vsock", qemu ? "--enable-qemu" : nil].compactMap { $0 },
            environment: imageEnv ?? [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(id: builderContainerId, image: imageDescription, process: processConfig)
        config.resources.cpus = Int(clamping: resources.cpus)
        config.resources.memoryInBytes = UInt64(clamping: resources.memoryInBytes)
        config.labels = [ResourceLabelKeys.role: ResourceRoleValues.builder]
        config.mounts = [
            Filesystem.tmpfs(destination: "/run", options: []),
            Filesystem.virtiofs(source: exportsMountPath, destination: "/var/lib/container-builder-shim/exports", options: []),
        ]
        // BuildKit's runc-native snapshotter rbind-mounts a snapshot to read the build
        // context/Dockerfile, which needs CAP_SYS_ADMIN — root alone doesn't grant it.
        // Matches apple/container's own builder bootstrap (BuilderStart.swift).
        config.capAdd = ["ALL"]
        config.rosetta = useRosetta
        config.networks = [
            AttachmentConfiguration(network: networkId, options: AttachmentOptions(hostname: builderContainerId))
        ]
        config.dns = ContainerConfiguration.DNSConfiguration(nameservers: [nameserver], domain: nil, searchDomains: [], options: [])
        return config
    }

    private func startBuildKit(containerId: String) async throws {
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }

        do {
            let process = try await containerClient.withClient { try await $0.bootstrap(id: containerId, stdio: io.stdio) }
            try await process.start()
            try io.closeAfterStart()
        } catch {
            try? await containerClient.withClient { try await $0.stop(id: containerId) }
            try? await containerClient.withClient { try await $0.delete(id: containerId) }
            if let containerizationError = error as? ContainerizationError {
                throw containerizationError
            }
            throw ContainerizationError(.internalError, message: "failed to start BuildKit: \(error)")
        }
    }

    private func execute(command: BuildctlUtility.Command, in container: ContainerSnapshot, actionName: String, logger: Logger) async throws -> String {
        var processConfig = container.configuration.initProcess
        processConfig.executable = command.executable
        processConfig.arguments = command.arguments
        processConfig.terminal = false

        guard let pipes = StdioPipes.make([.stdout, .stderr]) else {
            throw ContainerizationError(.internalError, message: "Failed to create I/O pipes")
        }
        let process: ClientProcess
        let processConfigToSend = processConfig
        do {
            process = try await containerClient.withClient {
                try await $0.createProcess(
                    containerId: container.id,
                    processId: UUID().uuidString.lowercased(),
                    configuration: processConfigToSend,
                    stdio: pipes.stdioArray
                )
            }
        } catch {
            pipes.closeAll()
            throw error
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw error
        }
        let (exitCode, stdoutData, stderrData) = try await pipes.collectOutput {
            try await process.wait()
        }
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if !stderrText.isEmpty {
            logger.error("\(actionName) stderr:\n\(stderrText)")
        }

        guard exitCode == 0 else {
            let details = stderrText.isEmpty ? stdoutText : stderrText
            throw ContainerizationError(.unknown, message: "\(actionName) failed with exit code \(exitCode): \(details)")
        }

        return stdoutText
    }

}
