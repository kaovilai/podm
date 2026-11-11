import ContainerizationEXT4
import Foundation
import SystemPackage

/// Reads an ext4 inode's extended attributes (name → value) so `docker diff`
/// can report xattr-only changes (issue #25) — e.g. `setcap` writing
/// `security.capability` without touching bytes or timestamps.
///
/// `ContainerizationEXT4` *writes* xattrs (`EXT4.Formatter.create(xattrs:)`,
/// `EXT4.FileXattrsState`) but exposes no read path from a live `EXT4Reader`:
/// `ExtendedAttribute`'s fields, `XAttrEntry` and the reader's block handle
/// are all module-internal. This reader decodes both on-disk storage forms
/// itself, following the package's own writer as the layout authority
/// (`EXT4+Xattrs.swift`, `FileXattrsState.write` / `writeInlineAttributes` /
/// `writeBlockAttributes`) and its export path (`EXT4Reader+Export.swift`),
/// which pins the two forms:
///
/// - **inline (inode body)**: the inode's `inlineXattrs` bytes — 96 bytes at
///   inode offset 160 (= 128 + `extraIsize` 32). Layout: 4-byte magic header
///   `0xEA020000`, then 16-byte entries growing forward and values packed
///   from the end of the region backwards. Each entry is
///   `nameLength(1), nameIndex(1), valueOffset(u16 LE), valueInum(u32),
///   valueSize(u32 LE), hash(u32)` followed by the name padded to a multiple
///   of 4 (16 + round4(name) bytes per entry, values rounded to 4).
///   `valueOffset` is measured from the end of the magic header — the Linux
///   kernel's `ext4_xattr_ibody_find` sets its base to `IFIRST(header)`
///   (magic + 4).
/// - **block-backed**: the block at the inode's `xattrBlockLow`/`High`
///   pointer holds a 32-byte header (magic, refcount, blocks, hash,
///   checksum, reserved) with entries from byte 32; `valueOffset` is measured
///   from the block start — kernel `ext4_xattr_block_find` bases its offsets
///   on `BHDR(bh)` (block start, offset 0). Block bytes are read through a
///   dedicated `FileHandle` on the same device path because `EXT4Reader`'s
///   own handle and `seek(block:)` are internal.
///
/// `system.data` is excluded from decoded sets: Apple's formatter writes it
/// as an inline-data marker whenever it writes any xattr, and the package's
/// own export skips it — it is on-disk representation, not a user attribute.
final class EXT4XattrReader {
    /// `EXT4.XAttrHeaderMagic` (kernel `EXT4_XATTR_MAGIC`) — internal in the
    /// package, restated here.
    private static let headerMagic: UInt32 = 0xEA02_0000

    /// Size of one xattr entry header (everything before the name).
    private static let entryHeaderSize = 16

    /// Size of the block-backed xattr header (magic … reserved).
    private static let blockHeaderSize = 32

    private let blockSize: UInt64
    private let devicePath: String
    private let onDecode: (@Sendable () -> Void)?
    private lazy var handle: FileHandle? = FileHandle(forReadingAtPath: devicePath)

    init(
        blockDevice: FilePath,
        superBlock: EXT4.SuperBlock,
        onDecode: (@Sendable () -> Void)? = nil
    ) {
        devicePath = blockDevice.description
        blockSize = UInt64(superBlock.blockSize)
        self.onDecode = onDecode
    }

    deinit {
        try? handle?.close()
    }

    // MARK: - Decoding

    /// The full xattr set for an inode whose cached signals are
    /// `inline` (raw inode-body region, nil when all zeros) and `block`
    /// (xattr block pointer, 0 = none).
    ///
    /// Returns nil when the set cannot be read (I/O failure, malformed
    /// region, external-inode values) — callers treat that as "equality
    /// cannot be established", mirroring the walker's unreadable-file
    /// behavior. An inline region without the magic header is *not* an
    /// error: real filesystems only write the header once the first
    /// attribute lands, so leftover non-zero bytes there simply mean no
    /// inline xattrs (any block-backed set is still decoded).
    func xattrs(inline: Data?, block: UInt64) -> [String: Data]? {
        onDecode?()
        var result: [String: Data] = [:]

        if let inline {
            let bytes = [UInt8](inline)
            // A region without the magic header only means "no inline xattrs"
            // (the header lands with the first attribute; leftover non-zero
            // bytes are stale) — skip inline parsing, but keep decoding any
            // block-backed set below rather than discarding it too.
            if bytes.count >= 4, Self.le32(bytes, 0) == Self.headerMagic {
                do {
                    try Self.parseEntries(from: bytes, entriesStart: 4, valueBase: 4, into: &result)
                } catch {
                    return nil
                }
            }
        }

        if block != 0 {
            guard let blockBytes = readXattrBlock(block) else { return nil }
            // A pointed-to block without the xattr magic is corrupt.
            guard Self.le32(blockBytes, 0) == Self.headerMagic else { return nil }
            do {
                try Self.parseEntries(from: blockBytes, entriesStart: Self.blockHeaderSize, valueBase: 0, into: &result)
            } catch {
                return nil
            }
        }

        result.removeValue(forKey: "system.data")
        return result
    }

