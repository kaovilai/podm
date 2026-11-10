import ContainerizationEXT4
import ContainerizationOCI
import CryptoKit
import Foundation
import SystemPackage

/// One `docker diff` filesystem change, matching moby's `archive.Change`
/// kinds: 0 = Modified, 1 = Added, 2 = Deleted.
struct ContainerFileChange: Sendable, Equatable {
    enum Kind: Int, Sendable {
        case modified = 0
        case added = 1
        case deleted = 2
    }

    /// Absolute path inside the container, e.g. `/etc/passwd`.
    let path: String
    let kind: Kind
}

/// Walks a container's live ext4 rootfs against the image's unpacked ext4
/// snapshot to produce `docker diff` / `podman diff` changes.
///
/// Apple Container keeps every unpacked image as a per-image ext4 snapshot on
/// disk (`<appSupport>/snapshots/<manifest digest>/snapshot`, see Apple's
/// `SnapshotStore`), and a container's rootfs
/// (`<appSupport>/containers/<id>/rootfs.ext4`) starts life as a copy of that
/// snapshot. The image snapshot therefore IS the pristine baseline — no
/// create-time capture is needed.
///
/// The walk compares (type, mode, uid/gid, size, mtime, ctime) metadata per path and only
/// hashes the contents of regular files whose metadata diverges, confirming
/// Modified entries (and suppressing false positives when a copy rewrites
/// timestamps). Directories are reported Modified only when their immediate
/// child set or mode differs — matching what `docker diff` shows in practice
/// and avoiding false positives from timestamp-only directory churn.
///
/// Reading the rootfs while the guest VM writes to it yields a volatile
/// snapshot — the same guarantee moby gives when diffing a running container.
enum ContainerChangesWalker {
    /// Resolve the image snapshot ext4 that baselines `imageDescriptorDigest`.
    ///
    /// Snapshots are keyed by the image's *platform manifest* digest, while a
    /// container's `ImageDescription.descriptor` usually carries the image
    /// *index* digest. Candidates are tried in order:
    ///   1. the descriptor digest itself (single-manifest images),
    ///   2. every platform-manifest child digest found in the index blob
    ///      (`<appSupport>/content/blobs/sha256/<digest>`), linux/arm64 first,
    ///      attestation manifests skipped.
    /// Each candidate resolves via `snapshots/<digest>/snapshot`, falling back
    /// to the path recorded in `snapshot-info` (Apple's `Filesystem.source`).
    /// - Parameter platform: the platform the CONTAINER was created for
    ///   (persisted at create time). When present, only index children whose
    ///   os/architecture match may serve as the baseline — an amd64/Rosetta
    ///   container must never be diffed against the arm64 snapshot (every
    ///   untouched file would report as changed). No cross-platform fallback:
    ///   a matching child without a snapshot is a missing baseline, not a
    ///   reason to compare against the wrong tree.
    static func baselineSnapshotPath(
        appSupportURL: URL,
        imageDescriptorDigest: String,
        platform: ContainerizationOCI.Platform? = nil
    ) -> URL? {
        for digest in candidateBaselineDigests(
            appSupportURL: appSupportURL, imageDescriptorDigest: imageDescriptorDigest, platform: platform)
        {
            if let path = snapshotPath(forDigest: digest, appSupportURL: appSupportURL) {
                return path
            }
        }
        return nil
    }

    /// Diff two ext4 block devices. Runs the (synchronous) EXT4 walk on a
    /// utility task so the event loop is not blocked on disk I/O.
    static func changes(baselineBlockDevice: URL, currentBlockDevice: URL) async throws -> [ContainerFileChange] {
        let baselinePath = baselineBlockDevice.path
        let currentPath = currentBlockDevice.path
        return try await Task.detached(priority: .utility) {
            let baseline = try EXT4.EXT4Reader(blockDevice: FilePath(baselinePath))
            let current = try EXT4.EXT4Reader(blockDevice: FilePath(currentPath))
            var changes: [ContainerFileChange] = []
            try walk(baseline: baseline, current: current, path: "/", into: &changes)
            return changes.sorted { $0.path < $1.path }
        }.value
    }

    // MARK: - Baseline resolution

