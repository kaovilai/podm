import Foundation
import Testing

@testable import podmd

/// Pins the serialization semantics the builder replacement fix relies on:
/// ONE admission instance serializes its holders (same-flavor builder
/// lookup/replace can't interleave — the actor-reentrancy bug), while TWO
/// instances (one per builder flavor) never block each other (a QEMU cold
/// start can't stall a Rosetta build whose builder already runs).
///
/// The test exercises `VMLifecycleAdmission` pairs directly:
/// `ClientBuilderService`'s per-flavor fields are two independent instances
/// of exactly this shape, and its container clients aren't injectable
/// without a wider refactor — the primitive-level pin plus CI's multi-arch
/// integration test (which really creates both builders) are the coverage.
@Suite("Builder replacement serialization semantics")
struct BuilderReplacementSerializationTests {

    @Test("One admission serializes holders; two admissions never block each other")
    func perFlavorSemantics() async throws {
        let rosettaSlot = VMLifecycleAdmission(limit: 1)
        let qemuSlot = VMLifecycleAdmission(limit: 1)

        actor Journal {
            var events: [String] = []
            func record(_ event: String) { events.append(event) }
            func get() -> [String] { events }
        }
        let journal = Journal()

        // Hold the Rosetta slot for a moment, recording entry/exit.
        let rosettaFirst = Task {
            try await rosettaSlot.withSlot {
                await journal.record("rosetta-1-enter")
                try await Task.sleep(for: .milliseconds(300))
                await journal.record("rosetta-1-exit")
            }
        }
        // Give the first holder a beat to actually enter the slot.
        try await Task.sleep(for: .milliseconds(50))

        // A SECOND same-flavor caller must queue behind the first.
        let rosettaSecond = Task {
            try await rosettaSlot.withSlot {
                await journal.record("rosetta-2-enter")
                await journal.record("rosetta-2-exit")
            }
        }
        // A different flavor's caller must NOT wait on the Rosetta hold.
        let qemuCaller = Task {
            try await qemuSlot.withSlot {
                await journal.record("qemu-enter")
                await journal.record("qemu-exit")
            }
        }

        _ = try await (rosettaFirst.value, rosettaSecond.value, qemuCaller.value)

        let events = await journal.get()
        // Same-flavor: the second holder entered only after the first exited.
        #expect(
            events.firstIndex(of: "rosetta-2-enter")! > events.firstIndex(of: "rosetta-1-exit")!,
            "a second same-flavor lookup must queue behind an in-flight replacement")
        // Cross-flavor: the QEMU caller completed while the Rosetta hold was
        // still active — per-flavor slots never block each other.
        #expect(
            events.firstIndex(of: "qemu-exit")! < events.firstIndex(of: "rosetta-1-exit")!,
            "a cold start on one flavor must not stall the other flavor")
        // And it really did enter before the hold ended (the assertion above
        // is vacuous if the QEMU caller somehow ran after everything).
        #expect(
            events.firstIndex(of: "qemu-enter")! < events.firstIndex(of: "rosetta-1-exit")!)
    }
}
