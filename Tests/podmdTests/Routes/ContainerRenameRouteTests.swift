import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

private struct RenameMock: ClientContainerProtocol {
    let snapshots: [ContainerSnapshot]
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { snapshots }
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        // Native-id exact match only — hex-prefix resolution semantics are
        // covered by the resolution tests; rename cares about names.
        snapshots.first { $0.id == id }
    }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws -> Bool { true }
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws -> Bool { true }
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private struct RenameErrorBody: Vapor.Content { let reason: String }

@Suite("ContainerRenameRoute", .serialized)
struct ContainerRenameRouteTests {
    private func makeStoppedSnapshot(id: String) throws -> ContainerSnapshot {
        try makeContainerSnapshot(nativeId: id, networks: [], labels: [:])
    }

    private func withRenameApp(
        _ snapshots: [ContainerSnapshot],
        dnsServer: PodmDNSServer? = nil,
        broadcaster: EventBroadcaster? = nil,
        libpod: Bool = false,
        run: (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.middleware.use(ErrorMiddleware.default(environment: app.environment))
            if let dnsServer { app.storage[PodmDNSServerKey.self] = dnsServer }
            if let broadcaster { app.storage[EventBroadcasterKey.self] = broadcaster }
            let mock = RenameMock(snapshots: snapshots)
            try app.register(
                collection: libpod
                    ? LibpodContainerRenameRoute(client: mock)
                    : ContainerRenameRoute(client: mock))
            try await run(app)
        }
    }

