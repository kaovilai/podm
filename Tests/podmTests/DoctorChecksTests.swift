// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import podm

/// `podm doctor` must point at the fix when the daemon cannot be woken: the
/// checks below are the launchd half that the socket/ping lines cannot explain.
@Suite("DoctorChecks")
struct DoctorChecksTests {

    private static let plistPath = "/Users/example/Library/LaunchAgents/io.github.podm.daemon.plist"
    private static let goodBinary = "/Users/example/.podm/bin/podmd"

    private static func plistData(
        binary: String,
        label: String = "io.github.podm.daemon",
        program: String? = nil
    ) -> Data {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary],
        ]
        if let program { plist["Program"] = program }
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private static func probes(
        plistData: Data? = plistData(binary: goodBinary),
        plistExists: Bool = true,
        launchctlExit: Int32 = 0,
        podmdLocated: Bool = true,
        socketPresent: Bool = true,
        pingExit: Int32 = 0,
        clis: Set<String> = ["podman", "docker", "container"]
    ) -> DoctorProbes {
        DoctorProbes(
            operatingSystemVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0) },
            isAppleSilicon: { true },
            locateCLI: { clis.contains($0) ? "/usr/local/bin/\($0)" : nil },
            locateDaemon: { podmdLocated ? goodBinary : nil },
            run: { executable, arguments in
                switch (executable, arguments) {
                case ("/bin/launchctl", _): return (launchctlExit, nil)
                case (_, ["--version"]): return (0, "container CLI version 1.6.1")
                case ("/usr/bin/curl", _): return (pingExit, nil)
                default: return (0, nil)
                }
            },
            readFile: { path in path == plistPath ? plistData : nil },
            fileExists: { _ in plistExists },
            isExecutableFile: { $0 == goodBinary },
            isSocket: { _ in socketPresent },
            socketPath: "/Users/example/.podm/container.sock",
            launchAgentPath: plistPath,
            launchdLabel: "io.github.podm.daemon",
            launchdDomain: "gui/501",
            launchdServiceTarget: "gui/501/io.github.podm.daemon"
        )
    }

    private static func check(_ name: String, in checks: [DoctorCheck]) -> DoctorCheck? {
        checks.first { $0.name == name }
    }

    @Test("a healthy install passes every check")
    func healthyInstall() {
        let checks = DoctorChecks.evaluate(probes: Self.probes())
        #expect(checks.allSatisfy { $0.passed })
        #expect(!checks.contains(where: { $0.blocksExit }))
        #expect(Self.check("podmd binary", in: checks)?.passed == true)
        #expect(Self.check("LaunchAgent", in: checks)?.passed == true)
        #expect(Self.check("LaunchAgent loaded", in: checks)?.passed == true)
    }

    @Test("no LaunchAgent is a warning, not a failure — `podm serve` is legitimate")
    func missingAgent() {
        let checks = DoctorChecks.evaluate(probes: Self.probes(plistData: nil, plistExists: false))
        let agent = Self.check("LaunchAgent", in: checks)
        #expect(agent?.passed == false)
        #expect(agent?.severity == .warn)
        #expect(agent?.blocksExit == false)
        #expect(agent?.detail.contains("podm install") == true)
    }

    @Test("an unparseable plist fails with the reinstall hint")
    func unreadablePlist() {
        let checks = DoctorChecks.evaluate(probes: Self.probes(plistData: Data("not a plist".utf8)))
        let agent = Self.check("LaunchAgent", in: checks)
        #expect(agent?.passed == false)
        #expect(agent?.blocksExit == true)
        #expect(agent?.detail.contains("podm install") == true)
    }

    @Test("a plist still naming __PODMD_BIN__ can never start the daemon")
    func placeholderBinary() {
        let checks = DoctorChecks.evaluate(
            probes: Self.probes(plistData: Self.plistData(binary: "__PODMD_BIN__")))
        let agent = Self.check("LaunchAgent", in: checks)
        #expect(agent?.passed == false)
        #expect(agent?.detail.contains("__PODMD_BIN__") == true)
        #expect(agent?.detail.contains("podm install") == true)
    }

    @Test("a plist naming a missing binary fails and names the path")
    func missingBinary() {
        let checks = DoctorChecks.evaluate(
            probes: Self.probes(plistData: Self.plistData(binary: "/gone/podmd")))
        let agent = Self.check("LaunchAgent", in: checks)
        #expect(agent?.passed == false)
        #expect(agent?.detail.contains("/gone/podmd") == true)
    }

    @Test("a valid plist whose job is not loaded is the actionable failure")
    func jobNotLoaded() {
        let checks = DoctorChecks.evaluate(probes: Self.probes(launchctlExit: 113))
        #expect(Self.check("LaunchAgent", in: checks)?.passed == true)
        let loaded = Self.check("LaunchAgent loaded", in: checks)
        #expect(loaded?.passed == false)
        #expect(loaded?.blocksExit == true)
        #expect(loaded?.detail.contains("113") == true)
        #expect(loaded?.detail.contains("launchctl bootstrap gui/501") == true)
        // The path is shell-quoted: a home directory with spaces must not split
        // the copied command into two arguments.
        #expect(loaded?.detail.contains("'/Users/example/Library/LaunchAgents/io.github.podm.daemon.plist'") == true)
    }

    @Test("an existing but unreadable plist is a FAIL, not an absent agent")
    func unreadableButPresentPlist() {
        let checks = DoctorChecks.evaluate(probes: Self.probes(plistData: nil, plistExists: true))
        let agent = Self.check("LaunchAgent", in: checks)
        #expect(agent?.passed == false)
        #expect(agent?.blocksExit == true)
        #expect(agent?.detail.contains("cannot read") == true)
    }

    @Test("a plist registering another label cannot be the agent the shim kicks")
    func wrongLabel() {
        let checks = DoctorChecks.evaluate(
            probes: Self.probes(plistData: Self.plistData(binary: Self.goodBinary, label: "com.example.other")))
        let agent = Self.check("LaunchAgent", in: checks)
        #expect(agent?.passed == false)
        #expect(agent?.blocksExit == true)
        #expect(agent?.detail.contains("com.example.other") == true)
        #expect(agent?.detail.contains("io.github.podm.daemon") == true)
    }

    @Test("launchd runs Program when the plist defines it")
    func programForm() {
        let good = DoctorChecks.evaluate(
            probes: Self.probes(
                plistData: Self.plistData(binary: "/ignored", program: Self.goodBinary)))
        #expect(Self.check("LaunchAgent", in: good)?.passed == true)
        #expect(Self.check("LaunchAgent", in: good)?.detail.contains(Self.goodBinary) == true)

        let bad = DoctorChecks.evaluate(
            probes: Self.probes(
                plistData: Self.plistData(binary: Self.goodBinary, program: "/gone/podmd")))
        #expect(Self.check("LaunchAgent", in: bad)?.passed == false)
        #expect(Self.check("LaunchAgent", in: bad)?.detail.contains("/gone/podmd") == true)
    }

    @Test("a missing podmd binary points at building it, not at podm install")
    func missingDaemonBinary() {
        let checks = DoctorChecks.evaluate(probes: Self.probes(podmdLocated: false))
        let daemon = Self.check("podmd binary", in: checks)
        #expect(daemon?.passed == false)
        #expect(daemon?.detail.contains("make") == true)
        #expect(daemon?.detail.contains("podm install") == false)
    }

    @Test("socket and ping failures both block")
    func daemonDown() {
        let checks = DoctorChecks.evaluate(
            probes: Self.probes(socketPresent: false, pingExit: 7))
        #expect(Self.check("daemon socket", in: checks)?.blocksExit == true)
        #expect(Self.check("daemon ping", in: checks)?.blocksExit == true)
    }

    @Test("a missing docker CLI is only a warning")
    func dockerOptional() {
        let checks = DoctorChecks.evaluate(probes: Self.probes(clis: ["podman", "container"]))
        let docker = Self.check("docker CLI", in: checks)
        #expect(docker?.passed == false)
        #expect(docker?.severity == .warn)
        #expect(docker?.blocksExit == false)
    }
}
