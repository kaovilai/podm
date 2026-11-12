import Testing

@testable import podmd

/// Build-resource sizing: the explicit per-build ask decoded from the wire
/// (both CLIs send memory + cpuperiod/cpuquota only when the user passes
/// --memory / --cpu-quota / --cpu-period), the daemon-level env knobs, and
/// the escalation rule that sizes builder VMs.
@Suite("Builder resource knobs and requests")
struct BuilderResourcesTests {

    // MARK: - Wire decoding

    @Test("No resource flags decode to a blank request")
    func blankWhenNoFlags() {
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: nil, cpuquota: nil).isBlank)
    }

    @Test("memory decodes verbatim from bytes")
    func memoryOnly() {
        let request = BuilderResourceRequest.fromQuery(memory: 4_294_967_296, cpuperiod: nil, cpuquota: nil)
        #expect(request.memoryInBytes == 4_294_967_296)
        #expect(request.cpus == 0)
        #expect(!request.isBlank)
    }

    @Test("cpus is ceil(quota / period)")
    func cpusFromQuotaPeriod() {
        // 150000/100000 = 1.5 vCPU -> 2
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: 100_000, cpuquota: 150_000).cpus == 2)
        // 300000/100000 = 3 vCPU exactly
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: 100_000, cpuquota: 300_000).cpus == 3)
        // quota smaller than one period still means one vCPU
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: 100_000, cpuquota: 1).cpus == 1)
    }

    @Test("partial or non-positive CFS values are ignored")
    func partialCfsIgnored() {
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: 100_000, cpuquota: nil).cpus == 0)
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: nil, cpuquota: 300_000).cpus == 0)
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: 0, cpuquota: 300_000).cpus == 0)
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: 100_000, cpuquota: -1).cpus == 0)
        #expect(BuilderResourceRequest.fromQuery(memory: -5, cpuperiod: nil, cpuquota: nil).isBlank)
    }

    // MARK: - Escalation

    @Test("A blank request never escalates")
    func blankDoesNotEscalate() {
        let configured = BuilderResourceRequest(memoryInBytes: 2_147_483_648, cpus: 2)
        #expect(BuilderResourceRequest(memoryInBytes: 0, cpus: 0).escalated(over: configured) == nil)
    }

    @Test("A request covered by the configured size never escalates")
    func coveredDoesNotEscalate() {
        let configured = BuilderResourceRequest(memoryInBytes: 8_589_934_592, cpus: 4)
        #expect(BuilderResourceRequest(memoryInBytes: 4_294_967_296, cpus: 2).escalated(over: configured) == nil)
        #expect(BuilderResourceRequest(memoryInBytes: 0, cpus: 4).escalated(over: configured) == nil)
    }

    @Test("An exceeding request escalates per field, keeping the larger floor")
    func exceedingEscalatesPerField() {
        let configured = BuilderResourceRequest(memoryInBytes: 2_147_483_648, cpus: 2)
        let escalated = BuilderResourceRequest(memoryInBytes: 4_294_967_296, cpus: 0).escalated(over: configured)
        #expect(escalated == BuilderResourceRequest(memoryInBytes: 4_294_967_296, cpus: 2))

        let cpuOnly = BuilderResourceRequest(memoryInBytes: 0, cpus: 6).escalated(over: configured)
        #expect(cpuOnly == BuilderResourceRequest(memoryInBytes: 2_147_483_648, cpus: 6))
    }

    @Test("desiredResources merges a request onto the floor, clamped to the host")
    func desiredMergesAndClamps() {
        let configured = BuilderResourceRequest(memoryInBytes: 2_147_483_648, cpus: 2)
        // Blank request: the floor unchanged.
        #expect(
            ClientBuilderService.desiredResources(
                requested: BuilderResourceRequest(memoryInBytes: 0, cpus: 0), configured: configured
            ) == configured)
        // No request at all: the floor unchanged.
        #expect(ClientBuilderService.desiredResources(requested: nil, configured: configured) == configured)
        // An absurd CPU ask clamps to the host's processor count.
        let clamped = ClientBuilderService.desiredResources(
            requested: BuilderResourceRequest(memoryInBytes: 0, cpus: 999_999), configured: configured)
        #expect(clamped.cpus == BuilderResourceRequest.hostCPUsClamp)
    }

    // MARK: - Env knobs

    @Test("Env knobs provision per flavor, defaults when absent")
    func envProvision() {
        let env = [
            "PODM_BUILDER_CPUS": "6",
            "PODM_BUILDER_MEMORY": "6g",
            "PODM_QEMU_BUILDER_CPUS": "4",
            "PODM_QEMU_BUILDER_MEMORY": "4096MB",
        ]
        let rosetta = BuilderResourceKnobs.provision(qemu: false, env: env)
        #expect(rosetta.cpus == 6)
        #expect(rosetta.memoryInBytes == 6 << 30)
        let qemu = BuilderResourceKnobs.provision(qemu: true, env: env)
        #expect(qemu.cpus == 4)
        #expect(qemu.memoryInBytes == 4_294_967_296)
    }

    @Test("Absent or invalid env values fall back to the 2 vCPU / 2048 MiB default")
    func envFallbacks() {
        let defaults = BuilderResourceKnobs.provision(qemu: false, env: [:])
        #expect(
            defaults
                == BuilderResourceRequest(
                    memoryInBytes: BuilderResourceKnobs.defaultMemoryInBytes, cpus: BuilderResourceKnobs.defaultCPUs))

        let invalid = BuilderResourceKnobs.provision(
            qemu: false,
            env: [
                "PODM_BUILDER_CPUS": "not-a-number",
                "PODM_BUILDER_MEMORY": "banana",
            ])
        #expect(invalid == defaults)
    }

    @Test("Memory accepts bare bytes, binary suffixes, and case-insensitive units")
    func memoryParsing() {
        #expect(BuilderResourceKnobs.memoryInBytes("4294967296") == 4_294_967_296)
        #expect(BuilderResourceKnobs.memoryInBytes("4096m") == 4_294_967_296)
        #expect(BuilderResourceKnobs.memoryInBytes("4G") == 4_294_967_296)
        #expect(BuilderResourceKnobs.memoryInBytes("2 GB") == 2_147_483_648)
        #expect(BuilderResourceKnobs.memoryInBytes("512k") == 524_288)
        #expect(BuilderResourceKnobs.memoryInBytes(nil) == nil)
        #expect(BuilderResourceKnobs.memoryInBytes("") == nil)
        #expect(BuilderResourceKnobs.memoryInBytes("12x") == nil)
        #expect(BuilderResourceKnobs.memoryInBytes("0") == nil)
        #expect(BuilderResourceKnobs.memoryInBytes("-4g") == nil)
    }

    @Test("Env knobs clamp to the host so a typo can't ask for the impossible")
    func envClampedToHost() {
        let env = [
            "PODM_BUILDER_CPUS": "9999",
            "PODM_BUILDER_MEMORY": "999999999g",
        ]
        let provision = BuilderResourceKnobs.provision(qemu: false, env: env)
        #expect(provision.cpus == BuilderResourceRequest.hostCPUsClamp)
        #expect(provision.memoryInBytes == BuilderResourceRequest.hostMemoryClamp)
    }
}
