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

    @Test("A quota without a period uses the CFS default period of 100000")
    func quotaOnlyUsesDefaultPeriod() {
        // The CLIs send cpuperiod/cpuquota independently — podman documents
        // 100000 microseconds as the default period.
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: nil, cpuquota: 600_000).cpus == 6)
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: nil, cpuquota: 150_000).cpus == 2)
        // A non-positive period falls back to the default too.
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: 0, cpuquota: 600_000).cpus == 6)
        // A period alone still carries no CPU information.
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: 100_000, cpuquota: nil).cpus == 0)
    }

    @Test("An absurd quota cannot overflow the ceiling math")
    func absurdQuotaDoesNotTrap() {
        // Int64.max is a decodable positive Int on the wire; the naive
        // (quota + period - 1) would trap and kill the daemon.
        let request = BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: 2, cpuquota: Int(Int64.max))
        #expect(request.cpus > 0)
        // Clamped down to the host wherever it is used.
        let configured = BuilderResourceRequest(memoryInBytes: 2_147_483_648, cpus: 2)
        let desired = ClientBuilderService.desiredResources(requested: request, configured: configured, existing: nil)
        #expect(desired.cpus == BuilderResourceRequest.hostCPUsClamp)
    }

    @Test("partial or non-positive CFS values are handled")
    func partialCfsHandled() {
        // A period alone carries no CPU information.
        #expect(BuilderResourceRequest.fromQuery(memory: nil, cpuperiod: 100_000, cpuquota: nil).cpus == 0)
        // A non-positive quota is ignored entirely.
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

        // Host-relative: escalation clamps to the host's processor count.
        let cpuOnly = BuilderResourceRequest(memoryInBytes: 0, cpus: 6).escalated(over: configured)
        #expect(
            cpuOnly
                == BuilderResourceRequest(
                    memoryInBytes: 2_147_483_648, cpus: min(6, BuilderResourceRequest.hostCPUsClamp)))
    }

    @Test("desiredResources merges a request onto the floor, clamped to the host")
    func desiredMergesAndClamps() {
        let configured = BuilderResourceRequest(memoryInBytes: 2_147_483_648, cpus: 2)
        // Blank request: the floor unchanged.
        #expect(
            ClientBuilderService.desiredResources(
                requested: BuilderResourceRequest(memoryInBytes: 0, cpus: 0), configured: configured, existing: nil
            ) == configured)
        // No request at all: the floor unchanged.
        #expect(ClientBuilderService.desiredResources(requested: nil, configured: configured, existing: nil) == configured)
        // An absurd CPU ask clamps to the host's processor count.
        let clamped = ClientBuilderService.desiredResources(
            requested: BuilderResourceRequest(memoryInBytes: 0, cpus: 999_999), configured: configured, existing: nil)
        #expect(clamped.cpus == BuilderResourceRequest.hostCPUsClamp)
    }

    @Test("Replacement never shrinks a field the builder already has")
    func replacementNeverShrinks() {
        // Host-relative on BOTH fields: CI's macOS runners have as little as
        // 7 GiB RAM and 3 processors, and desiredResources clamps to the host.
        // The "big" allocation is what the host allows of 8 GiB / whatever it
        // allows of 6 vCPUs — still strictly above the 2 GiB / 2-vCPU floor.
        let bigMemory = min(8_589_934_592, BuilderResourceRequest.hostMemoryClamp)
        let bigCPUs = min(6, BuilderResourceRequest.hostCPUsClamp)
        let configured = BuilderResourceRequest(memoryInBytes: 2_147_483_648, cpus: 2)

        // A memory-rich builder (created by a memory-only ask) faced with a
        // CPU-only ask keeps its memory — per-field max with the existing
        // allocation folded in, not a redistribution.
        let existing = BuilderResourceRequest(memoryInBytes: bigMemory, cpus: 2)
        let cpuOnlyAsk = BuilderResourceRequest(memoryInBytes: 0, cpus: 4)
        let desired = ClientBuilderService.desiredResources(
            requested: cpuOnlyAsk, configured: configured, existing: existing)
        #expect(desired.memoryInBytes == bigMemory)
        #expect(desired.cpus == min(4, BuilderResourceRequest.hostCPUsClamp))

        // And the reverse: a memory-only ask keeps extra vCPUs the builder has.
        let memoryOnlyAsk = BuilderResourceRequest(memoryInBytes: 4_294_967_296, cpus: 0)
        let existingFatCPUs = BuilderResourceRequest(memoryInBytes: 2_147_483_648, cpus: bigCPUs)
        let desired2 = ClientBuilderService.desiredResources(
            requested: memoryOnlyAsk, configured: configured, existing: existingFatCPUs)
        #expect(desired2.memoryInBytes == 4_294_967_296)
        #expect(desired2.cpus == bigCPUs)

        // An existing allocation above the env floor is never pulled back down.
        let unflagged = ClientBuilderService.desiredResources(requested: nil, configured: configured, existing: existing)
        #expect(unflagged == BuilderResourceRequest(memoryInBytes: bigMemory, cpus: 2))
    }

    // MARK: - Env knobs

    @Test("Env knobs provision per flavor, defaults when absent")
    func envProvision() {
        // CPU expectations are host-relative: provision clamps to the host's
        // processor count, which is 3 on CI's smaller macOS runners.
        let env = [
            "PODM_BUILDER_CPUS": "6",
            "PODM_BUILDER_MEMORY": "6g",
            "PODM_QEMU_BUILDER_CPUS": "4",
            "PODM_QEMU_BUILDER_MEMORY": "4096MB",
        ]
        let rosetta = BuilderResourceKnobs.provision(qemu: false, env: env)
        #expect(rosetta.cpus == min(6, BuilderResourceRequest.hostCPUsClamp))
        #expect(rosetta.memoryInBytes == 6 << 30)
        let qemu = BuilderResourceKnobs.provision(qemu: true, env: env)
        #expect(qemu.cpus == min(4, BuilderResourceRequest.hostCPUsClamp))
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
