import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import podmd

/// Builds throwaway ext4 filesystems for the changes walker. Mirrors the
/// fixture style of `ClientArchiveServiceExportTests` — `EXT4.Formatter`
/// writes a real ext4 block file into a temp directory, so the walker is
/// exercised against the same reader it uses in production.
struct Ext4TreeFixture {
    let url: URL

    init(name: String) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("changes-fixture-\(UUID().uuidString)-\(name)")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }

    /// - Parameters:
    ///   - files: guest path -> contents. Parent directories are created
    ///     implicitly (`recursion: true`).
    ///   - directories: explicit directory paths (for empty or deleted dirs).
    ///   - symlinks: guest path -> target path.
    ///   - xattrs: guest path -> extended attributes, written through the
    ///     formatter's own `create(xattrs:)` (inline when they fit the
    ///     inode's 96-byte region, block-backed otherwise — so both ext4
    ///     xattr storage forms are exercised against the same writer that
    ///     production code uses).
    ///   - mtime: every entry gets this fixed timestamp, keeping fixtures
    ///     deterministic (the walker compares mtimes).
    @discardableResult
    func write(
        files: [String: String] = [:],
        directories: [String] = [],
        symlinks: [String: String] = [:],
        fileModes: [String: UInt16] = [:],
        xattrs: [String: [String: Data]] = [:],
        mtime: Date = Date(timeIntervalSince1970: 1_000_000_000)
    ) throws -> URL {
        let device = url.appendingPathComponent("rootfs.ext4")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let formatter = try EXT4.Formatter(FilePath(device.path))
        let ts = FileTimestamps(access: mtime, modification: mtime, creation: mtime)

        for dir in directories.sorted() {
            try formatter.create(
                path: FilePath(dir),
                mode: EXT4.Inode.Mode(.S_IFDIR, 0o755),
                ts: ts
            )
        }
        for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
            let stream = InputStream(data: Data(contents.utf8))
            stream.open()
            try formatter.create(
                path: FilePath(path),
                mode: EXT4.Inode.Mode(.S_IFREG, fileModes[path] ?? 0o644),
                ts: ts,
                buf: stream,
                xattrs: xattrs[path],
                recursion: true
            )
        }
        for (path, target) in symlinks.sorted(by: { $0.key < $1.key }) {
            try formatter.create(
                path: FilePath(path),
                link: FilePath(target),
                mode: EXT4.Inode.Mode(.S_IFLNK, 0o777),
                ts: ts
            )
        }
        try formatter.close()
        return device
    }
}

@Suite("ContainerChangesWalker")
struct ContainerChangesWalkerTests {

