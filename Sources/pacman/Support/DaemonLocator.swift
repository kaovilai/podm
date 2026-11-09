// SPDX-License-Identifier: Apache-2.0

import Foundation

// Locates the pacman daemon binary (pacmand).

enum DaemonLocator {
    /// Prefer a pacmand sitting next to this shim's real binary (same directory
    /// after symlink resolution — the usual make/install layout), then fall back
    /// to a $PATH scan.
    static func locate() -> String? {
        let sibling = URL(fileURLWithPath: ShimLocator.selfRealPath)
            .deletingLastPathComponent()
            .appendingPathComponent("pacmand")
            .path
        if FileSystem.isExecutableFile(sibling) {
            return sibling
        }
        return CLILocator.locate(cli: "pacmand", skippingRealPath: ShimLocator.selfRealPath)
    }
}
