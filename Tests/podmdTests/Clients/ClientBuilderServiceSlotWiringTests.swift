import ContainerPersistence
import Foundation
import Testing

@testable import podmd

/// The service wiring: each flavor must serialize through its OWN slot.
/// This is the regression test for the shared-slot mistake — it fails if
/// both flavors ever resolve to the same admission instance.
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
