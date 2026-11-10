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
        let ok = await store.claim(hexId: a, name: "api", reserved: ["other-native", "otherhex"])
        #expect(ok == true)
        let stolen = await store.claim(hexId: b, name: "api", reserved: [])
        #expect(stolen == false)
        let owner = await store.get(hexId: a)
        #expect(owner == "api")
        let loser = await store.get(hexId: b)
        #expect(loser == nil)
    }

    @Test("claim rejects names in the reserved set (native ids and hex ids)")
    func claimRespectsReserved() async throws {
        let store = ContainerNameOverrideStore()
        let id = DockerContainerID.hexId(nativeId: "web", createdAt: Date(timeIntervalSince1970: 1_000))
        let reserved = await store.claim(hexId: id, name: "db", reserved: ["db"])
        #expect(reserved == false)
        let taken = await store.isTaken(name: "db")
        #expect(taken == false)
    }

    @Test("isTaken reflects recorded overrides for create-side checks")
    func isTakenSeesOverrides() async throws {
        let store = ContainerNameOverrideStore()
        let id = "istaken-\(UUID().uuidString.prefix(8).lowercased())"
        await store.set(hexId: id, name: "claimed-name")
        let taken = await store.isTaken(name: "claimed-name")
        #expect(taken == true)
        let free = await store.isTaken(name: "unclaimed")
        #expect(free == false)
        await store.remove(hexId: id)
        let released = await store.isTaken(name: "claimed-name")
        #expect(released == false)
    }
}
