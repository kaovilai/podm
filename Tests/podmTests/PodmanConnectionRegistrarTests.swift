// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import podm

/// `podm install` must register podm as a selectable podman system
/// connection — never touching the default (issue #47).
@Suite("PodmanConnectionRegistrar")
struct PodmanConnectionRegistrarTests {

    /// Records every spawned command; answers from a scripted exit-status
    /// map keyed by the subcommand verb.
    private final class SpawnRecorder {
        private(set) var calls: [(executable: String, arguments: [String])] = []
        private let statuses: [String: Int32]

        init(statuses: [String: Int32] = [:]) {
            self.statuses = statuses
        }

        var spawn: PodmanConnectionRegistrar.Spawn {
            { [self] executable, arguments in
                self.calls.append((executable, arguments))
                // Key on the verb after "system connection".
                let verb = arguments.count >= 3 ? arguments[2] : ""
                return (self.statuses[verb] ?? 0, "")
            }
        }
    }

    @Test("register removes any existing connection first, then adds with the socket uri")
    func registerSequence() {
        let recorder = SpawnRecorder()

        let registered = PodmanConnectionRegistrar.register(
            podmanPath: "/opt/podman/bin/podman",
            uri: "unix:///home/user/.podm/container.sock",
            spawn: recorder.spawn)

        #expect(registered)
        #expect(recorder.calls.count == 2)
        #expect(recorder.calls[0].arguments == ["system", "connection", "remove", "podm"])
        #expect(
            recorder.calls[1].arguments
                == ["system", "connection", "add", "podm", "unix:///home/user/.podm/container.sock"])
        #expect(recorder.calls.allSatisfy { $0.executable == "/opt/podman/bin/podman" })
    }

    @Test("register reports failure when podman rejects the add")
    func registerFailure() {
        let recorder = SpawnRecorder(statuses: ["add": 125])

        let registered = PodmanConnectionRegistrar.register(
            podmanPath: "/opt/podman/bin/podman", uri: "unix://x", spawn: recorder.spawn)

        #expect(!registered)
    }

    @Test("register is idempotent — remove of an unregistered name is not an error")
    func registerIdempotent() {
        // "remove" fails (nothing registered) but "add" succeeds.
        let recorder = SpawnRecorder(statuses: ["remove": 125])

        let registered = PodmanConnectionRegistrar.register(
            podmanPath: "/podman", uri: "unix://x", spawn: recorder.spawn)

        #expect(registered, "a failing remove of a missing connection must not fail the add")
    }

    @Test("register uses a custom connection name when given")
    func customName() {
        let recorder = SpawnRecorder()

        _ = PodmanConnectionRegistrar.register(
            podmanPath: "/podman", uri: "unix://x", connectionName: "podm-alt", spawn: recorder.spawn)

        #expect(recorder.calls[0].arguments == ["system", "connection", "remove", "podm-alt"])
        #expect(recorder.calls[1].arguments[3] == "podm-alt")
    }

    @Test("unregister removes the connection by name")
    func unregister() {
        let recorder = SpawnRecorder()

        _ = PodmanConnectionRegistrar.unregister(podmanPath: "/podman", spawn: recorder.spawn)

        #expect(recorder.calls.map(\.arguments) == [["system", "connection", "remove", "podm"]])
    }

    @Test("unregister succeeds when the connection is gone after the call")
    func unregisterWhenAbsent() {
        // remove fails, show fails (not registered) → gone → success.
        let recorder = SpawnRecorder(statuses: ["remove": 125, "show": 1])

        let gone = PodmanConnectionRegistrar.unregister(podmanPath: "/podman", spawn: recorder.spawn)

        #expect(gone)
        #expect(
            recorder.calls.map(\.arguments).last == ["system", "connection", "show", "podm"],
            "absence must be confirmed via show")
    }

    @Test("isRegistered reflects the show exit status")
    func isRegistered() {
        #expect(
            PodmanConnectionRegistrar.isRegistered(
                podmanPath: "/podman", spawn: SpawnRecorder(statuses: ["show": 0]).spawn))
        #expect(
            !PodmanConnectionRegistrar.isRegistered(
                podmanPath: "/podman", spawn: SpawnRecorder(statuses: ["show": 1]).spawn))
    }
}
