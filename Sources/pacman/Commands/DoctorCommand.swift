// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check pacman's requirements and print a PASS/FAIL line per check."
    )

    private enum Severity {
        case fail
        case warn
    }

    func run() throws {
        var allCriticalChecksPassed = true

        func report(_ check: String, passed: Bool, detail: String, severity: Severity = .fail) {
            if !passed && severity == .fail {
                allCriticalChecksPassed = false
            }
            let label = passed ? "PASS" : (severity == .warn ? "WARN" : "FAIL")
            print("\(label)  \(check): \(detail)")
        }

        // Operating system: macOS 26+ (Darwin 25+).
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        report(
            "macOS >= 26",
            passed: osVersion.majorVersion >= 26,
            detail: "found macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        )

        // CPU architecture (compile-time — the daemon needs Apple Silicon).
        #if arch(arm64)
        let arm64 = true
        #else
        let arm64 = false
        #endif
        report("CPU arm64", passed: arm64, detail: arm64 ? "running on arm64" : "this build targets Apple Silicon only")

        // Real CLIs (the shim skips its own podman/docker symlinks).
        let selfRealPath = ShimLocator.selfRealPath
        if let podmanPath = CLILocator.locate(cli: "podman", skippingRealPath: selfRealPath) {
            report("podman CLI", passed: true, detail: podmanPath)
        } else {
            report("podman CLI", passed: false, detail: "not found — brew install podman (then pacman install)")
        }

        if let dockerPath = CLILocator.locate(cli: "docker", skippingRealPath: selfRealPath) {
            report("docker CLI", passed: true, detail: dockerPath)
        } else {
            // Optional: the podman persona works without the docker CLI.
            report("docker CLI", passed: false, detail: "not found (only needed for the docker persona)", severity: .warn)
        }

        if let containerCLI = CLILocator.locate(cli: "container") {
            let versionResult = ProcessSpawn.run(containerCLI, ["--version"], captureOutput: true)
            let version = versionResult.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            report(
                "`container` CLI",
                passed: true,
                detail: version.isEmpty ? containerCLI : "\(containerCLI) — \(version)"
            )
        } else {
            report("`container` CLI", passed: false, detail: "not found on PATH")
        }

        // Daemon.
        let socketPresent = FileSystem.isSocket(PacmanPaths.socketPath)
        report(
            "daemon socket",
            passed: socketPresent,
            detail: socketPresent ? PacmanPaths.socketPath : "missing at \(PacmanPaths.socketPath)"
        )

        let ping = ProcessSpawn.run(
            "/usr/bin/curl",
            ["--max-time", "2", "-sf", "--unix-socket", PacmanPaths.socketPath, "http://localhost/_ping"]
        )
        report(
            "daemon ping",
            passed: ping.exitStatus == 0,
            detail: ping.exitStatus == 0 ? "/_ping OK" : "no response from /_ping (is pacmand running? try `pacman serve`)"
        )

        if !allCriticalChecksPassed {
            throw ExitCode(1)
        }
    }
}
