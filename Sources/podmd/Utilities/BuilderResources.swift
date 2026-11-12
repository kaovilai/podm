import Foundation
import Logging

/// Explicit build-resource request derived from the wire. Both CLIs send
/// `memory` (bytes) and `cpuperiod`/`cpuquota` (CFS) on /build ONLY when the
/// user passes --memory / --cpu-quota / --cpu-period (verified against the
/// wire-contract harness): absent flags = absent query keys, so a non-nil
/// request is always an explicit ask, never an inferred default.
struct BuilderResourceRequest: Sendable, Equatable {
    /// 0 = not requested.
    let memoryInBytes: Int64
    /// 0 = not requested.
    let cpus: Int64

    var isBlank: Bool { memoryInBytes <= 0 && cpus <= 0 }

    /// Docker's and podman's wire forms are identical here. `cpus` is
    /// ceil(quota / period) — a quota of 150000/100000 means one and a half
    /// vCPUs, which the VM layer sizes as 2. The CLIs send the two keys
    /// independently, so a quota without a period uses the CFS default
    /// period of 100000 µs (podman's own documented default). The ceiling is
    /// computed as `1 + (quota - 1) / period` — the naive
    /// `(quota + period - 1) / period` traps on Int64 overflow for absurd
    /// but decodable quotas (e.g. `cpuquota=9223372036854775807`), and a
    /// build flag must never crash the daemon.
    static func fromQuery(memory: Int?, cpuperiod: Int?, cpuquota: Int?) -> BuilderResourceRequest {
        let memoryBytes = memory.flatMap { $0 > 0 ? Int64($0) : nil } ?? 0
        let cpus: Int64
        if let quota = cpuquota, quota > 0 {
            let period: Int64
            if let rawPeriod = cpuperiod, rawPeriod > 0 {
                period = Int64(rawPeriod)
            } else {
                period = 100_000  // CFS default period
            }
            cpus = 1 + (Int64(quota) - 1) / period
        } else {
            cpus = 0
        }
        return BuilderResourceRequest(memoryInBytes: memoryBytes, cpus: cpus)
    }

    /// The resources to actually provision when `self` explicitly exceeds
    /// what the builder would otherwise get: per-field max, clamped to the
    /// host. Returns nil when nothing needs changing — the configured size
    /// already covers the request.
    func escalated(over configured: BuilderResourceRequest) -> BuilderResourceRequest? {
        guard !isBlank else { return nil }
        let memory = memoryInBytes > 0 ? max(memoryInBytes, configured.memoryInBytes) : configured.memoryInBytes
        let cpus = self.cpus > 0 ? max(self.cpus, configured.cpus) : configured.cpus
        guard memory != configured.memoryInBytes || cpus != configured.cpus else { return nil }
        return BuilderResourceRequest(memoryInBytes: memory, cpus: cpus).clampedToHost()
    }

    func clampedToHost() -> BuilderResourceRequest {
        BuilderResourceRequest(
            memoryInBytes: min(max(1, memoryInBytes), Self.hostMemoryClamp),
            cpus: min(max(1, cpus), Self.hostCPUsClamp)
        )
    }

    /// Overcommit guards: a VM's vCPUs beyond the physical core count and
    /// memory beyond physical RAM only slow builds down (and wired VM memory
    /// can hard-fail creation), so absurd asks clamp to the host.
    static var hostCPUsClamp: Int64 {
        Int64(max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    static var hostMemoryClamp: Int64 {
        let physical = hostPhysicalMemory()
        return physical >= UInt64(Int64.max) ? Int64.max : Int64(physical)
    }
}

/// Daemon-level builder sizing knobs, read once at boot (house style:
/// PODM_* env like PODM_DNS_PORT). Users with big projects raise the
/// builder VM once instead of passing --memory on every build.
///
/// - PODM_BUILDER_CPUS / PODM_BUILDER_MEMORY — Rosetta (native/amd64) builder
/// - PODM_QEMU_BUILDER_CPUS / PODM_QEMU_BUILDER_MEMORY — QEMU (emulated-arch) builder
///
/// Memory accepts `<number>`, `<number><k|m|g>` (case-insensitive, binary
/// multiples). Invalid values warn and fall back to the default, matching
/// the PODM_DNS_UPSTREAM behavior.
enum BuilderResourceKnobs {
    static let defaultCPUs: Int64 = 2
    static let defaultMemoryInBytes: Int64 = 2_147_483_648  // 2048 MiB

    static func provision(qemu: Bool, env: [String: String], logger: Logger? = nil) -> BuilderResourceRequest {
        let cpusKey = qemu ? "PODM_QEMU_BUILDER_CPUS" : "PODM_BUILDER_CPUS"
        let memoryKey = qemu ? "PODM_QEMU_BUILDER_MEMORY" : "PODM_BUILDER_MEMORY"
        var cpus = positiveInt64(env[cpusKey])
        if env[cpusKey] != nil, cpus == nil {
            logger?.warning(
                "podm: ignoring invalid \(cpusKey) '\(env[cpusKey] ?? "")' — expected a positive whole number; using \(defaultCPUs)")
        }
        var memory = memoryInBytes(env[memoryKey])
        if env[memoryKey] != nil, memory == nil {
            logger?.warning(
                "podm: ignoring invalid \(memoryKey) '\(env[memoryKey] ?? "")' — expected bytes or a k/m/g suffix; using \(defaultMemoryInBytes)")
        }
        let clampedCPUs = cpus.map { min($0, BuilderResourceRequest.hostCPUsClamp) }
        let clampedMemory = memory.map { min($0, BuilderResourceRequest.hostMemoryClamp) }
        return BuilderResourceRequest(memoryInBytes: clampedMemory ?? defaultMemoryInBytes, cpus: clampedCPUs ?? defaultCPUs)
    }

    /// Parses "4096m", "4G", "4294967296" into bytes; nil when absent or invalid.
    static func memoryInBytes(_ raw: String?) -> Int64? {
        guard let raw, !raw.isEmpty else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        let digits = value.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int64(digits) else { return nil }
        let unit = value.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        let multiplier: Int64
        switch unit {
        case "", "b": multiplier = 1
        case "k", "kb": multiplier = 1 << 10
        case "m", "mb": multiplier = 1 << 20
        case "g", "gb": multiplier = 1 << 30
        case "t", "tb": multiplier = 1 << 40
        default: return nil
        }
        guard number > 0 else { return nil }
        // Overflow-safe multiply.
        guard number <= Int64.max / multiplier else { return nil }
        return number * multiplier
    }

    private static func positiveInt64(_ raw: String?) -> Int64? {
        guard let raw, let value = Int64(raw.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }
}