    private static func candidateBaselineDigests(
        appSupportURL: URL, imageDescriptorDigest: String, platform: ContainerizationOCI.Platform?
    ) -> [String] {
        var candidates = [imageDescriptorDigest]

        // The descriptor digest may be an image index; its platform-manifest
        // children key the actual snapshots.
        let indexBlob =
            appSupportURL
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
            .appendingPathComponent(imageDescriptorDigest.trimmingDigestPrefix, isDirectory: false)

        guard
            let data = try? Data(contentsOf: indexBlob),
            let index = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let manifests = index["manifests"] as? [[String: Any]]
        else {
            return candidates
        }

        let childDigests: [(digest: String, arm64: Bool)] = manifests.compactMap { manifest in
            guard manifest["platform"] != nil else { return nil }
            if let annotations = manifest["annotations"] as? [String: String],
                annotations["vnd.docker.reference.type"] == "attestation-manifest"
            {
                return nil
            }
            guard let digest = manifest["digest"] as? String else { return nil }
            let childPlatform = manifest["platform"] as? [String: Any]
            let isArm64 = (childPlatform?["architecture"] as? String) == "arm64"
            return (digest: digest, arm64: isArm64)
        }

        if let platform {
            // The container's own platform decides — only matching children
            // are candidates, and a mismatched snapshot is never a fallback.
            let matching = childDigests.filter { child in
                let childPlatform =
                    manifests
                    .first { ($0["digest"] as? String) == child.digest }?["platform"] as? [String: Any]
                return (childPlatform?["os"] as? String) == platform.os
                    && (childPlatform?["architecture"] as? String) == platform.architecture
            }
            candidates.append(contentsOf: matching.map(\.digest))
        } else {
            // Platform unknown: prefer the host platform's snapshot.
            candidates.append(contentsOf: childDigests.sorted { $0.arm64 && !$1.arm64 }.map(\.digest))
        }
        return candidates
    }

    private static func snapshotPath(forDigest digest: String, appSupportURL: URL) -> URL? {
        let snapshotDir =
            appSupportURL
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(digest.trimmingDigestPrefix, isDirectory: true)

        let direct = snapshotDir.appendingPathComponent("snapshot", isDirectory: false)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }

