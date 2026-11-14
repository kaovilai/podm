import ContainerizationOCI
import Foundation
import Testing

@testable import podmd

/// `docker run --platform linux/s390x` used to be accepted and quietly ran the
/// ARM64 image; `podman run --platform linux/s390x` pulled the s390x layers and
/// then stalled before an opaque failure. Apple's VM executes the host
/// architecture natively and amd64 via Rosetta — everything else is build-only.
@Suite("ContainerCreateRoute — runnable-platform validation")
struct RunnablePlatformValidationTests {

    private var host: Platform { Platform.current }

    @Test("the host architecture is runnable")
    func hostArchitecture() {
        #expect(ContainerCreateRoute.validateRunnablePlatform(host) == nil)
    }

    @Test("amd64 is runnable on an arm64 host (Rosetta)")
    func amd64OnArm64() throws {
        guard Platform.current.architecture == "arm64" else { return }
        #expect(ContainerCreateRoute.validateRunnablePlatform(try Platform(from: "linux/amd64")) == nil)
    }

    @Test("a build-only architecture is rejected with the remedy")
    func buildOnlyArchitecture() throws {
        let message = try #require(ContainerCreateRoute.validateRunnablePlatform(try Platform(from: "linux/s390x")))
        #expect(message.contains("linux/s390x"))
        #expect(message.contains("build-only"))
        #expect(message.contains("docker build --platform linux/s390x"))
    }

    @Test("a non-Linux OS is rejected")
    func nonLinuxRejected() {
        let message = ContainerCreateRoute.validateRunnablePlatform(Platform(arch: Platform.current.architecture, os: "windows", variant: nil))
        #expect(message?.contains("windows") == true)
    }
}

/// `--cpus` is a fractional CFS quota in Docker; a podm container's VM is
/// provisioned whole vCPUs, so `--cpus 0.5` silently became 1 vCPU. The create
/// response now says so (docker prints create warnings).
@Suite("ContainerCreateRoute — fractional --cpus warnings")
struct FractionalCpuWarningTests {

    private func hostConfig(nanoCpus: Int) throws -> HostConfig {
        try JSONDecoder().decode(HostConfig.self, from: Data("{\"NanoCpus\":\(nanoCpus)}".utf8))
    }

    @Test("a fractional cap warns with the granted vCPU count")
    func fractionalWarns() throws {
        let warnings = ContainerCreateRoute.cpuWarnings(hostConfig: try hostConfig(nanoCpus: 500_000_000))
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("--cpus 0.5") == true)
        #expect(warnings.first?.contains("1 vCPU") == true)
    }

    @Test("a whole-number cap matching the granted vCPUs is silent")
    func exactIsSilent() throws {
        #expect(try ContainerCreateRoute.cpuWarnings(hostConfig: hostConfig(nanoCpus: 2_000_000_000)).isEmpty)
    }

    @Test("no cap at all is silent")
    func noCapSilent() throws {
        #expect(try ContainerCreateRoute.cpuWarnings(hostConfig: hostConfig(nanoCpus: 0)).isEmpty)
        #expect(ContainerCreateRoute.cpuWarnings(hostConfig: nil).isEmpty)
    }
}
