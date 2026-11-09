// SPDX-License-Identifier: Apache-2.0

import Foundation

// Locates the podm daemon binary (podmd).

enum DaemonLocator {
    /// Prefer a podmd sitting next to this shim's real binary (same directory
    /// after symlink resolution — the usual make/install layout), then fall back
    /// to a $PATH scan.
    static func locate() -> String? {
        let sibling = URL(fileURLWithPath: ShimLocator.selfRealPath)
            .deletingLastPathComponent()
            .appendingPathComponent("podmd")
            .path
        if FileSystem.isExecutableFile(sibling) {
            return sibling
        }
        return CLILocator.locate(cli: "podmd", skippingRealPath: ShimLocator.selfRealPath)
    }
}
