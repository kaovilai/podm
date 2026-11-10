import ArgumentParser
import BuildInfo
import ContainerResource
import Foundation
import Vapor

// CLI options
struct CLIOptions: ParsableArguments {
    @ArgumentParser.Flag(name: .long, help: "Show version")
    var version: Bool = false

    @ArgumentParser.Flag(name: .long, inversion: .prefixedNo, help: "Check Apple Container compatibility and exit")
    var checkCompatibility: Bool = true

    @ArgumentParser.Flag(name: .long, inversion: .prefixedNo, help: "Create or update the 'podm' Docker context on startup")
    var dockerContext: Bool = true

    @ArgumentParser.Option(
        name: .long,
        help:
            "Sync mode for named volumes: nosync (default, ~1.5x faster for write-heavy workloads), fsync (honors guest fsyncs for durability), full (fully synchronous writes). Override per-volume with: docker volume create -o sync=fsync <name>"
    )
    var volumeSync: String = "nosync"

    @ArgumentParser.Option(
        name: .long,
        help:
            "Upstream DNS resolver for names the embedded DNS server cannot answer locally: IPv4 literal with optional :port (default 1.1.1.1:53). Env fallback: PODM_DNS_UPSTREAM"
    )
    var dnsUpstream: String?

    @ArgumentParser.Option(
        name: .long,
        help:
            "Generate route-coverage documentation (route-coverage.md + index.html) into the given directory and exit — CI uses this to keep the README section and the GitHub Pages site in sync with the registered surface."
    )
    var docgen: String?
}

// Parse CLI before starting the app
let options = CLIOptions.parseOrExit()

if options.version {
    print("podm: \(getBuildVersion()) (git commit: \(getBuildGitCommit()))")
    exit(0)
}

// Documentation generation mode: boot the production route registry (no
// server, no instance lock), render the support surface, exit. Used by CI.
if let docgenDir = options.docgen {
    var docgenEnv = try Environment(name: "docgen", arguments: ["podm"])
    try LoggingSystem.bootstrap(from: &docgenEnv)
    let docgenApp = try await Application.make(docgenEnv)
    // Boot against a THROWAWAY app-support directory: docgen takes no
    // instance lock, and SecretStore's load sweeps crash-leftover temp
    // files and quarantines corrupt ones — pointed at the real store while
    // the daemon runs, that could delete a live mutation's in-flight temp
    // file (a 500 mid-persist) or quarantine a file the daemon is about to
    // swap. Docgen only reads the registered routes; nothing it renders
    // depends on real state.
    let docgenAppSupport = FileManager.default.temporaryDirectory
        .appendingPathComponent("podm-docgen-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: docgenAppSupport) }
    _ = try await RouteRegistry.bootstrap(docgenApp, appSupportDirectory: docgenAppSupport)
    try RouteDocGen.write(to: docgenDir, routes: docgenApp.regexRouter.registeredRoutes)
    try await docgenApp.asyncShutdown()
    exit(0)
}

// Resolve the DNS upstream before anything else touches the DNS server (it is
// applied via PodmDNSServer.upstream ahead of configure(_:), which starts the
// server). The CLI flag wins; PODM_DNS_UPSTREAM is only consulted when the
// flag is absent. An invalid CLI value is fatal, while an invalid env value only
// warns and keeps the default (matching upstream socktainer's documented
// semantics).
if let cliUpstream = options.dnsUpstream {
    guard let parsed = PodmDNSServer.parseUpstream(cliUpstream) else {
        FileHandle.standardError.write(
            Data(
                "podm: invalid --dns-upstream '\(cliUpstream)' — expected an IPv4 literal with optional :port (e.g. 8.8.8.8 or 8.8.8.8:53)\n"
                    .utf8))
        exit(1)
    }
    PodmDNSServer.upstream = parsed
} else if let envUpstream = ProcessInfo.processInfo.environment["PODM_DNS_UPSTREAM"]?
    .trimmingCharacters(in: .whitespacesAndNewlines), !envUpstream.isEmpty
{
    if let parsed = PodmDNSServer.parseUpstream(envUpstream) {
        PodmDNSServer.upstream = parsed
    } else {
        FileHandle.standardError.write(
            Data(
                "podm: ignoring invalid PODM_DNS_UPSTREAM '\(envUpstream)' — expected an IPv4 literal with optional :port; using default \(PodmDNSServer.upstream.ip)\n"
                    .utf8))
    }
}

if options.checkCompatibility {
    await AppleContainerVersionCheck.performCompatibilityCheck()
}

// Ignore real CLI args for Vapor: always behave like `podm serve`
let executable = CommandLine.arguments.first ?? "podm"
let vaporArgs = [executable, "serve"]

// Detect environment and set up logging
var env = try Environment.detect(arguments: vaporArgs)
try LoggingSystem.bootstrap(from: &env)

// Create and configure the Vapor application
let app = try await Application.make(env)
let homeDirectory = ProcessInfo.processInfo.environment["HOME"]

// Held for the process lifetime: refuses to start a second daemon against the same
// socket instead of silently stealing it out from under a still-running instance.
let instanceLock: SingleInstanceLock
do {
    instanceLock = try acquireSingleInstanceLock(homeDirectory: homeDirectory)
} catch let error as SingleInstanceError {
    FileHandle.standardError.write(Data("podm: \(error)\n".utf8))
    exit(1)
}

try prepareUnixSocket(for: app, homeDirectory: homeDirectory)
if options.dockerContext,
    let homeDir = homeDirectory,
    !homeDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
{
    DockerContextSetup.install(homeDirectory: homeDir)
}
app.storage[VolumeSyncModeKey.self] = Filesystem.SyncMode.resolve(from: options.volumeSync)
try await configure(app)

// Start the app
try await app.startup()
// Start the idle-exit monitor only now that the server is actually up — see
// configure() for why starting it any earlier burns its exit latch.
app.storage[IdleExitMonitorKey.self]?.start()
do {
    try openUnixSocketToAllUsers(homeDirectory: homeDirectory)
} catch {
    try? await app.asyncShutdown()
    throw error
}
try await app.running?.onStop.get()
withExtendedLifetime(instanceLock) {}
