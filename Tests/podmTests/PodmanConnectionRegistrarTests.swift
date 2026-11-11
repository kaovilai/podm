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
        // A NON-clean profile (one existing connection, itself the
        // default): podman's add does not touch the default.
        let listing = SpawnRecorder.listing([
            ["Name": "other", "URI": "ssh://x", "Default": true]
        ])
        let recorder = SpawnRecorder(verbs: ["list": (0, listing)])

        let result = PodmanConnectionRegistrar.register(
            podmanPath: "/opt/podman/bin/podman",
            uri: "unix:///home/user/.podm/container.sock",
            spawn: recorder.spawn)

        #expect(
            result
                == PodmanConnectionRegistrar.RegistrationResult(
                    connectionName: "podm", becameDefaultOnCleanProfile: false))
        // The whole contract: list (default snapshot), add (destination
        // positional), list (verify the default survived). No remove —
        // podman 6's add updates an existing name in place, and a remove
        // would clear the user's default selection.
        #expect(recorder.calls.count == 3)
        #expect(recorder.calls[0].arguments == ["system", "connection", "list", "--format", "json"])
        #expect(
            recorder.calls[1].arguments
                == ["system", "connection", "add", "podm", "unix:///home/user/.podm/container.sock"])
        #expect(recorder.calls[2].arguments == ["system", "connection", "list", "--format", "json"])
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
        // Before: nothing at all. After: podm, made the default by podman's
        // own first-connection rule.
        let before = "[]"
        let after = SpawnRecorder.listing([["Name": "podm", "URI": "unix://x", "Default": true]])
        var listingIndex = 0
        let spawn: PodmanConnectionRegistrar.Spawn = { _, arguments in
            if arguments.contains("list") {
                listingIndex += 1
                return (0, listingIndex == 1 ? before : after)
            }
            return (0, "")
        }

        let result = PodmanConnectionRegistrar.register(
            podmanPath: "/podman", uri: "unix://x", spawn: spawn)

        #expect(result?.becameDefaultOnCleanProfile == true)
    }

    /// Review round 4: connections supplied entirely by a READ-ONLY layer
    /// (containers.conf) — the LISTING shows an existing default, but
    /// podman's add still sees an empty WRITABLE profile and flips the
    /// default to the new connection. The before/after comparison must
    /// catch it and RESTORE the previous selection.
    @Test("register restores a default flipped by podman's add")
    func registerRestoresFlippedDefault() {
        let before = SpawnRecorder.listing([
            ["Name": "other-machine", "URI": "ssh://x", "Default": true]
        ])
        let after = SpawnRecorder.listing([
            ["Name": "other-machine", "URI": "ssh://x", "Default": false],
            ["Name": "podm", "URI": "unix://x", "Default": true],
        ])
        var listingIndex = 0
        var calls: [(executable: String, arguments: [String])] = []
        let spawn: PodmanConnectionRegistrar.Spawn = { executable, arguments in
            calls.append((executable, arguments))
            if arguments.contains("list") {
                listingIndex += 1
                return (0, listingIndex == 1 ? before : after)
            }
            return (0, "")
        }

        let result = PodmanConnectionRegistrar.register(
            podmanPath: "/podman", uri: "unix://x", spawn: spawn)

        #expect(result?.becameDefaultOnCleanProfile == false, "a default existed before")
        #expect(
            calls.contains { $0.arguments == ["system", "connection", "default", "other-machine"] },
            "the flipped default must be restored")
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

        #expect(
            recorder.calls.first(where: { $0.arguments[2] == "add" })?.arguments[3] == "podm-alt")
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
    /// Review round 4: a command writing ONLY stdout passes even under a
    /// merged-stream implementation — the probe must write BOTH streams so
    /// the regression (podman's config warnings on stderr corrupting the
    /// JSON parse) is actually detectable.
    @Test("the production spawn seam reads stdout, not stderr")
    func realSpawnStdoutOnly() {
        let result = PodmanConnectionRegistrar.realSpawn(
            "/bin/sh",
            ["-c", "printf stdout-marker; printf stderr-warning >&2"])
        #expect(result.exitStatus == 0)
        #expect(
            result.output == "stdout-marker",
            "stdout only, exactly: \(result.output ?? "nil")")
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
