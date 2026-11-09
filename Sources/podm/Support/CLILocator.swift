// SPDX-License-Identifier: Apache-2.0

import Foundation

// ~/.podm/client-paths.json — the recorded locations of the real podman and
// docker CLIs, written by `podm install`. Only entries for CLIs that were
// actually found are (re)written, so a missing CLI keeps its old entry.

enum ClientPaths {
    static func read() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: PodmPaths.clientPathsURL.path),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: String]
        else {
            return [:]
        }
        return dictionary
    }

    static func mergeAndWrite(_ entries: [String: String]) throws {
        var merged = read()
        for (name, path) in entries where !path.isEmpty {
            merged[name] = path
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: PodmPaths.podmDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: PodmPaths.clientPathsURL, options: .atomic)
    }
}

// Locates real (non-shim) executables for the personas and helper CLIs.

enum CLILocator {
    /// Find the executable named `name`.
    ///
    /// Search order:
    ///   1. The path recorded in ~/.podm/client-paths.json by `podm install`.
    ///   2. A $PATH scan, front to back.
    ///
    /// Any candidate whose realpath equals `skippingRealPath` is rejected and the
    /// search continues — this is how the symlinked-shim directory (~/.podm/bin,
    /// which users put FIRST on PATH) is skipped: its `podman`/`docker` entries
    /// resolve to this very binary, so the scan moves on to the next PATH entry
    /// where the real CLI lives.
    static func locate(cli name: String, skippingRealPath skippedPath: String? = nil) -> String? {
        if let recorded = ClientPaths.read()[name], let resolved = usableRealPath(recorded, skipping: skippedPath) {
            return resolved
        }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if let resolved = usableRealPath(candidate, skipping: skippedPath) {
                return resolved
            }
        }
        return nil
    }

    /// A candidate is usable when it is an executable regular file and not the
    /// shim itself (compared after resolving symlinks on both sides).
    private static func usableRealPath(_ path: String, skipping skippedPath: String?) -> String? {
        guard FileSystem.isExecutableFile(path) else {
            return nil
        }
        let resolved = FileSystem.realPath(path)
        if let skippedPath, resolved == skippedPath {
            return nil
        }
        return resolved
    }
}