    @Test("added, deleted, modified, retargeted and unchanged entries all classify correctly")
    func classifiesChanges() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }

        try baseline.write(
            files: [
                "/keep.txt": "keep",
                "/gone.txt": "old",
                "/modified.txt": "before",
                "/etc/hostname": "alpha",
                "/etc/keep.cfg": "same",
                "/stamp.txt": "identical bytes",
                "/olddir/inner.txt": "x",
            ],
            symlinks: ["/link": "/keep.txt"])

        try current.write(
            files: [
                "/keep.txt": "keep",
                "/modified.txt": "after",
                "/etc/hostname": "beta",
                "/etc/keep.cfg": "same",
                "/stamp.txt": "identical bytes",
                "/new.txt": "added",
                "/newdir/inner.txt": "y",
            ],
            symlinks: ["/link": "/new.txt"])

        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))

        #expect(
            changes == [
                // /etc itself is NOT reported: its child set is unchanged and only
                // mtime-inspected files beneath it changed — matching docker diff.
                ContainerFileChange(path: "/etc/hostname", kind: .modified),
                ContainerFileChange(path: "/gone.txt", kind: .deleted),
                ContainerFileChange(path: "/link", kind: .modified),
                ContainerFileChange(path: "/modified.txt", kind: .modified),
                ContainerFileChange(path: "/new.txt", kind: .added),
                ContainerFileChange(path: "/newdir", kind: .added),
                ContainerFileChange(path: "/newdir/inner.txt", kind: .added),
                ContainerFileChange(path: "/olddir", kind: .deleted),
                ContainerFileChange(path: "/olddir/inner.txt", kind: .deleted),
            ])
    }

    @Test("a file whose bytes are identical reports nothing even when its mtime diverges")
    func hashRescue() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }

        try baseline.write(files: ["/stamp.txt": "identical bytes"])
        // Same contents, later timestamp: the walker must hash and stay quiet.
        try current.write(
            files: ["/stamp.txt": "identical bytes"],
            mtime: Date(timeIntervalSince1970: 2_000_000_000))

        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))

        #expect(changes.isEmpty)
    }

    @Test("a directory whose child set changed is itself Modified")
    func directoryChildSetDivergence() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }

        try baseline.write(files: ["/data/a.txt": "a"])
        try current.write(files: ["/data/b.txt": "b"])

        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))

        #expect(
            changes == [
                ContainerFileChange(path: "/data", kind: .modified),
                ContainerFileChange(path: "/data/a.txt", kind: .deleted),
                ContainerFileChange(path: "/data/b.txt", kind: .added),
            ])
    }

    @Test("identical trees produce no changes")
    func identicalTrees() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }

        let tree: ([String: String], [String], [String: String]) = (
            ["/etc/hostname": "web", "/var/log/app.log": "hello"],
            ["/emptydir"],
            ["/bin/sh": "/bin/busybox"]
        )
        try baseline.write(files: tree.0, directories: tree.1, symlinks: tree.2)
        try current.write(files: tree.0, directories: tree.1, symlinks: tree.2)

        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))

        #expect(changes.isEmpty)
    }

    @Test("baseline resolution: the descriptor digest keys the snapshot directly")
    func baselineDirectDigest() throws {
        let fixture = Ext4TreeFixture(name: "store")
        defer { fixture.cleanUp() }
        try fixture.write(files: ["/bin/true": "elf"])

        let snapshot =
            fixture.url
            .appendingPathComponent("snapshots")
            .appendingPathComponent("aaaa")
            .appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(
            at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fixture.url.appendingPathComponent("rootfs.ext4"), to: snapshot)

        let resolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:aaaa")
        #expect(resolved?.path == snapshot.path)
    }

    @Test("baseline resolution: an index digest resolves through the content store to the platform manifest snapshot")
    func baselineViaIndexBlob() throws {
        let fixture = Ext4TreeFixture(name: "store")
        defer { fixture.cleanUp() }
        try fixture.write(files: ["/bin/true": "elf"])

        // Snapshot keyed by the platform-manifest digest (the arm64 child).
        let snapshot =
            fixture.url
            .appendingPathComponent("snapshots")
            .appendingPathComponent("bbbb")
            .appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(
            at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fixture.url.appendingPathComponent("rootfs.ext4"), to: snapshot)

        // Image index blob pointing at it, plus an attestation twin that must
        // be skipped and an amd64 child that loses to arm64.
        let index =
            """
            {"schemaVersion": 2, "manifests": [
              {"digest": "sha256:cccc", "mediaType": "application/vnd.oci.image.manifest.v1+json",
               "platform": {"architecture": "amd64", "os": "linux"}},
              {"digest": "sha256:dddd", "mediaType": "application/vnd.oci.image.manifest.v1+json",
               "annotations": {"vnd.docker.reference.type": "attestation-manifest"}},
              {"digest": "sha256:bbbb", "mediaType": "application/vnd.oci.image.manifest.v1+json",
               "platform": {"architecture": "arm64", "os": "linux", "variant": "v8"}}
            ]}
            """
        let blob =
            fixture.url
            .appendingPathComponent("content")
            .appendingPathComponent("blobs")
            .appendingPathComponent("sha256")
        try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: true)
        try Data(index.utf8).write(to: blob.appendingPathComponent("eeee"))

        let resolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:eeee")
        #expect(resolved?.path == snapshot.path)
    }

    @Test("baseline resolution falls back to snapshot-info's recorded source")
    func baselineViaSnapshotInfo() throws {
        let fixture = Ext4TreeFixture(name: "store")
        defer { fixture.cleanUp() }
        try fixture.write(files: ["/bin/true": "elf"])

        // The snapshot file lives at a non-default location recorded in
        // snapshot-info (Apple's Filesystem.source).
        let snapshot = fixture.url.appendingPathComponent("elsewhere.ext4")
        try FileManager.default.moveItem(
            at: fixture.url.appendingPathComponent("rootfs.ext4"), to: snapshot)

        let snapshotDir = fixture.url.appendingPathComponent("snapshots").appendingPathComponent("ffff")
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        let info = #"{"source":"\#(snapshot.path)","destination":"/","type":"block","format":"ext4"}"#
        try Data(info.utf8).write(to: snapshotDir.appendingPathComponent("snapshot-info"))

        let resolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:ffff")
        #expect(resolved?.path == snapshot.path)
    }

    @Test("baseline resolution returns nil when nothing matches")
    func baselineMissing() {
        let fixture = Ext4TreeFixture(name: "store")
        defer { fixture.cleanUp() }

        let resolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:deadbeef")
        #expect(resolved == nil)
    }

    @Test("a file replaced by a directory reports Modified, with new children Added")
    func fileToDirectorySwap() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }
        try baseline.write(files: ["/swap": "was-a-file", "/keep": "data"])
        try current.write(files: ["/swap/child": "inside", "/keep": "data"])
        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))
        #expect(
            changes == [
                ContainerFileChange(path: "/swap", kind: .modified),
                ContainerFileChange(path: "/swap/child", kind: .added),
            ])
    }

    @Test("a chmod-only change on a regular file reports Modified")
    func chmodOnlyChange() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }
        // Identical bytes, identical timestamps — only the permission bits
        // differ. Content heuristics must not suppress a mode change.
        try baseline.write(files: ["/app": "payload"])
        try current.write(files: ["/app": "payload"], fileModes: ["/app": 0o755])
        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))
        #expect(changes == [ContainerFileChange(path: "/app", kind: .modified)])
    }

    // MARK: - Extended attributes (issue #25)

    /// A realistic `security.capability` value (vfs cap_v2: magic_etc then
    /// two 8-byte capability words).
    private static var capabilityBlob: Data {
        var blob = Data(repeating: 0, count: 20)
        blob[1] = 0x01  // VFS_CAP_REVISION_2
        blob[3] = 0x40  // CAP_NET_BIND_SERVICE in the effective set
        return blob
    }

    @Test("an xattr-only change (setcap writing security.capability) reports Modified")
    func xattrOnlyChange() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }
        // Identical bytes and metadata — only an xattr was added, exactly
        // what `setcap cap_net_bind_service=+ep` does. The hash rescue must
        // suppress the content comparison and the xattr check must still
        // fire.
        try baseline.write(files: ["/usr/bin/custom": "#!/bin/sh\nexit 0\n"])
        try current.write(
            files: ["/usr/bin/custom": "#!/bin/sh\nexit 0\n"],
            xattrs: ["/usr/bin/custom": ["security.capability": Self.capabilityBlob]])

        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))

        #expect(changes == [ContainerFileChange(path: "/usr/bin/custom", kind: .modified)])
    }

    @Test("a changed xattr value reports Modified")
    func xattrValueChanged() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }
        var otherCap = Self.capabilityBlob
        otherCap[3] = 0x20  // a different capability

        try baseline.write(
            files: ["/usr/bin/custom": "bin"],
            xattrs: ["/usr/bin/custom": ["security.capability": Self.capabilityBlob]])
        try current.write(
            files: ["/usr/bin/custom": "bin"],
            xattrs: ["/usr/bin/custom": ["security.capability": otherCap]])

        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))

        #expect(changes == [ContainerFileChange(path: "/usr/bin/custom", kind: .modified)])
    }

    @Test("a removed xattr reports Modified")
    func xattrRemoved() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }
        try baseline.write(
            files: ["/file": "bytes"],
            xattrs: ["/file": ["user.label": Data("mark".utf8)]])
        try current.write(files: ["/file": "bytes"])

        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))

        #expect(changes == [ContainerFileChange(path: "/file", kind: .modified)])
    }

    @Test("identical xattrs report nothing, including block-backed ones")
    func identicalXattrsAreQuiet() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }
        // The 256-byte values cannot fit the inode's 96-byte inline region,
        // so these land in block-backed xattr storage — the comparison must
        // read and match them there too.
        let sharedXattrs: [String: [String: Data]] = [
            "/inline": ["user.small": Data("fits-inline".utf8)],
            "/blockbacked": ["user.big": Data(repeating: 0x5a, count: 256)],
        ]
        try baseline.write(
            files: ["/inline": "a", "/blockbacked": "b"],
            xattrs: sharedXattrs)
        try current.write(
            files: ["/inline": "a", "/blockbacked": "b"],
            xattrs: sharedXattrs)

        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))

        #expect(changes.isEmpty)
    }

    @Test("a changed block-backed xattr reports Modified")
    func blockBackedXattrChange() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }
        try baseline.write(
            files: ["/file": "bytes"],
            xattrs: ["/file": ["user.big": Data(repeating: 0x11, count: 256)]])
        try current.write(
            files: ["/file": "bytes"],
            xattrs: ["/file": ["user.big": Data(repeating: 0x22, count: 256)]])

        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"))

        #expect(changes == [ContainerFileChange(path: "/file", kind: .modified)])
    }

    /// Thread-safe tally of xattr decodes for one `changes()` invocation
    /// (the walk runs on a detached task, the assertion on the test task).
    private final class DecodeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func tick() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    @Test("files without xattrs never trigger an xattr decode")
    func noXattrDecodeFastPath() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }
        try baseline.write(
            files: ["/keep": "same", "/stamp": "identical bytes"],
            directories: ["/emptydir"],
            symlinks: ["/link": "/keep"])
        try current.write(
            files: ["/keep": "same", "/stamp": "identical bytes"],
            directories: ["/emptydir"],
            symlinks: ["/link": "/keep"])

        let counter = DecodeCounter()
        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"),
            onXattrDecode: { counter.tick() })

        #expect(changes.isEmpty)
        #expect(counter.value == 0)
    }

    @Test("a diverging xattr signal does decode both sides")
    func xattrDivergenceDecodes() async throws {
        let baseline = Ext4TreeFixture(name: "baseline")
        let current = Ext4TreeFixture(name: "current")
        defer {
            baseline.cleanUp()
            current.cleanUp()
        }
        try baseline.write(files: ["/file": "bytes"])
        try current.write(
            files: ["/file": "bytes"],
            xattrs: ["/file": ["user.label": Data("v".utf8)]])

        let counter = DecodeCounter()
        let changes = try await ContainerChangesWalker.changes(
            baselineBlockDevice: baseline.url.appendingPathComponent("rootfs.ext4"),
            currentBlockDevice: current.url.appendingPathComponent("rootfs.ext4"),
            onXattrDecode: { counter.tick() })

        #expect(changes == [ContainerFileChange(path: "/file", kind: .modified)])
        // Both sides were decoded (the baseline resolves to an empty set).
        #expect(counter.value == 2)
    }

    @Test("baseline resolution with a known platform never falls back to another platform's snapshot")
    func baselineMatchesContainerPlatform() throws {
        let fixture = Ext4TreeFixture(name: "store")
        defer { fixture.cleanUp() }
        // BOTH platform snapshots exist on disk.
        for digest in ["bbbb", "cccc"] {
            try fixture.write(files: ["/bin/true": "elf"])
            let snapshot =
                fixture.url
                .appendingPathComponent("snapshots")
                .appendingPathComponent(digest)
                .appendingPathComponent("snapshot")
            try FileManager.default.createDirectory(
                at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: fixture.url.appendingPathComponent("rootfs.ext4"), to: snapshot)
        }
        let index =
            """
            {"schemaVersion": 2, "manifests": [
              {"digest": "sha256:cccc", "mediaType": "application/vnd.oci.image.manifest.v1+json",
               "platform": {"architecture": "amd64", "os": "linux"}},
              {"digest": "sha256:bbbb", "mediaType": "application/vnd.oci.image.manifest.v1+json",
               "platform": {"architecture": "arm64", "os": "linux"}}
            ]}
            """
        let blob =
            fixture.url
            .appendingPathComponent("content")
            .appendingPathComponent("blobs")
            .appendingPathComponent("sha256")
        try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: true)
        try Data(index.utf8).write(to: blob.appendingPathComponent("eeee"))

        let arm64 = try Platform(from: "linux/arm64")
        let amd64 = try Platform(from: "linux/amd64")

        // arm64 container → the arm64 snapshot, never amd64.
        let armResolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:eeee", platform: arm64)
        #expect(armResolved?.lastPathComponent == "snapshot")
        #expect(armResolved?.deletingLastPathComponent().lastPathComponent == "bbbb")

        // amd64 (Rosetta) container → the amd64 snapshot, never arm64.
        let amdResolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:eeee", platform: amd64)
        #expect(amdResolved?.deletingLastPathComponent().lastPathComponent == "cccc")

        // A platform with no matching child gets NO baseline (missing, not
        // wrong-tree fallback) — the route answers 500 with a diagnostic.
        let riscv = try Platform(from: "linux/riscv64")
        let noneResolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:eeee", platform: riscv)
        #expect(noneResolved == nil)
    }

    @Test("baseline resolution with an unknown platform still prefers the host architecture")
    func baselineUnknownPlatformPrefersHost() throws {
        let fixture = Ext4TreeFixture(name: "store")
        defer { fixture.cleanUp() }
        for digest in ["bbbb", "cccc"] {
            try fixture.write(files: ["/bin/true": "elf"])
            let snapshot =
                fixture.url
                .appendingPathComponent("snapshots")
                .appendingPathComponent(digest)
                .appendingPathComponent("snapshot")
            try FileManager.default.createDirectory(
                at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: fixture.url.appendingPathComponent("rootfs.ext4"), to: snapshot)
        }
        let index =
            """
            {"schemaVersion": 2, "manifests": [
              {"digest": "sha256:cccc", "mediaType": "application/vnd.oci.image.manifest.v1+json",
               "platform": {"architecture": "amd64", "os": "linux"}},
              {"digest": "sha256:bbbb", "mediaType": "application/vnd.oci.image.manifest.v1+json",
               "platform": {"architecture": "arm64", "os": "linux"}}
            ]}
            """
        let blob =
            fixture.url
            .appendingPathComponent("content")
            .appendingPathComponent("blobs")
            .appendingPathComponent("sha256")
        try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: true)
        try Data(index.utf8).write(to: blob.appendingPathComponent("eeee"))

        // Platform unknown: arm64 (the host) wins even though both exist —
        // this is the pre-existing behavior, now proven by both snapshots
        // being present.
        let resolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:eeee", platform: nil)
        #expect(resolved?.deletingLastPathComponent().lastPathComponent == "bbbb")
    }

    @Test("baseline resolution matches the platform variant when both sides specify one")
    func baselineVariantMatching() throws {
        let fixture = Ext4TreeFixture(name: "store")
        defer { fixture.cleanUp() }
        // Both arm64 variants have snapshots on disk.
        for digest in ["v8snap", "v7snap"] {
            try fixture.write(files: ["/bin/true": "elf"])
            let snapshot =
                fixture.url
                .appendingPathComponent("snapshots")
                .appendingPathComponent(digest)
                .appendingPathComponent("snapshot")
            try FileManager.default.createDirectory(
                at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: fixture.url.appendingPathComponent("rootfs.ext4"), to: snapshot)
        }
        let index =
            """
            {"schemaVersion": 2, "manifests": [
              {"digest": "sha256:v8snap", "mediaType": "application/vnd.oci.image.manifest.v1+json",
               "platform": {"architecture": "arm64", "os": "linux", "variant": "v8"}},
              {"digest": "sha256:v7snap", "mediaType": "application/vnd.oci.image.manifest.v1+json",
               "platform": {"architecture": "arm64", "os": "linux", "variant": "v7"}}
            ]}
            """
        let blob =
            fixture.url
            .appendingPathComponent("content")
            .appendingPathComponent("blobs")
            .appendingPathComponent("sha256")
        try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: true)
        try Data(index.utf8).write(to: blob.appendingPathComponent("index"))

        let v7 = Platform(arch: "arm64", os: "linux", variant: "v7")
        let v7Resolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:index", platform: v7)
        #expect(v7Resolved?.deletingLastPathComponent().lastPathComponent == "v7snap")

        let v8 = Platform(arch: "arm64", os: "linux", variant: "v8")
        let v8Resolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:index", platform: v8)
        #expect(v8Resolved?.deletingLastPathComponent().lastPathComponent == "v8snap")

        // No variant requested: either arm64 child is compatible — a snapshot
        // resolves (the arm64-preference order picks the first child).
        let unspecified = Platform(arch: "arm64", os: "linux")
        let anyResolved = ContainerChangesWalker.baselineSnapshotPath(
            appSupportURL: fixture.url, imageDescriptorDigest: "sha256:index", platform: unspecified)
        #expect(anyResolved != nil)
    }
}
