import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import Vapor

/// Boots the production route surface: constructs the service clients, installs
/// the regex router, and registers every route collection exactly as the daemon
/// serves them. Extracted from `configure()` so the route-conformance test can
/// enumerate and exercise the REAL registered surface (164 collections) rather
/// than a hand-maintained list. Returns the Apple container app-support URL the
/// post-registration services in `configure()` need.
///
/// Side effects are boot-safe for tests: XPC clients connect lazily on first
/// use, and dispatching requests with dummy path parameters only ever reaches
/// lookup/validation code paths (a bogus container/image reference is a 404
/// long before any VM or store mutation).
enum RouteRegistry {
    /// The default Apple container app-support directory — the single source
    /// of the literal that route collections' no-argument defaults also need
    /// (they must compile without the registry passing anything).
    static let defaultAppSupportURL = URL(
        fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/com.apple.container")

    /// - Parameter appSupportDirectory: overrides where podm's own
    ///   app-support-managed state lives (notably the restart-policy override
    ///   store, a singleton). The daemon passes nothing and gets the real
    ///   `~/Library/Application Support/com.apple.container`; the conformance
    ///   test passes a throwaway directory so `RestartPolicyOverrideStore.shared`
    ///   is never pointed at a developer's real store by a test boot.
    static func bootstrap(
        _ app: Application,
        appSupportDirectory: URL? = nil
    ) async throws -> (appSupportUrl: URL, systemConfig: ContainerSystemConfig) {
        // Define app support path early since it's needed by multiple services
        let appleContainerAppSupportUrl = appSupportDirectory ?? RouteRegistry.defaultAppSupportURL

        let systemConfig: ContainerSystemConfig
        do {
            systemConfig = try await ConfigurationLoader.load()
        } catch let err as ContainerizationError {
            app.logger.error("System config is malformed — falling back to defaults. Fix your config.toml: \(err)")
            systemConfig = ContainerSystemConfig()
        } catch {
            app.logger.warning("Failed to load system config at startup, using defaults: \(error)")
            systemConfig = ContainerSystemConfig()
        }

        let containerClient = ClientContainerService()
        await RestartPolicyOverrideStore.shared.configure(storageDirectory: appleContainerAppSupportUrl)
        await ContainerNameOverrideStore.shared.configure(storageDirectory: appleContainerAppSupportUrl)
        let imageClient = ClientImageService(containerSystemConfig: systemConfig)
        let healthCheckClient = ClientHealthCheckService()
        let networkClient = ClientNetworkService()
        let volumeClient = ClientVolumeService()
        let registryClient = ClientRegistryService()
        // podman's LOCAL secret store (libpod dialect) — file-backed under
        // app support, 0600 payloads; distinct from the swarm /secrets stubs.
        let secretStore = SecretStore(storageDirectory: appleContainerAppSupportUrl)
        let archiveClient = ClientArchiveService(appSupportPath: appleContainerAppSupportUrl)
        let builderClient = ClientBuilderService(appSupportURL: appleContainerAppSupportUrl, containerSystemConfig: systemConfig)

        // Create and install regex routing middleware with logging
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)

        // /_ping
        try app.register(collection: HealthCheckPingRoute(client: healthCheckClient))

        // /info
        try app.register(collection: InfoRoute(containerClient: containerClient, imageClient: imageClient))

        // /events
        try app.register(collection: EventsRoute(client: healthCheckClient))

        // exec
        try app.register(collection: ExecRoute(client: containerClient))

        // /containers
        try app.register(collection: ContainerArchiveRoute(containerClient: containerClient, archiveClient: archiveClient))
        try app.register(collection: ContainerAttachRoute(client: containerClient))
        try app.register(collection: ContainerAttachWSRoute(client: containerClient))
        try app.register(collection: ContainerChangesRoute())
        try app.register(collection: ContainerCreateRoute(client: containerClient, systemConfig: systemConfig))
        try app.register(collection: ContainerDeleteRoute(client: containerClient))
        try app.register(collection: ContainerExportRoute(containerClient: containerClient, archiveClient: archiveClient))
        try app.register(collection: ContainerInspectRoute(client: containerClient))
        try app.register(collection: ContainerKillRoute(client: containerClient))
        try app.register(collection: ContainerListRoute(client: containerClient))
        try app.register(collection: ContainerLogsRoute(client: containerClient))
        try app.register(collection: ContainerPauseRoute())
        try app.register(collection: ContainerPruneRoute(client: containerClient))
        try app.register(collection: ContainerRenameRoute(client: containerClient))
        try app.register(collection: ContainerResizeRoute(client: containerClient))
        try app.register(collection: ContainerRestartRoute(client: containerClient))
        try app.register(collection: ContainerStartRoute(client: containerClient))
        try app.register(collection: ContainerStatsRoute())
        try app.register(collection: ContainerStopRoute(client: containerClient))
        try app.register(collection: ContainerTopRoute())
        try app.register(collection: ContainerUnpauseRoute())
        try app.register(collection: ContainerUpdateRoute(client: containerClient))
        try app.register(collection: ContainerWaitRoute(client: containerClient))

        // /images
        let manifestClient = ClientManifestService(appSupportURL: appleContainerAppSupportUrl, containerSystemConfig: systemConfig)
        try app.register(collection: ImageDeleteRoute(client: imageClient))
        try app.register(collection: ImageHistoryRoute(systemConfig: systemConfig))
        try app.register(collection: ImageListRoute(client: imageClient))
        try app.register(collection: ImagePruneRoute(client: imageClient))
        try app.register(collection: ImageCreateRoute(client: imageClient))
        try app.register(collection: ImagePushRoute(client: imageClient, manifestClient: manifestClient))
        try app.register(collection: ImageSearchRoute())
        try app.register(collection: ImageInspectRoute(systemConfig: systemConfig))
        try app.register(collection: ImageTagRoute(systemConfig: systemConfig))
        try app.register(collection: ImagesGetRoute(client: imageClient))
        try app.register(collection: ImagesLoadRoute(client: imageClient))

        // /volumes
        try app.register(collection: VolumeCreateRoute(client: volumeClient))
        try app.register(collection: VolumeDeleteRoute(client: volumeClient))
        try app.register(collection: VolumeInspectRoute(client: volumeClient))
        try app.register(collection: VolumeListRoute(client: volumeClient))
        try app.register(collection: VolumePruneRoute(client: volumeClient))

        // /swarm
        try app.register(collection: SwarmInitRoute())
        try app.register(collection: SwarmJoinRoute())
        try app.register(collection: SwarmLeaveRoute())
        try app.register(collection: SwarmRoute())
        try app.register(collection: SwarmUnlockKeyRoute())
        try app.register(collection: SwarmUnlockRoute())
        try app.register(collection: SwarmUpdateRoute())

        // --- network routes ---
        try app.register(collection: NetworkConnectRoute())
        try app.register(collection: NetworkCreateRoute(client: networkClient))
        try app.register(collection: NetworkDisconnectRoute())
        try app.register(collection: NetworkInspectRoute(client: networkClient))
        try app.register(collection: NetworkListRoute())
        try app.register(collection: NetworkPruneRoute(client: networkClient))
        try app.register(collection: NetworkDeleteRoute(client: networkClient))

        // --- build/distribution routes ---
        try app.register(collection: BuildPruneRoute(builderClient: builderClient))
        try app.register(collection: BuildRoute(client: containerClient, builderClient: builderClient, systemConfig: systemConfig, manifestClient: manifestClient))
        try app.register(collection: DistributionJsonRoute(systemConfig: systemConfig))

        // --- plugin routes ---
        try app.register(collection: PluginsCreateRoute())
        try app.register(collection: PluginsNameDisableRoute())
        try app.register(collection: PluginsNameEnableRoute())
        try app.register(collection: PluginsNameJsonRoute())
        try app.register(collection: PluginsNamePushRoute())
        try app.register(collection: PluginsNameRoute())
        try app.register(collection: PluginsNameSetRoute())
        try app.register(collection: PluginsNameUpgradeRoute())
        try app.register(collection: PluginsPrivilegesRoute())
        try app.register(collection: PluginsPullRoute())
        try app.register(collection: PluginsRoute())

        // --- swarm node routes ---
        try app.register(collection: NodesIdRoute())
        try app.register(collection: NodesIdUpdateRoute())
        try app.register(collection: NodesRoute())

        // --- swarm service routes ---
        try app.register(collection: ServicesCreateRoute())
        try app.register(collection: ServicesIdLogsRoute())
        try app.register(collection: ServicesIdRoute())
        try app.register(collection: ServicesIdUpdateRoute())
        try app.register(collection: ServicesRoute())

        // --- swarm task routes ---
        try app.register(collection: TasksIdLogsRoute())
        try app.register(collection: TasksIdRoute())
        try app.register(collection: TasksRoute())

        // --- Swarm secret routes ---
        try app.register(collection: SecretsCreateRoute())
        try app.register(collection: SecretsIdRoute())
        try app.register(collection: SecretsIdUpdateRoute())
        try app.register(collection: SecretsRoute())

        // --- swarm config routes ---
        try app.register(collection: ConfigsCreateRoute())
        try app.register(collection: ConfigsIdRoute())
        try app.register(collection: ConfigsIdUpdateRoute())
        try app.register(collection: ConfigsRoute())

        // --- session route ---
        try app.register(collection: SessionRoute())

        // --- miscellaneous ---
        try app.register(collection: AuthRoute(client: registryClient))
        try app.register(collection: CommitRoute(containerClient: containerClient, archiveClient: archiveClient, imageClient: imageClient))
        let systemDFRoute = SystemDFRoute(
            imageClient: imageClient, containerClient: containerClient, volumeClient: volumeClient, builderClient: builderClient,
            diskUsageProvider: ContainerClientDiskUsageProvider(),
            imageLayerDiskUsageProvider: ClientImageLayerDiskUsageProvider()
        )
        try app.register(collection: systemDFRoute)
        try app.register(collection: VersionRoute())

        // --- Podman libpod routes ---
        try app.register(collection: LibpodPingRoute(client: healthCheckClient))
        try app.register(collection: LibpodVersionRoute())
        try app.register(collection: LibpodInfoRoute(containerClient: containerClient, imageClient: imageClient))
        try app.register(collection: LibpodContainerListRoute(client: containerClient))
        try app.register(collection: LibpodContainerCreateRoute(client: containerClient, systemConfig: systemConfig))
        try app.register(collection: LibpodContainerStartRoute(client: containerClient))
        try app.register(collection: LibpodContainerStopRoute(client: containerClient))
        try app.register(collection: LibpodContainerKillRoute(client: containerClient))
        try app.register(collection: LibpodContainerAttachRoute(client: containerClient))
        try app.register(collection: LibpodContainerWaitRoute(client: containerClient))
        try app.register(collection: LibpodContainerInspectRoute(client: containerClient))
        try app.register(collection: LibpodContainerDeleteRoute(client: containerClient))
        try app.register(collection: LibpodContainerHealthcheckRoute(client: containerClient))
        try app.register(collection: LibpodImageListRoute(client: imageClient))
        try app.register(collection: LibpodImagePullRoute(client: imageClient))
        try app.register(collection: LibpodImageDeleteRoute(client: imageClient))
        try app.register(collection: LibpodImageRemoveRoute(client: imageClient))
        try app.register(collection: LibpodImageInspectRoute(systemConfig: systemConfig))
        try app.register(collection: LibpodImageTagRoute(systemConfig: systemConfig))
        try app.register(collection: LibpodBuildRoute(client: containerClient, builderClient: builderClient, systemConfig: systemConfig, manifestClient: manifestClient))
        try app.register(collection: LibpodContainerLogsRoute(client: containerClient))
        try app.register(collection: LibpodContainerTopRoute())
        try app.register(collection: LibpodContainerRenameRoute(client: containerClient))
        try app.register(collection: LibpodContainerRestartRoute(client: containerClient))
        try app.register(collection: LibpodExecCreateRoute(client: containerClient))
        try app.register(collection: LibpodExecStartRoute(client: containerClient))
        try app.register(collection: LibpodExecInspectRoute(client: containerClient))
        try app.register(collection: LibpodVolumeListRoute(dockerRoute: VolumeListRoute(client: volumeClient)))
        try app.register(collection: LibpodVolumeCreateRoute(dockerRoute: VolumeCreateRoute(client: volumeClient)))
        try app.register(collection: LibpodVolumeDeleteRoute(dockerRoute: VolumeDeleteRoute(client: volumeClient)))
        try app.register(collection: LibpodVolumeInspectRoute(dockerRoute: VolumeInspectRoute(client: volumeClient)))
        try app.register(collection: LibpodNetworkListRoute())
        try app.register(collection: LibpodNetworkCreateRoute(dockerRoute: NetworkCreateRoute(client: networkClient)))
        try app.register(collection: LibpodNetworkDeleteRoute(dockerRoute: NetworkDeleteRoute(client: networkClient)))
        try app.register(collection: LibpodNetworkInspectRoute(client: networkClient))
        try app.register(
            collection: LibpodSystemDFRoute(dockerRoute: systemDFRoute))
        try app.register(collection: LibpodAuthRoute(client: registryClient))

        // --- Podman libpod routes: stats/pause/prune/cp/push/save/load/events gaps ---
        try app.register(collection: LibpodContainerStatsRoute())
        // All-container stats (podman stats with no args): plural route, podman's
        // newline-delimited ContainerStatsReport shape.
        try app.register(collection: LibpodContainersStatsRoute(client: containerClient))
        // podman untag: POST /libpod/images/{name}/untag (repo/tag parameter dance
        // like the tag endpoint; bare invocation removes every reference).
        try app.register(collection: LibpodImageUntagRoute(systemConfig: systemConfig))
        try app.register(collection: LibpodContainerPauseRoute())
        try app.register(collection: LibpodContainerUnpauseRoute())
        try app.register(collection: LibpodContainerChangesRoute())
        try app.register(collection: LibpodContainerPruneRoute(dockerRoute: ContainerPruneRoute(client: containerClient)))
        try app.register(collection: LibpodContainerUpdateRoute(client: containerClient))
        try app.register(collection: LibpodContainerExportRoute(containerClient: containerClient, archiveClient: archiveClient))
        try app.register(collection: LibpodContainerArchiveRoute(containerClient: containerClient, archiveClient: archiveClient))
        try app.register(collection: LibpodImagePushRoute(client: imageClient, manifestClient: manifestClient))
        try app.register(collection: LibpodImagePruneRoute(dockerRoute: ImagePruneRoute(client: imageClient)))
        try app.register(collection: LibpodImagesGetRoute(client: imageClient))
        try app.register(collection: LibpodImagesLoadRoute(client: imageClient))
        try app.register(collection: LibpodVolumePruneRoute(dockerRoute: VolumePruneRoute(client: volumeClient)))
        try app.register(collection: LibpodNetworkPruneRoute(client: networkClient))
        try app.register(collection: LibpodNetworkConnectRoute())
        try app.register(collection: LibpodNetworkDisconnectRoute())
        try app.register(collection: LibpodEventsRoute(client: healthCheckClient))
        try app.register(collection: LibpodImageImportRoute(client: imageClient))
        try app.register(collection: LibpodImageSearchRoute(dockerRoute: ImageSearchRoute()))
        try app.register(collection: LibpodImageHistoryRoute(systemConfig: systemConfig))
        try app.register(collection: LibpodCommitRoute(containerClient: containerClient, archiveClient: archiveClient, imageClient: imageClient))
        try app.register(collection: LibpodContainerExistsRoute(client: containerClient))
        try app.register(collection: LibpodImageExistsRoute(systemConfig: systemConfig))
        try app.register(collection: LibpodVolumeExistsRoute(client: volumeClient))

        // libpod secrets (podman secret create/ls/inspect/rm)
        try app.register(collection: LibpodSecretsRoute(store: secretStore))
        try app.register(collection: LibpodNetworkExistsRoute(client: networkClient))

        try app.register(collection: LibpodManifestCreateRoute(client: manifestClient))
        try app.register(collection: LibpodManifestInspectRoute(client: manifestClient))
        try app.register(collection: LibpodManifestExistsRoute(client: manifestClient))
        try app.register(collection: LibpodManifestModifyRoute(client: manifestClient))
        try app.register(collection: LibpodManifestDeleteRoute(client: manifestClient))
        try app.register(collection: LibpodManifestPushRoute(manifestClient: manifestClient, imageClient: imageClient))
        return (appleContainerAppSupportUrl, systemConfig)
    }
}
