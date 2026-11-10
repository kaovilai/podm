import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import podmd

/// The background journal-writer's lifecycle: armed through the registry, it
/// reads the container's log stream, records each completed line with its
/// arrival time, keeps following while the container runs, and stops (with a
/// final drain) once it no longer does. Driven through the registry's test
/// seams — a temp log file instead of Apple's XPC-backed stream, a mutable
/// mock client for the running/stopped check, and a temp-dir journal.
@Suite("ContainerLogFollower")
struct ContainerLogFollowerTests {

    /// ClientContainerProtocol mock whose reported status flips on demand.
    private final class StatusFlipMock: ClientContainerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func stopContainer() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
        private var snapshot: ContainerSnapshot {
            let proc = ProcessConfiguration(
                executable: "/bin/sh", arguments: [], environment: [],
                workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
            let img = ImageDescription(
                reference: "alpine:latest",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
            let config = ContainerConfiguration(id: "ctr", image: img, process: proc)
            lock.lock()
            defer { lock.unlock() }
            return ContainerSnapshot(configuration: config, status: stopped ? .stopped : .running, networks: [])
        }
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
        func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
        func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws {}
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws {}
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
            RESTContainerWait(statusCode: 0)
        }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
            ([], 0)
        }
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-follower-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Polls `condition` until true or the timeout passes.
    private func waitFor(
        _ condition: () async -> Bool,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    @Test("journals completed lines with arrival times and stops when the container stops")
    func followsUntilExit() async throws {
        let dir = tempDirectory()
        let logFile = dir.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let writer = try FileHandle(forWritingTo: logFile)

        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        let client = StatusFlipMock()
        let registry = ContainerLogFollowerRegistry.shared

        let before = ContainerLogJournal.currentUnixNano()
        await registry.arm(
            nativeId: "follower-test-ctr",
            client: client,
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in try FileHandle(forReadingFrom: logFile) }
        )
        try writer.write(contentsOf: Data("first\n".utf8))
        try writer.write(contentsOf: Data("second\npartial-no-newline".utf8))

        let journaled = await waitFor {
            await journal.entries(nativeId: "follower-test-ctr").count >= 2
        }
        #expect(journaled, "both complete lines should be journaled promptly")

        let entries = await journal.entries(nativeId: "follower-test-ctr")
        #expect(entries.map(\.bytes) == [Data("first\n".utf8), Data("second\n".utf8)], "partial line must not be journaled")
        #expect(entries.allSatisfy { $0.unixNano >= before }, "arrival timestamps must be recorded")

        // The container stops; the held-back partial line is completed and a
        // final line still gets drained and journaled, then the follower
        // exits and reaps itself from the registry.
        client.stopContainer()
        // The leading \n completes the pending partial as its own line first.
        try writer.write(contentsOf: Data("\nfinal\n".utf8))
        try? writer.close()

        let finished = await waitFor {
            let armed = await registry.isArmed(nativeId: "follower-test-ctr")
            return !armed
        }
        #expect(finished, "follower should reap itself after the container stops")

        let finalEntries = await journal.entries(nativeId: "follower-test-ctr")
        #expect(
            finalEntries.map(\.bytes) == [
                Data("first\n".utf8), Data("second\n".utf8),
                Data("partial-no-newline\n".utf8), Data("final\n".utf8),
            ], "the exit drain should journal the completed partial and the final line")
    }

    @Test("teardown disarms the follower and removes the journal")
    func teardown() async throws {
        let dir = tempDirectory()
        let journal = ContainerLogJournal()
        await journal.configure(storageDirectory: dir)
        await journal.append(
            nativeId: "teardown-ctr", epoch: 1,
            [ContainerLogJournal.Entry(unixNano: 1, streamType: 1, bytes: Data("x\n".utf8))],
            isCurrentEpoch: { true })
        let registry = ContainerLogFollowerRegistry.shared
        await registry.arm(
            nativeId: "teardown-ctr",
            client: StatusFlipMock(),
            logger: .init(label: "test"),
            freshBoot: true,
            journal: journal,
            openLogStream: { _ in FileHandle.nullDevice }
        )
        let armedBefore = await registry.isArmed(nativeId: "teardown-ctr")
        #expect(armedBefore)

        await ContainerLogFollowerRegistry.shared.disarm(nativeId: "teardown-ctr")
        await journal.remove(nativeId: "teardown-ctr")
        let cleared = await journal.entries(nativeId: "teardown-ctr")
        #expect(cleared.isEmpty)
        let armedAfter = await registry.isArmed(nativeId: "teardown-ctr")
        #expect(!armedAfter)
    }
}
