import Foundation
import Logging
import Testing

@testable import podmd

/// Captures log records for assertions — swift-log has no built-in
/// in-memory handler, and `LogHandler` is the sanctioned injection point.
final class CapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(level: Logger.Level, message: String)] = []

    struct Handler: LogHandler {
        let captured: CapturedLog
        var logLevel: Logger.Level = .warning
        var metadata: Logger.Metadata = [:]

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(
            level: Logger.Level,
            message: Logger.Message,
            metadata: Logger.Metadata?,
            source: String,
            file: String,
            function: String,
            line: UInt
        ) {
            captured.add(level: level, message: message.description)
        }
    }

    func add(level: Logger.Level, message: String) {
        lock.lock()
        defer { lock.unlock() }
        records.append((level, message))
    }

    func warnings() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { $0.level == .warning }.map(\.message)
    }
}

/// The env-knob warning contract: present-but-invalid values warn naming
/// the rejected key and value; absent and valid values stay silent.
@Suite("Builder resource knob warnings")
struct BuilderResourceKnobWarningTests {

    private func makeLogger(_ captured: CapturedLog) -> Logger {
        Logger(label: "test") { _ in CapturedLog.Handler(captured: captured) }
    }

    @Test("Invalid env values warn naming the key and value; valid ones stay silent")
    func invalidValuesWarn() {
        let captured = CapturedLog()
        let logger = makeLogger(captured)
        _ = BuilderResourceKnobs.provision(
            qemu: false,
            env: ["PODM_BUILDER_CPUS": "fast", "PODM_BUILDER_MEMORY": "6GiB"],
            logger: logger)
        let warnings = captured.warnings()
        #expect(warnings.count == 2)
        // Key names only — the raw values are deliberately NOT logged
        // (env vars can carry secrets pasted by mistake).
        #expect(warnings.contains { $0.contains("PODM_BUILDER_CPUS") })
        #expect(warnings.contains { $0.contains("PODM_BUILDER_MEMORY") })
        #expect(warnings.allSatisfy { !$0.contains("fast") && !$0.contains("6GiB") })

        // Valid and absent values never warn.
        let quiet = CapturedLog()
        _ = BuilderResourceKnobs.provision(
            qemu: false, env: ["PODM_BUILDER_CPUS": "4", "PODM_BUILDER_MEMORY": "4g"],
            logger: makeLogger(quiet))
        _ = BuilderResourceKnobs.provision(qemu: false, env: [:], logger: makeLogger(quiet))
        #expect(quiet.warnings().isEmpty)
    }

    @Test("The QEMU-flavored keys warn under their own names")
    func qemuKeysWarn() {
        let captured = CapturedLog()
        _ = BuilderResourceKnobs.provision(
            qemu: true,
            env: ["PODM_QEMU_BUILDER_CPUS": "-1", "PODM_QEMU_BUILDER_MEMORY": "banana"],
            logger: makeLogger(captured))
        let warnings = captured.warnings()
        #expect(warnings.contains { $0.contains("PODM_QEMU_BUILDER_CPUS") })
        #expect(warnings.contains { $0.contains("PODM_QEMU_BUILDER_MEMORY") })
    }
}
