// SPDX-License-Identifier: Apache-2.0

import Foundation

// `podm doctor`'s checks, split from the command so they can be unit tested:
// every answer (filesystem, launchd, CLI lookups, the daemon ping) arrives
// through `DoctorProbes` instead of being reached for directly.

/// One doctor result line.
struct DoctorCheck: Equatable {
    enum Severity: Equatable {
        case fail
        case warn
    }

    let name: String
    let passed: Bool
    let severity: Severity
    let detail: String

    /// A failed non-optional check makes `podm doctor` exit 1. A warning never
    /// does: a dev setup without a LaunchAgent, or without the docker CLI, is
    /// legitimate.
    var blocksExit: Bool { !passed && severity == .fail }

    var line: String {
        let label = passed ? "PASS" : (severity == .warn ? "WARN" : "FAIL")
        return "\(label)  \(name): \(detail)"
    }
}

/// Everything `DoctorChecks` consults. `live` wires the real system; tests
/// inject scripted answers.
struct DoctorProbes {
    var operatingSystemVersion: () -> OperatingSystemVersion
    var isAppleSilicon: () -> Bool
    var locateCLI: (String) -> String?
    var locateDaemon: () -> String?
    var run: (_ executable: String, _ arguments: [String]) -> (exitStatus: Int32, output: String?)
    var readFile: (String) -> Data?
    var fileExists: (String) -> Bool
    var isExecutableFile: (String) -> Bool
    var isSocket: (String) -> Bool

    var socketPath: String
    var launchAgentPath: String
    var launchdLabel: String
    var launchdDomain: String
    var launchdServiceTarget: String

