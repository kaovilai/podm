import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import Testing

@testable import podmd

/// The service wiring: each flavor must serialize through its OWN slot.
/// This is the regression test for the shared-slot mistake — it fails if
/// both flavors ever resolve to the same admission instance.
///
/// The admission primitive's own semantics (same-instance serialization,
/// FIFO handoff, cancellation correctness) are covered deterministically by
/// VMLifecycleAdmissionTests — a separate sleep-timing test here was
/// runner-stall-flaky (the classic macOS-runner class) and added nothing.
@Suite("ClientBuilderService replacement slot wiring")
struct BuilderReplacementSlotWiringTests {

    @Test("Rosetta and QEMU serialize through distinct slots, stably")
    func flavors() async throws {
        let service = ClientBuilderService(
            appSupportURL: URL(fileURLWithPath: "/tmp"),
            containerSystemConfig: ContainerSystemConfig()
        )
        let rosetta = service.replacementSerializer(forQEMU: false)
        let qemu = service.replacementSerializer(forQEMU: true)
        // Distinct instances: a cold start on one flavor cannot hold the
        // other flavor's slot.
        #expect(rosetta !== qemu, "the two builder flavors must not share a replacement slot")
        // Stable across calls: same flavor always resolves to its own slot.
        #expect(service.replacementSerializer(forQEMU: false) === rosetta)
        #expect(service.replacementSerializer(forQEMU: true) === qemu)
    }
}

/// The role label — not the name — is a builder's identity: an ordinary
/// container named `buildkit` must never be treated as a builder by the
/// sizing or lifecycle paths (the replacement branch would stop and delete
/// it, destroying its writable disk).
@Suite("ClientBuilderService builder identity")
struct ClientBuilderServiceIdentityTests {

    @Test("Only role-labeled containers are podm builders, regardless of name")
    func builderIdentity() throws {
        let builder = try makeContainerSnapshot(
            nativeId: "buildkit", networks: [],
            labels: [ResourceLabelKeys.role: ResourceRoleValues.builder])
        #expect(ClientBuilderService.isPodmBuilder(builder))

        // An ordinary container with the builder's name: NOT a builder.
        let ordinary = try makeContainerSnapshot(
            nativeId: "buildkit", networks: [], labels: [:])
        #expect(!ClientBuilderService.isPodmBuilder(ordinary))

        // Same name, unrelated labels: NOT a builder.
        let labeled = try makeContainerSnapshot(
            nativeId: "buildkit", networks: [],
            labels: ["com.example.owner": "team-a"])
        #expect(!ClientBuilderService.isPodmBuilder(labeled))

        // Any other name with the builder role: a builder.
        let renamed = try makeContainerSnapshot(
            nativeId: "some-other-id", networks: [],
            labels: [ResourceLabelKeys.role: ResourceRoleValues.builder])
        #expect(ClientBuilderService.isPodmBuilder(renamed))
    }
}
