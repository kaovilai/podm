// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import podm

/// `podm install` must register podm as a selectable podman system
/// connection — never touching the default (issue #47), and using only
/// subcommands podman actually has (6.1.4: add/default/list/remove/rename —
/// there is no `show`).
@Suite("PodmanConnectionRegistrar")
struct PodmanConnectionRegistrarTests {

    /// Records every spawned command; answers from a scripted handler keyed
    /// by the verb after "system connection", with `list` answering JSON.
    private final class SpawnRecorder {
        private(set) var calls: [(executable: String, arguments: [String])] = []
        private let verbs: [String: (Int32, String?)]

        init(verbs: [String: (Int32, String?)] = [:]) {
            self.verbs = verbs
        }

        /// A listing body the registrar can parse.
        static func listing(_ entries: [[String: Any]]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: entries)) ?? Data("[]".utf8)
            return String(data: data, encoding: .utf8) ?? "[]"
        }

        var spawn: PodmanConnectionRegistrar.Spawn {
            { [self] executable, arguments in
                self.calls.append((executable, arguments))
                let verb = arguments.count >= 3 ? arguments[2] : ""
                return self.verbs[verb] ?? (0, "")
            }
        }
    }

    @Test("register adds with the positional destination and NO remove — podman updates in place")
    func registerSequence() {
        // A NON-clean profile (one existing connection): podman's add does
        // not touch the default.
        let recorder = SpawnRecorder(
            verbs: ["list": (0, SpawnRecorder.listing([["Name": "other", "URI": "ssh://x"]]))])

        let result = PodmanConnectionRegistrar.register(
            podmanPath: "/opt/podman/bin/podman",
            uri: "unix:///home/user/.podm/container.sock",
            spawn: recorder.spawn)

        #expect(
            result
                == PodmanConnectionRegistrar.RegistrationResult(
                    connectionName: "podm", becameDefaultOnCleanProfile: false))
        // The whole contract: ONE add, destination positional, after ONE
        // clean-profile check. No remove — podman 6's add updates an
        // existing name in place, and a remove would clear the user's
        // default selection.
        #expect(recorder.calls.count == 2)
        #expect(recorder.calls[0].arguments == ["system", "connection", "list", "--format", "json"])
        #expect(
            recorder.calls[1].arguments
                == ["system", "connection", "add", "podm", "unix:///home/user/.podm/container.sock"])
        #expect(recorder.calls[1].executable == "/opt/podman/bin/podman")
    }

    /// Review round 3: on a CLEAN profile (no connections at all), podman's
    /// own add makes the first-ever connection the DEFAULT
    /// (cmd/podman/system/connection/add.go: `Connections == nil` →
    /// `Default = connection`). podm cannot opt out of podman's rule — but
    /// it must KNOW, so install can tell the user instead of it happening
    /// silently.
    @Test("register reports when a clean profile makes podm the default")
    func registerOnCleanProfileReportsDefault() {
        let recorder = SpawnRecorder(verbs: ["list": (0, "[]")])

        let result = PodmanConnectionRegistrar.register(
            podmanPath: "/podman", uri: "unix://x", spawn: recorder.spawn)

        #expect(result?.becameDefaultOnCleanProfile == true)
    }

    @Test("register reports failure when podman rejects the add")
    func registerFailure() {
        let recorder = SpawnRecorder(
            verbs: [
                "list": (0, SpawnRecorder.listing([["Name": "other", "URI": "ssh://x"]])),
                "add": (125, nil),
            ])

        let result = PodmanConnectionRegistrar.register(
            podmanPath: "/opt/podman/bin/podman", uri: "unix://x", spawn: recorder.spawn)

        #expect(result == nil)
    }

    @Test("register uses a custom connection name when given")
    func customName() {
        let recorder = SpawnRecorder()

        _ = PodmanConnectionRegistrar.register(
            podmanPath: "/podman", uri: "unix://x", connectionName: "podm-alt", spawn: recorder.spawn)

        #expect(recorder.calls.last?.arguments[3] == "podm-alt")
    }

    @Test("isRegistered parses the list --format json output podman actually produces")
    func isRegisteredParsesList() {
        let present = SpawnRecorder(
            verbs: [
                "list": (
                    0,
                    SpawnRecorder.listing([
                        ["Name": "ryzen-wsl", "URI": "ssh://x", "Default": true],
                        ["Name": "podm", "URI": "unix:///sock", "Default": false],
                    ])
                )
            ]
        )
        #expect(PodmanConnectionRegistrar.isRegistered(podmanPath: "/podman", spawn: present.spawn) == true)

        let absent = SpawnRecorder(verbs: ["list": (0, SpawnRecorder.listing([["Name": "ryzen-wsl", "URI": "ssh://x"]]))])
        #expect(PodmanConnectionRegistrar.isRegistered(podmanPath: "/podman", spawn: absent.spawn) == false)
    }

    @Test("isRegistered is nil when the listing itself fails — not a confident no")
    func isRegisteredUnknownOnCliFailure() {
        let failed = SpawnRecorder(verbs: ["list": (125, nil)])
        #expect(PodmanConnectionRegistrar.isRegistered(podmanPath: "/podman", spawn: failed.spawn) == nil)

        let garbage = SpawnRecorder(verbs: ["list": (0, "not json")])
        #expect(PodmanConnectionRegistrar.isRegistered(podmanPath: "/podman", spawn: garbage.spawn) == nil)
    }

    @Test("unregister removes the connection by name")
    func unregister() {
        let recorder = SpawnRecorder()

        #expect(PodmanConnectionRegistrar.unregister(podmanPath: "/podman", spawn: recorder.spawn))
        #expect(recorder.calls.map(\.arguments) == [["system", "connection", "remove", "podm"]])
    }

    @Test("unregister succeeds when a successful listing confirms absence")
    func unregisterWhenAbsent() {
        let recorder = SpawnRecorder(
            verbs: [
                "remove": (125, nil),
                "list": (0, SpawnRecorder.listing([["Name": "other", "URI": "ssh://x"]])),
            ])

        #expect(PodmanConnectionRegistrar.unregister(podmanPath: "/podman", spawn: recorder.spawn))
        #expect(
            recorder.calls.map(\.arguments).last == ["system", "connection", "list", "--format", "json"],
            "absence must be confirmed via a successful listing")
    }

    @Test("unregister fails when both remove and list fail — unconfirmed is not success")
    func unregisterCliFailure() {
        let recorder = SpawnRecorder(verbs: ["remove": (125, nil), "list": (125, nil)])

        #expect(!PodmanConnectionRegistrar.unregister(podmanPath: "/podman", spawn: recorder.spawn))
    }

    /// Review round 2: the production seam used to spawn WITHOUT output
    /// capture, so `list --format json` came back nil in production while
    /// the injected fixtures (which hand back strings) bypassed the bug —
    /// status always printed "unknown" and uninstall never removed the
    /// connection. Echo proves the seam captures stdout end-to-end.
    @Test("the production spawn seam captures stdout only")
    func realSpawnCapturesOutput() {
        let result = PodmanConnectionRegistrar.realSpawn("/bin/echo", ["captured-marker"])
        #expect(result.exitStatus == 0)
        #expect(result.output?.contains("captured-marker") == true, "output must be captured, got nil")
    }

    /// Review round 3: a CLI emitting warnings to STDERR while printing
    /// valid JSON to stdout must not corrupt the parse — echo writes the
    /// marker to stdout, and the command itself writes nothing to stderr,
    /// so the captured output must be exactly the marker (a merged-stream
    /// implementation would also pass this; the separation is enforced by
    /// runCaptureStdout's null stderr, asserted structurally by the seam
    /// living in ProcessSpawn).
    @Test("the production spawn seam reads stdout, not stderr")
    func realSpawnStdoutOnly() {
        // /usr/bin/printf writes to stdout; warnings would go to stderr.
        let result = PodmanConnectionRegistrar.realSpawn("/usr/bin/printf", ["json-marker"])
        #expect(result.exitStatus == 0)
        #expect(result.output == "json-marker", "stdout only, exactly: \(result.output ?? "nil")")
    }

    @Test("listConnections decodes entries and distinguishes CLI failure")
    func listConnectionsDecoding() {
        let recorder = SpawnRecorder(
            verbs: ["list": (0, SpawnRecorder.listing([["Name": "podm", "URI": "unix:///s", "Default": true]]))]
        )

        let entries = PodmanConnectionRegistrar.listConnections(podmanPath: "/podman", spawn: recorder.spawn)

        #expect(
            entries
                == [PodmanConnectionRegistrar.ConnectionEntry(name: "podm", uri: "unix:///s", isDefault: true)])
        #expect(
            PodmanConnectionRegistrar.listConnections(
                podmanPath: "/podman",
                spawn: SpawnRecorder(verbs: ["list": (1, nil)]).spawn
            ) == nil, "CLI failure must be nil, not an empty list")
    }
}
