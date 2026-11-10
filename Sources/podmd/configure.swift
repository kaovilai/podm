import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import Vapor

struct AppleContainerAppSupportUrlKey: StorageKey {
    typealias Value = URL
}

func configure(_ app: Application) async throws {

    // Docker container-create payloads (large env / config — e.g. Supabase's
    // edge-runtime + storage-api) exceed Vapor's 16 KB default collected-body
    // cap, yielding 413 "Payload Too Large". Raise it well above any real request.
    app.routes.defaultMaxBodySize = "64mb"

    // Make error responses Docker-compatible (`{"message": ...}`) so SDKs like
    // docker-py don't crash on their `response.json()['message']` lookup. Installed
    // outermost so it wraps all routing/error handling. See DockerErrorMiddleware.
    app.middleware.use(DockerErrorMiddleware(), at: .beginning)

    // launchd on-demand lifecycle: count in-flight requests so the daemon
    // never exits while serving a client. Streaming response bodies are
    // counted at construction via `Response.Body.idleTracked(...)` — Vapor's
    // Response.Body storage is internal, so middleware alone cannot see a
    // stream that outlives its handler. See Utilities/IdleExit.swift.
    let idleCounters = IdleActivityCounters.shared
    app.middleware.use(IdleExitConnectionMiddleware(counters: idleCounters))

    // Idle-exit monitor: exits the daemon after PODM_IDLE_EXIT_SECS
    // (default 90s, 0 disables) of no client connections AND no running
    // containers, so an idle podmd consumes zero RAM; launchctl kickstart
    // wakes it again. Never exits while containers run — the embedded DNS
    // server (PodmDNSServer), healthcheck loops (HealthCheckManager) and
    // event broadcasting all live in this process and running containers
    // depend on them. See Utilities/IdleExit.swift for the full contract.
    let idleConfiguration = IdleExitConfiguration.fromEnvironment(
        ProcessInfo.processInfo.environment)
    if idleConfiguration.isEnabled {
        if ProcessInfo.processInfo.environment["PODM_LAUNCHD"] == "1" {
            app.logger.info("launchd mode: idle-exit enabled (grace \(idleConfiguration.grace))")
        } else {
            app.logger.info(
                "idle-exit enabled (grace \(idleConfiguration.grace)); set PODM_IDLE_EXIT_SECS=0 to disable"
            )
        }
        let idleMonitor = IdleExitMonitor(
            configuration: idleConfiguration,
            counters: idleCounters,
            runningContainersProvider: defaultRunningContainersProvider(logger: app.logger),
            logger: app.logger
        ) {
            // Same path SIGTERM takes (Vapor's ServeCommand signal handler
            // completes app.running's promise): main.swift's onStop.get()
            // returns, the instance lock is released, the process exits 0.
            app.running?.stop()
        }
        // Created here but started by main.swift after app.startup() succeeds:
        // configure() runs before the server is up, and startup (housekeeping
        // included) can take tens of seconds — with a short grace the monitor
        // would fire while app.running is still nil (the optional stop() would
        // no-op, but the monitor's exit latch would burn its one shot and the
        // daemon would never idle-exit for the rest of its life).
        app.storage[IdleExitMonitorKey.self] = idleMonitor
    }
    // Production route surface (clients, regex router, all collections) —
    // shared with the route-conformance test via RouteRegistry.
    let (appleContainerAppSupportUrl, systemConfig) = try await RouteRegistry.bootstrap(app)

    // Initialize broadcaster
    let broadcaster = EventBroadcaster()
    app.storage[EventBroadcasterKey.self] = broadcaster
    app.storage[AppleContainerAppSupportUrlKey.self] = appleContainerAppSupportUrl

    // Initialize inter-container DNS infrastructure.
    // Port is read from PODM_DNS_PORT (default 2054). If the preferred port
    // is taken, Podm auto-increments until a free port is found.
    let preferredDNSPort =
        ProcessInfo.processInfo.environment["PODM_DNS_PORT"]
        .flatMap(Int.init) ?? 2054
    let dnsServer = PodmDNSServer()
    guard let resolvedDNSPort = dnsServer.start(preferredPort: preferredDNSPort) else {
        app.logger.error("Could not bind DNS server on any port near \(preferredDNSPort) — inter-container DNS disabled")
        return
    }
    app.logger.notice("DNS server listening on port \(resolvedDNSPort)")
    app.storage[PodmDNSServerKey.self] = dnsServer

    let dnsManager = NetworkDNSManager(appSupportURL: appleContainerAppSupportUrl, dnsPort: resolvedDNSPort, containerSystemConfig: systemConfig)
    app.storage[NetworkDNSManagerKey.self] = dnsManager

    // Healthcheck executor: runs `HEALTHCHECK` probes inside containers and
    // tracks status so `/containers/{id}/json` can return `.State.Health`.
    let healthCheckManager = HealthCheckManager(broadcaster: broadcaster)
    app.storage[HealthCheckManagerKey.self] = healthCheckManager

    // Resume healthcheck loops and DNS registrations for any containers that were
    // running when Podm last stopped. PodmDNSServer is in-memory so
    // entries are lost on restart; without re-registration containers that are
    // restarted (not re-created) via docker start cannot be resolved by peers.
    let resumeClient = ContainerClient()
    if let runningContainers = try? await resumeClient.list() {
        for container in runningContainers where container.status == .running {
            // Skip DNS-sidecar containers — they are internal infrastructure.
            guard !ClientContainerService.isDNSSidecar(container)
            else { continue }

            await ContainerStartRoute.registerDNSAliasesOnResume(container: container, dnsServer: dnsServer, logger: app.logger)

            // Resume healthcheck loop if the container has one.
            guard let json = container.configuration.labels[HealthCheckManager.healthcheckLabel],
                let config = try? JSONDecoder().decode(HealthcheckConfig.self, from: Data(json.utf8)),
                HealthCheckManager.parseTest(config.Test) != nil  // skip NONE / disabled checks
            else { continue }
            await healthCheckManager.start(containerId: container.id, config: config)
            app.logger.info("Resumed healthcheck for \(container.id)")
        }
    }

    // Sidecar adoption and network reaping (in that order — a network whose only
    // member was its sidecar must appear empty to the reaper) are best-effort
    // housekeeping over XPC calls that hang indefinitely when the runtime is
    // wedged (apple/container#1884). Time-box them: a daemon that skips
    // housekeeping still serves clients, one that never binds its socket serves
    // nothing. Network reaping context: Apple Container's vmnet state degrades
    // as orphaned networks accumulate and eventually breaks container-to-container
    // routing (EHOSTUNREACH).
    let housekeepingLogger = app.logger
    let housekeepingFinished = await StartupHousekeeping.runBounded(timeout: .seconds(30)) {
        await dnsManager.adoptOrRemoveSidecarsFromPreviousRun()
        await OrphanedNetworkReaper.reap(networkClient: ClientNetworkService(), logger: housekeepingLogger)
    }
    if !housekeepingFinished {
        app.logger.warning(
            "[startup] DNS-sidecar adoption / orphaned-network reaping did not finish within 30s — continuing startup without it. The container runtime may be unhealthy (see apple/container#1884)."
        )
    }

}
