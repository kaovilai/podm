import Foundation
import Testing

@testable import podmd

/// ContainerNameOverrideStore semantics: instance-unique keys, disk
/// persistence, and the atomic claim that rename (and create's isTaken
/// check) rely on for name reservation.
@Suite("ContainerNameOverrideStore")
struct ContainerNameOverrideStoreTests {
    @Test("the override wins over the native id; a recreated instance gets a fresh key")
    func overridePrecedence() async throws {
        let firstInstance = DockerContainerID.hexId(nativeId: "web", createdAt: Date(timeIntervalSince1970: 1_000))
        let recreatedInstance = DockerContainerID.hexId(nativeId: "web", createdAt: Date(timeIntervalSince1970: 2_000))
        let before = await ContainerNameOverrideStore.shared.get(hexId: firstInstance)
        #expect(before == nil)
        await ContainerNameOverrideStore.shared.set(hexId: firstInstance, name: "web2")
        let overridden = await ContainerNameOverrideStore.shared.get(hexId: firstInstance)
        #expect(overridden == "web2")
        let recreated = await ContainerNameOverrideStore.shared.get(hexId: recreatedInstance)
        #expect(recreated == nil)
        await ContainerNameOverrideStore.shared.remove(hexId: firstInstance)
        let restored = await ContainerNameOverrideStore.shared.get(hexId: firstInstance)
        #expect(restored == nil)
    }

    @Test("renames survive a store reload from disk")
    func overridePersistence() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("name-override-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "rename-persist-\(UUID().uuidString.prefix(8).lowercased())"
        let store = ContainerNameOverrideStore()
        await store.configure(storageDirectory: dir)
        await store.set(hexId: id, name: "persisted-name")
        let reloadedStore = ContainerNameOverrideStore()
        await reloadedStore.configure(storageDirectory: dir)
        let reloaded = await reloadedStore.get(hexId: id)
        #expect(reloaded == "persisted-name")
    }

    @Test("claim succeeds when the name is free and reserves it")
    func claimSucceeds() async throws {
        let store = ContainerNameOverrideStore()
        let a = DockerContainerID.hexId(nativeId: "web", createdAt: Date(timeIntervalSince1970: 1_000))
        let b = DockerContainerID.hexId(nativeId: "db", createdAt: Date(timeIntervalSince1970: 1_000))
        let ok = await store.claim(hexId: a, name: "api", expectedOverride: nil, reserved: ["other-native", "otherhex"])
        #expect(ok == true)
        let stolen = await store.claim(hexId: b, name: "api", expectedOverride: nil, reserved: [])
        #expect(stolen == false)
        let owner = await store.get(hexId: a)
        #expect(owner == "api")
        let loser = await store.get(hexId: b)
        #expect(loser == nil)
    }

    @Test("claim's compare-and-swap rejects a rename whose old name is stale")
    func claimCasRejectsStaleOldName() async throws {
        let store = ContainerNameOverrideStore()
        let hex = DockerContainerID.hexId(nativeId: "web", createdAt: Date(timeIntervalSince1970: 1_000))
        // Both requests read override=nil (current name "web"); the first
        // claims "api". The second (to "backend") must fail the CAS — its
        // expected override is stale — so it can not publish a stale old
        // name or leave an abandoned DNS alias.
        let first = await store.claim(hexId: hex, name: "api", expectedOverride: nil, reserved: [])
        #expect(first == true)
        let second = await store.claim(hexId: hex, name: "backend", expectedOverride: nil, reserved: [])
        #expect(second == false)
        let winner = await store.get(hexId: hex)
        #expect(winner == "api")
    }

    @Test("pending-create reservations block renames and are released")
    func pendingCreateReservations() async throws {
        let store = ContainerNameOverrideStore()
        let reserved = await store.reserveForCreate(name: "fresh-name")
        #expect(reserved == true)
        let hex = DockerContainerID.hexId(nativeId: "web", createdAt: Date(timeIntervalSince1970: 1_000))
        let renameBlocked = await store.claim(hexId: hex, name: "fresh-name", expectedOverride: nil, reserved: [])
        #expect(renameBlocked == false)
        let doubleReserve = await store.reserveForCreate(name: "fresh-name")
        #expect(doubleReserve == false)
        await store.releaseCreateReservation(name: "fresh-name")
        let renameAfterRelease = await store.claim(hexId: hex, name: "fresh-name", expectedOverride: nil, reserved: [])
        #expect(renameAfterRelease == true)
    }

    @Test("a claim for a deleted (tombstoned) container fails even with a stale read")
    func tombstonedClaimsFail() async throws {
        let store = ContainerNameOverrideStore()
        let hex = DockerContainerID.hexId(nativeId: "web", createdAt: Date(timeIntervalSince1970: 1_000))
        await store.set(hexId: hex, name: "api")
        // A rename read override "api" and suspended; prune deleted the
        // container and removed (tombstoned) the key. The rename's later
        // claim — even with the matching expectedOverride — must fail, or it
        // persists a name for a container that no longer exists.
        await store.remove(hexId: hex)
        let claimAfterDelete = await store.claim(hexId: hex, name: "backend", expectedOverride: "api", reserved: [])
        #expect(claimAfterDelete == false)
        let stored = await store.get(hexId: hex)
        #expect(stored == nil)
    }

    @Test("claim rejects names in the reserved set (native ids and hex ids)")
    func claimRespectsReserved() async throws {
        let store = ContainerNameOverrideStore()
        let id = DockerContainerID.hexId(nativeId: "web", createdAt: Date(timeIntervalSince1970: 1_000))
        let reserved = await store.claim(hexId: id, name: "db", expectedOverride: nil, reserved: ["db"])
        #expect(reserved == false)
        // The rejected claim reserved nothing: a create can still take "db".
        let createable = await store.reserveForCreate(name: "db")
        #expect(createable == true)
    }

    @Test("a recorded override blocks a create reservation until removed")
    func overridesBlockCreateReservations() async throws {
        let store = ContainerNameOverrideStore()
        let id = "istaken-\(UUID().uuidString.prefix(8).lowercased())"
        await store.set(hexId: id, name: "claimed-name")
        let blocked = await store.reserveForCreate(name: "claimed-name")
        #expect(blocked == false)
        let free = await store.reserveForCreate(name: "unclaimed")
        #expect(free == true)
        await store.remove(hexId: id)
        let released = await store.reserveForCreate(name: "claimed-name")
        #expect(released == true)
    }
}