    /// The inode's raw inline-xattr region, or nil when it is all zeros (no
    /// inline xattrs). A homogeneous `UInt8` tuple occupies its bytes
    /// contiguously, so the region is copied directly — no reflection over 96
    /// fields on the walk's hot path.
    static func inlineRegion(of inode: EXT4.Inode) -> Data? {
        withUnsafeBytes(of: inode.inlineXattrs) { raw in
            guard let base = raw.baseAddress else { return nil }
            let bytes = Data(bytes: base, count: raw.count)
            return bytes.allSatisfy { $0 == 0 } ? nil : bytes
        }
    }

    // MARK: - Entry parsing

    private enum Error: Swift.Error {
        case malformed(_ detail: String)
        case externalValueInode(Int)
    }

    /// Little-endian u16 at `buffer[i]`.
    private static func le16(_ buffer: [UInt8], _ i: Int) -> Int {
        Int(buffer[i]) | (Int(buffer[i + 1]) << 8)
    }

    /// Little-endian u32 at `buffer[i]`.
    private static func le32(_ buffer: [UInt8], _ i: Int) -> Int {
        Int(buffer[i]) | (Int(buffer[i + 1]) << 8) | (Int(buffer[i + 2]) << 16) | (Int(buffer[i + 3]) << 24)
    }

    /// Parses a sequence of ext4 xattr entries, mirroring the layout the
    /// package's writer produces (`FileXattrsState.write`) and its reader
    /// consumes (`FileXattrsState.read`): 16-byte entries — `nameLength`,
    /// `nameIndex`, `valueOffset` (u16 LE, relative to `valueBase`),
    /// `valueInum` (u32; 0 = value stored in this region), `valueSize`
    /// (u32 LE), `hash` — each followed by the name padded to a multiple of
    /// 4. Values live towards the far end of the region. A zeroed 4-byte
    /// slot where the next entry would start terminates the list.
    private static func parseEntries(
        from buffer: [UInt8],
        entriesStart: Int,
        valueBase: Int,
        into result: inout [String: Data]
    ) throws {
        var i = entriesStart
        while i + entryHeaderSize <= buffer.count {
            // The writer leaves 4 zero bytes where the next entry begins.
            if buffer[i] == 0, buffer[i + 1] == 0, buffer[i + 2] == 0, buffer[i + 3] == 0 {
                break
            }

            let nameLength = Int(buffer[i])
            let nameIndex = Int(buffer[i + 1])
            let valueOffset = le16(buffer, i + 2)
            let valueInum = le32(buffer, i + 4)
            let valueSize = le32(buffer, i + 8)

            let nameStart = i + entryHeaderSize
            let nameEnd = nameStart + nameLength
            guard nameEnd <= buffer.count else {
                throw Error.malformed("xattr name overruns region")
            }
            // Linux xattr names are arbitrary non-NUL bytes and need not be
            // ASCII (`user.étiquette` is a legal name). UTF-8 keeps the name
            // byte-preserving for every valid sequence — two files with the
            // same name decode equal, so an unchanged non-ASCII attribute is
            // not reported as Modified. Bytes that are not valid UTF-8 cannot
            // round-trip through String; surface those as unreadable.
            guard let name = String(bytes: buffer[nameStart..<nameEnd], encoding: .utf8) else {
                throw Error.malformed("xattr name is not valid UTF-8")
            }
            if valueInum != 0 {
                // Large values in dedicated inodes (ext4 ea_inode feature).
                // The package cannot read these either; surface as unreadable
                // rather than guessing at the value.
                throw Error.externalValueInode(valueInum)
            }

            let value: Data
            if valueSize == 0 {
                // Zero-size values carry a meaningless offset (the kernel
                // writes e_value_offs = 0 alongside e_value_size = 0).
                value = Data()
            } else {
                let valueStart = valueOffset + valueBase
                guard valueStart >= entriesStart, valueStart + valueSize <= buffer.count else {
                    throw Error.malformed("xattr value overruns region")
                }
                value = Data(buffer[valueStart..<valueStart + valueSize])
            }

            // Name prefixes are stored as an index; decompress via the
            // package's own public map (e.g. 6 + "capability" ->
            // "security.capability").
            result[EXT4.ExtendedAttribute.decompressName(id: nameIndex, suffix: name)] = value

            i = nameStart + ((nameLength + 3) & ~3)
        }
    }

    // MARK: - Block access

    private func readXattrBlock(_ block: UInt64) -> [UInt8]? {
        guard let handle else { return nil }
        do {
            try handle.seek(toOffset: block * blockSize)
            // Require a COMPLETE block: a truncated device makes read return
            // fewer bytes than the block size, and decoding a short buffer
            // would trap on array bounds inside le32 instead of reporting an
            // unreadable set.
            guard let data = try handle.read(upToCount: Int(blockSize)), data.count >= Int(blockSize) else {
                return nil
            }
            return [UInt8](data)
        } catch {
            return nil
        }
    }
}