        // Fall back to the path Apple's own snapshot-info records.
        let infoURL = snapshotDir.appendingPathComponent("snapshot-info", isDirectory: false)
        guard
            let data = try? Data(contentsOf: infoURL),
            let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let source = info["source"] as? String,
            FileManager.default.fileExists(atPath: source)
        else {
            return nil
        }
        return URL(fileURLWithPath: source)
    }

    // MARK: - Tree walk

    private struct TreeEntry {
        let typeTag: UInt16
        let isDirectory: Bool
        let isSymlink: Bool
        let size: Int64
        let mtime: UInt32
        /// Inode change time: bumped by any metadata/data write and NOT
        /// settable through utimes() — the archive API can preserve mtime,
        /// but a rewritten file still bumps ctime, so same-size/same-mtime
        /// content rewrites stay detectable without hashing every file.
        let ctime: UInt32
        let mode: UInt16
        let uid: UInt16
        let gid: UInt16

        init(inode: EXT4.Inode) {
            typeTag = inode.mode & 0xF000
            isDirectory = inode.isDirectory
            isSymlink = inode.isSymlink
            size = inode.size
            mtime = inode.mtime
            ctime = inode.ctime
            mode = inode.mode
            uid = inode.uid
            gid = inode.gid
        }

        /// Metadata equality for content-bearing entries: everything a
        /// `docker diff` treats as a change EXCEPT the timestamp pair,
        /// which callers handle through hash/ctime confirmation.
        func metadataMatches(_ other: TreeEntry) -> Bool {
            mode == other.mode && uid == other.uid && gid == other.gid
        }
    }

    private static func walk(
        baseline: EXT4.EXT4Reader,
        current: EXT4.EXT4Reader,
        path: String,
        into changes: inout [ContainerFileChange]
    ) throws {
        // A side that does not have the directory (or holds a non-directory
        // there) lists as empty, so added/deleted subtrees fall out naturally.
        let baseEntries = (try? list(baseline, at: path)) ?? [:]
        let currentEntries = (try? list(current, at: path)) ?? [:]
        try walk(
            baseline: baseline,
            current: current,
            path: path,
            baseEntries: baseEntries,
            currentEntries: currentEntries,
            into: &changes
        )
    }

    /// One directory level. `baseEntries`/`currentEntries` carry the listings
    /// of `path` on each side (`nil` when that side has nothing there).
    private static func walk(
        baseline: EXT4.EXT4Reader,
        current: EXT4.EXT4Reader,
        path: String,
        baseEntries: [String: TreeEntry],
        currentEntries: [String: TreeEntry],
        into changes: inout [ContainerFileChange]
    ) throws {
        for name in Set(baseEntries.keys).union(currentEntries.keys).sorted() {
            let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            let base = baseEntries[name]
            let currentEntry = currentEntries[name]

            switch (base, currentEntry) {
            case (nil, nil):
                continue

            case (nil, .some):
                changes.append(ContainerFileChange(path: childPath, kind: .added))

            case (.some, nil):
                changes.append(ContainerFileChange(path: childPath, kind: .deleted))

            case (.some(let b), .some(let c)):
                if b.typeTag != c.typeTag {
                    // file <-> directory <-> symlink swap: report the path
                    // itself as modified and let the recursion below surface
                    // the old/new children as deleted/added.
                    changes.append(ContainerFileChange(path: childPath, kind: .modified))
                } else if c.isDirectory {
                    // Directories are Modified only when their child set,
                    // mode, or ownership changed — timestamp-only churn is
                    // not a content change (docker diff shows the same
                    // behavior). Both sides hold a directory here, so a
                    // listing failure is an ERROR, not an empty listing —
                    // silently treating it as empty would fabricate
                    // additions/deletions or mask the whole subtree.
                    let childBase = try list(baseline, at: childPath)
                    let childCurrent = try list(current, at: childPath)
                    if Set(childBase.keys) != Set(childCurrent.keys) || !b.metadataMatches(c) {
                        changes.append(ContainerFileChange(path: childPath, kind: .modified))
                    }
                    try walk(
                        baseline: baseline, current: current, path: childPath,
                        baseEntries: childBase, currentEntries: childCurrent, into: &changes)
                    continue
                } else if c.isSymlink {
                    // Symlinks: target or ownership change (mode/uid/gid of
                    // the link inode itself).
                    if b.size != c.size
                        || !b.metadataMatches(c)
                        || symlinkTarget(baseline, at: childPath) != symlinkTarget(current, at: childPath)
                    {
                        changes.append(ContainerFileChange(path: childPath, kind: .modified))
                    }
                } else {
                    // Regular file (and any other non-directory, non-symlink
                    // inode type — the branches above took dirs and symlinks).
                    // A chmod/chown alone is a modification: moby reports mode
                    // and ownership changes even when the bytes are identical,
                    // so they are checked BEFORE any content heuristic can
                    // suppress them.
                    if !b.metadataMatches(c) {
                        changes.append(ContainerFileChange(path: childPath, kind: .modified))
                    } else if b.size != c.size {
                        // Different sizes mean different contents — no hash
                        // needed (also avoids reading both files in vain).
                        changes.append(ContainerFileChange(path: childPath, kind: .modified))
                    } else if b.mtime != c.mtime || b.ctime != c.ctime {
                        // Same size, but a timestamp moved. mtime alone can be
                        // rewritten without touching the bytes (rootfs-creation
                        // timestamp churn) — hash to confirm. ctime cannot be
                        // forged via utimes(), so an archive-API replace that
                        // preserves mtime still lands here.
                        if isModifiedFile(baseline: baseline, at: childPath, current: current) {
                            changes.append(ContainerFileChange(path: childPath, kind: .modified))
                        }
                    }
                }
            }

            // Recurse wherever either side has a directory, so deleted and
            // added subtrees enumerate every descendant. A side that IS a
            // directory must list or throw — an error is never an empty
            // listing; only the absent side contributes nothing.
            if base?.isDirectory == true || currentEntry?.isDirectory == true {
                let childBase =
                    base?.isDirectory == true ? try list(baseline, at: childPath) : [:]
                let childCurrent =
                    currentEntry?.isDirectory == true ? try list(current, at: childPath) : [:]
                try walk(
                    baseline: baseline, current: current, path: childPath,
                    baseEntries: childBase, currentEntries: childCurrent, into: &changes)
            }
        }
    }

    /// Immediate child entries of the directory at `path`, keyed by name.
    /// Stats without following symlinks so a link keeps its own inode (type,
    /// size = target length) and dangling links still list.
    private static func list(_ reader: EXT4.EXT4Reader, at path: String) throws -> [String: TreeEntry] {
        var entries: [String: TreeEntry] = [:]
        for name in try reader.listDirectory(FilePath(path)) {
            guard name != ".", name != ".." else { continue }
            let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            let (_, inode) = try reader.stat(FilePath(childPath), followSymlinks: false)
            entries[name] = TreeEntry(inode: inode)
        }
        return entries
    }

    /// Content comparison for metadata-divergent regular files: hash both
    /// sides and report Modified only when they truly differ. A file that
    /// cannot be read is treated as modified — its metadata already diverged
    /// and equality cannot be established.
    private static func isModifiedFile(
        baseline: EXT4.EXT4Reader,
        at path: String,
        current: EXT4.EXT4Reader
    ) -> Bool {
        guard
            let baseDigest = contentDigest(baseline, at: path),
            let currentDigest = contentDigest(current, at: path)
        else {
            return true
        }
        return baseDigest != currentDigest
    }

    private static func contentDigest(_ reader: EXT4.EXT4Reader, at path: String) -> String? {
        guard let data = try? reader.readFile(at: FilePath(path)) else { return nil }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func symlinkTarget(_ reader: EXT4.EXT4Reader, at path: String) -> String? {
        guard let data = try? reader.readFile(at: FilePath(path), followSymlinks: false) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
