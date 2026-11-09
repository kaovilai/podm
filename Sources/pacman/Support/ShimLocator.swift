// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

// Locates this shim binary's own identity on disk.

enum ShimLocator {
    /// Absolute, symlink-resolved path of this executable. Computed via
    /// _NSGetExecutablePath (works regardless of how argv[0] was spelled or
    /// whether we were invoked through a PATH symlink), then realpath'd so it
    /// can be compared against candidate CLI paths found on $PATH.
    static let selfRealPath: String = {
        FileSystem.realPath(rawExecutablePath())
    }()

    private static func rawExecutablePath() -> String {
        var size: Int32 = 4096
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) != 0 {
            // Buffer was too small; size now holds the required length.
            buffer = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buffer, &size) == 0 else {
                return CommandLine.arguments.first ?? "pacman"
            }
        }
        return String(cString: buffer)
    }
}
