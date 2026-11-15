// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check podm's requirements and print a PASS/WARN/FAIL line per check."
    )

    func run() throws {
        let checks = DoctorChecks.evaluate(probes: .live)
        for check in checks {
            print(check.line)
        }
        if checks.contains(where: \.blocksExit) {
            throw ExitCode(1)
        }
    }
}
