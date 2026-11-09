// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

// Small filesystem predicates shared by the podm client. POSIX-flavored
// checks (symlink, socket) use stat/lstat directly because FileManager has no
// equivalents that do not follow symlinks.

enum FileSystem {
    /// realpath(3)-equivalent: resolves symlinks and normalizes. Non-existent
    /// path tails are kept as-is (the resolvable prefix is still resolved).
    static func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// True when path exists, is a regular file (not a directory), and has an
    /// executable bit — the same bar a shell applies when searching $PATH.
    static func isExecutableFile(_ path: String) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: path)
    }

    /// True for symlinks, including dangling ones (lstat does not follow).
    static func isSymlink(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFLNK
    }

    static func isSocket(_ path: String) -> Bool {
        var status = stat()
        return stat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFSOCK
    }
}