    static var live: DoctorProbes {
        #if arch(arm64)
        let arm64 = true
        #else
        let arm64 = false
        #endif
        return DoctorProbes(
            operatingSystemVersion: { ProcessInfo.processInfo.operatingSystemVersion },
            isAppleSilicon: { arm64 },
            locateCLI: { CLILocator.locate(cli: $0, skippingRealPath: ShimLocator.selfRealPath) },
            locateDaemon: { DaemonLocator.locate() },
            run: { ProcessSpawn.run($0, $1, captureOutput: true) },
            readFile: { FileManager.default.contents(atPath: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isExecutableFile: { FileSystem.isExecutableFile($0) },
            isSocket: { FileSystem.isSocket($0) },
            socketPath: PodmPaths.socketPath,
            launchAgentPath: PodmPaths.launchAgentURL.path,
            launchdLabel: PodmPaths.launchdLabel,
            launchdDomain: PodmPaths.launchdDomain,
            launchdServiceTarget: PodmPaths.launchdServiceTarget
        )
    }
}

/// What the installed LaunchAgent plist says about the daemon it would start.
enum LaunchAgentInspection: Equatable {
    case missing
    case unreadable
    case wrongLabel(String?)
    case placeholder
    case binaryMissing(String)
    case okay(String)

    static func inspect(
        path: String,
        expectedLabel: String,
        fileExists: (String) -> Bool,
        readFile: (String) -> Data?,
        isExecutableFile: (String) -> Bool
    ) -> LaunchAgentInspection {
        // `contents(atPath:)` is nil for permission failures too — an existing
        // but unreadable plist must not read as an optional, absent agent.
        guard fileExists(path) else { return .missing }
        guard
            let data = readFile(path),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return .unreadable }
        // The shim kickstarts `io.github.podm.daemon`; a plist registering any
        // other label cannot be the agent it waits for.
        guard let label = plist["Label"] as? String, label == expectedLabel else {
            return .wrongLabel(plist["Label"] as? String)
        }
        // launchd runs `Program` when present; `ProgramArguments[0]` is only the
        // argv[0] for the other form.
        let binary: String
        if let program = plist["Program"] as? String, !program.isEmpty {
            binary = program
        } else if let arguments = plist["ProgramArguments"] as? [String],
            let first = arguments.first, !first.isEmpty
        {
            binary = first
        } else {
            return .unreadable
        }
        // `podm install --launchd-template` renders __PODMD_BIN__; a plist that
        // still contains it bootstraps fine but can never start the daemon.
        if binary.contains("__PODMD_BIN__") { return .placeholder }
        guard isExecutableFile(binary) else { return .binaryMissing(binary) }
        return .okay(binary)
    }
}

enum DoctorChecks {
    static func evaluate(probes: DoctorProbes) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        let version = probes.operatingSystemVersion()
        checks.append(
            DoctorCheck(
                name: "macOS >= 26",
                passed: version.majorVersion >= 26,
                severity: .fail,
                detail: "found macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            ))

        let arm64 = probes.isAppleSilicon()
        checks.append(
            DoctorCheck(
                name: "CPU arm64",
                passed: arm64,
                severity: .fail,
                detail: arm64 ? "running on arm64" : "this build targets Apple Silicon only"
            ))

        checks.append(cli(probes, "podman", severity: .fail, hint: "brew install podman (then podm install)"))
        checks.append(
            cli(
                probes, "docker", severity: .warn,
                hint: "only needed for the docker persona (brew install docker)"))

        switch probes.locateCLI("container") {
        case let path?:
            let output =
                probes.run(path, ["--version"]).output?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            checks.append(
                DoctorCheck(
                    name: "`container` CLI", passed: true, severity: .fail,
                    detail: output.isEmpty ? path : "\(path) — \(output)"))
        case nil:
            checks.append(
                DoctorCheck(
                    name: "`container` CLI", passed: false, severity: .fail,
                    detail: "not found on PATH"))
        }

        if let daemon = probes.locateDaemon() {
            checks.append(
                DoctorCheck(
                    name: "podmd binary", passed: true, severity: .fail, detail: daemon))
        } else {
            checks.append(
                DoctorCheck(
                    name: "podmd binary", passed: false, severity: .fail,
                    detail: "not found next to the shim or on PATH — build it with `make` in the podm repository"))
        }

        checks.append(contentsOf: launchAgentChecks(probes))

        let socketPresent = probes.isSocket(probes.socketPath)
        checks.append(
            DoctorCheck(
                name: "daemon socket",
                passed: socketPresent,
                severity: .fail,
                detail: socketPresent ? probes.socketPath : "missing at \(probes.socketPath)"
            ))

        let ping = probes.run(
            "/usr/bin/curl",
            ["--max-time", "2", "-sf", "--unix-socket", probes.socketPath, "http://localhost/_ping"])
        checks.append(
            DoctorCheck(
                name: "daemon ping",
                passed: ping.exitStatus == 0,
                severity: .fail,
                detail: ping.exitStatus == 0
                    ? "/_ping OK"
                    : "no response from /_ping (is podmd running? start it with `podm serve`, or fix the LaunchAgent lines above)"
            ))

        return checks
    }

    private static func cli(
        _ probes: DoctorProbes, _ name: String, severity: DoctorCheck.Severity, hint: String
    ) -> DoctorCheck {
        if let path = probes.locateCLI(name) {
            return DoctorCheck(name: "\(name) CLI", passed: true, severity: severity, detail: path)
        }
        return DoctorCheck(name: "\(name) CLI", passed: false, severity: severity, detail: "not found — \(hint)")
    }

    /// The install path the shim's own wake logic depends on: a rendered plist
    /// plus a loaded job. This is what makes a missing agent show up as an
    /// actionable FAIL instead of a CLI that hangs and then says "cannot
    /// connect".
    private static func launchAgentChecks(_ probes: DoctorProbes) -> [DoctorCheck] {
        let inspection = LaunchAgentInspection.inspect(
            path: probes.launchAgentPath,
            expectedLabel: probes.launchdLabel,
            fileExists: probes.fileExists,
            readFile: probes.readFile,
            isExecutableFile: probes.isExecutableFile)

        switch inspection {
        case .missing:
            return [
                DoctorCheck(
                    name: "LaunchAgent",
                    passed: false,
                    severity: .warn,
                    detail:
                        "no agent at \(probes.launchAgentPath) — on-demand wake is off; install one with `podm install --launchd-template <plist-template>` (a foreground `podm serve` also works)"
                )
            ]
        case .unreadable:
            return [
                DoctorCheck(
                    name: "LaunchAgent",
                    passed: false,
                    severity: .fail,
                    detail:
                        "cannot read or parse \(probes.launchAgentPath) — reinstall it with `podm install --launchd-template <plist-template>`"
                )
            ]
        case .wrongLabel(let label):
            return [
                DoctorCheck(
                    name: "LaunchAgent",
                    passed: false,
                    severity: .fail,
                    detail:
                        "\(probes.launchAgentPath) registers \(label.map { "label \($0)" } ?? "no Label"), not \(probes.launchdLabel) — the shim kicks \(probes.launchdServiceTarget); reinstall it with `podm install --launchd-template <plist-template>`"
                )
            ]
        case .placeholder:
            return [
                DoctorCheck(
                    name: "LaunchAgent",
                    passed: false,
                    severity: .fail,
                    detail:
                        "\(probes.launchAgentPath) still names __PODMD_BIN__ — the agent can never start a daemon; reinstall it with `podm install --launchd-template <plist-template>`"
                )
            ]
        case .binaryMissing(let binary):
            return [
                DoctorCheck(
                    name: "LaunchAgent",
                    passed: false,
                    severity: .fail,
                    detail:
                        "\(probes.launchAgentPath) names \(binary), which is missing or not executable — reinstall it with `podm install --launchd-template <plist-template>`"
                )
            ]
        case .okay(let binary):
            var checks = [
                DoctorCheck(
                    name: "LaunchAgent",
                    passed: true,
                    severity: .fail,
                    detail: "\(probes.launchAgentPath) → \(binary)"
                )
            ]
            let loaded = probes.run("/bin/launchctl", ["print", probes.launchdServiceTarget])
            checks.append(
                DoctorCheck(
                    name: "LaunchAgent loaded",
                    passed: loaded.exitStatus == 0,
                    severity: .fail,
                    detail: loaded.exitStatus == 0
                        ? probes.launchdServiceTarget
                        : "job not loaded (launchctl print exited \(loaded.exitStatus)) — reload it with `launchctl bootstrap \(probes.launchdDomain) \(shellQuoted(probes.launchAgentPath))`"
                ))
            return checks
        }
    }

    /// Single-quote a path for the shell so a home directory containing spaces
    /// still copies to one `launchctl bootstrap` argument.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