    @Test("a successful rename records an override and answers 204 No Content")
    func renameSucceeds() async throws {
        let id = "rename-ctr-\(UUID().uuidString.prefix(8).lowercased())"
        let snapshot = try makeStoppedSnapshot(id: id)
        let hexId = DockerContainerID.hexId(for: snapshot)
        defer { Task { await ContainerNameOverrideStore.shared.remove(hexId: hexId) } }
        try await withRenameApp([snapshot]) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename?name=\(id)-renamed") { res async in
                #expect(res.status == .noContent)
            }
        }
        let stored = await ContainerNameOverrideStore.shared.get(hexId: hexId)
        #expect(stored == "\(id)-renamed")
        let effective = await ContainerNameOverrideStore.effectiveName(for: snapshot)
        #expect(effective == "\(id)-renamed")
    }

    @Test("the libpod dialect dispatches to the same handler")
    func libpodDialect() async throws {
        let id = "rename-lp-\(UUID().uuidString.prefix(8).lowercased())"
        let snapshot = try makeStoppedSnapshot(id: id)
        let hexId = DockerContainerID.hexId(for: snapshot)
        defer { Task { await ContainerNameOverrideStore.shared.remove(hexId: hexId) } }
        try await withRenameApp([snapshot], libpod: true) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/\(id)/rename?name=\(id)-renamed") { res async in
                #expect(res.status == .noContent)
            }
        }
        let stored = await ContainerNameOverrideStore.shared.get(hexId: hexId)
        #expect(stored == "\(id)-renamed")
    }

    @Test("an unknown container answers 404")
    func unknownContainer() async throws {
        let snapshot = try makeStoppedSnapshot(id: "exists")
        try await withRenameApp([snapshot]) { app in
            try await app.testing().test(.POST, "/v1.51/containers/ghost/rename?name=new-name") { res async throws in
                #expect(res.status == .notFound)
                let body = try res.content.decode(RenameErrorBody.self)
                #expect(body.reason.contains("No such container"))
            }
        }
    }

    @Test("a missing or empty name answers 400")
    func missingOrEmptyName() async throws {
        let id = "rename-empty-\(UUID().uuidString.prefix(8).lowercased())"
        let snapshot = try makeStoppedSnapshot(id: id)
        try await withRenameApp([snapshot]) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename") { res async throws in
                #expect(res.status == .badRequest)
                let body = try res.content.decode(RenameErrorBody.self)
                #expect(body.reason.contains("may be empty"))
            }
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename?name=") { res async in
                #expect(res.status == .badRequest)
            }
        }
        let hexId = DockerContainerID.hexId(for: snapshot)
        let stored = await ContainerNameOverrideStore.shared.get(hexId: hexId)
        #expect(stored == nil)
    }

    @Test("an invalid name answers 400")
    func invalidName() async throws {
        let id = "rename-bad-\(UUID().uuidString.prefix(8).lowercased())"
        let snapshot = try makeStoppedSnapshot(id: id)
        try await withRenameApp([snapshot]) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename?name=bad%20name!") { res async throws in
                #expect(res.status == .badRequest)
                let body = try res.content.decode(RenameErrorBody.self)
                // moby's reserveName message shape (daemon/names.go).
                #expect(body.reason.contains("Invalid container name (bad name!)"))
                #expect(body.reason.contains("[a-zA-Z0-9][a-zA-Z0-9_.-] are allowed"))
            }
        }
        let hexId = DockerContainerID.hexId(for: snapshot)
        let stored = await ContainerNameOverrideStore.shared.get(hexId: hexId)
        #expect(stored == nil)
    }

    @Test("renaming to the current effective name answers 400")
    func sameNameRejected() async throws {
        let id = "rename-same-\(UUID().uuidString.prefix(8).lowercased())"
        let snapshot = try makeStoppedSnapshot(id: id)
        try await withRenameApp([snapshot]) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename?name=\(id)") { res async throws in
                #expect(res.status == .badRequest)
                let body = try res.content.decode(RenameErrorBody.self)
                #expect(body.reason.contains("same name"))
            }
        }
        let hexId = DockerContainerID.hexId(for: snapshot)
        let stored = await ContainerNameOverrideStore.shared.get(hexId: hexId)
        #expect(stored == nil)
    }

    @Test("a name taken by another container's native id answers 409 with moby's conflict message")
    func conflictWithNativeName() async throws {
        let first = try makeStoppedSnapshot(id: "rename-owner-\(UUID().uuidString.prefix(6).lowercased())")
        let second = try makeStoppedSnapshot(id: "rename-taker-\(UUID().uuidString.prefix(6).lowercased())")
        let firstHex = DockerContainerID.hexId(for: first)
        try await withRenameApp([first, second]) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(second.id)/rename?name=\(first.id)") { res async throws in
                #expect(res.status == .conflict)
                let body = try res.content.decode(RenameErrorBody.self)
                // moby's nameConflictError shape (daemon/errors.go): the
                // taken name (canonicalized with a leading slash) and the
                // full Docker id of the container that holds it.
                #expect(
                    body.reason
                        == "Error when allocating new name: Conflict. The container name \"/\(first.id)\" is already in use by container \"\(firstHex)\". You have to remove (or rename) that container to be able to reuse that name."
                )
            }
        }
        let hexId = DockerContainerID.hexId(for: second)
        let stored = await ContainerNameOverrideStore.shared.get(hexId: hexId)
        #expect(stored == nil)
    }

    @Test("a name taken by another container's rename override answers 409 — native id stays reserved too")
    func conflictWithOverrideAndShadowedNative() async throws {
        let first = try makeStoppedSnapshot(id: "rename-a-\(UUID().uuidString.prefix(6).lowercased())")
        let second = try makeStoppedSnapshot(id: "rename-b-\(UUID().uuidString.prefix(6).lowercased())")
        let firstHex = DockerContainerID.hexId(for: first)
        await ContainerNameOverrideStore.shared.set(hexId: firstHex, name: "\(first.id)-renamed")
        defer { Task { await ContainerNameOverrideStore.shared.remove(hexId: firstHex) } }
        try await withRenameApp([first, second]) { app in
            // The overridden name is taken — and the 409 names the override's
            // owner, like moby's nameConflictError.
            try await app.testing().test(.POST, "/v1.51/containers/\(second.id)/rename?name=\(first.id)-renamed") { res async throws in
                #expect(res.status == .conflict)
                let body = try res.content.decode(RenameErrorBody.self)
                #expect(
                    body.reason
                        == "Error when allocating new name: Conflict. The container name \"/\(first.id)-renamed\" is already in use by container \"\(firstHex)\". You have to remove (or rename) that container to be able to reuse that name."
                )
            }
            // The shadowed native id is still resolvable, so it stays reserved
            // — unlike moby, a rename cannot free a native id.
            try await app.testing().test(.POST, "/v1.51/containers/\(second.id)/rename?name=\(first.id)") { res async in
                #expect(res.status == .conflict)
            }
        }
        let secondHex = DockerContainerID.hexId(for: second)
        let stored = await ContainerNameOverrideStore.shared.get(hexId: secondHex)
        #expect(stored == nil)
    }

    @Test("a rename emits a container 'rename' event with oldName and new name")
    func renameEmitsEvent() async throws {
        let id = "rename-evt-\(UUID().uuidString.prefix(8).lowercased())"
        let snapshot = try makeStoppedSnapshot(id: id)
        let hexId = DockerContainerID.hexId(for: snapshot)
        defer { Task { await ContainerNameOverrideStore.shared.remove(hexId: hexId) } }
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "rename" { return event }
            return nil
        }
        try await withRenameApp([snapshot], broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename?name=\(id)-renamed") { res async in
                #expect(res.status == .noContent)
            }
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            captureTask.cancel()
        }
        let event = await captureTask.value
        timeoutTask.cancel()
        #expect(event?.Type == "container")
        #expect(event?.Actor.ID == hexId)
        #expect(event?.Actor.Attributes["name"] == "\(id)-renamed")
        // moby's attribute key is "oldName" (daemon/rename.go
        // LogContainerEventWithAttributes), not snake_case — and the value
        // carries the name registry's leading slash: "/<name>".
        #expect(event?.Actor.Attributes["oldName"] == "/\(id)")
    }

    @Test("a running container's DNS alias swaps from the old name to the new one")
    func dnsAliasSwaps() async throws {
        let id = "rename-dns-\(UUID().uuidString.prefix(8).lowercased())"
        let snapshot = try makeContainerSnapshot(
            nativeId: id, networks: [("mynet", "192.168.64.5")], labels: [:], status: .running)
        let hexId = DockerContainerID.hexId(for: snapshot)
        defer { Task { await ContainerNameOverrideStore.shared.remove(hexId: hexId) } }
        let dnsServer = PodmDNSServer()
        dnsServer.register(hostname: id, ip: "192.168.64.5")
        try await withRenameApp([snapshot], dnsServer: dnsServer) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename?name=\(id)-renamed") { res async in
                #expect(res.status == .noContent)
            }
        }
        let entries = dnsServer.listEntries()
        #expect(entries["\(id)-renamed"] == "192.168.64.5")
        // The native id stays registered: restart and daemon-resume register
        // both it and the override, and the API keeps native ids resolvable —
        // DNS must not diverge from that. Only a previous OVERRIDE name is
        // swapped out (covered by the second-rename case below).
        #expect(entries[id] == "192.168.64.5")
    }

    @Test("a second rename swaps out only the previous override name, not the native id")
    func secondRenameSwapsOverrideOnly() async throws {
        let id = "rename-dns2-\(UUID().uuidString.prefix(8).lowercased())"
        let snapshot = try makeContainerSnapshot(
            nativeId: id, networks: [("mynet", "192.168.64.5")], labels: [:], status: .running)
        let hexId = DockerContainerID.hexId(for: snapshot)
        defer { Task { await ContainerNameOverrideStore.shared.remove(hexId: hexId) } }
        let dnsServer = PodmDNSServer()
        dnsServer.register(hostname: id, ip: "192.168.64.5")
        try await withRenameApp([snapshot], dnsServer: dnsServer) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename?name=\(id)-first") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename?name=\(id)-second") { res async in
                #expect(res.status == .noContent)
            }
        }
        let entries = dnsServer.listEntries()
        #expect(entries["\(id)-second"] == "192.168.64.5")
        #expect(entries["\(id)-first"] == nil, "the previous override name is swapped out")
        #expect(entries[id] == "192.168.64.5", "the native id survives every rename")
    }

}
