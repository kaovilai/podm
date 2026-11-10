import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import podmd

/// Unit tests for the hand-rolled ext4 xattr decoder. The on-disk layout is
/// pinned by the formatter's own writer (`EXT4+Xattrs.swift`,
/// `FileXattrsState.write` / `writeInlineAttributes` / `writeBlockAttributes`)
/// and its export path (`EXT4Reader+Export.swift`); the tests below hand-craft
/// regions in that layout to cover cases the formatter cannot produce
/// (differing byte layouts of equal sets, garbage regions, corrupt offsets).
@Suite("EXT4XattrReader")
struct EXT4XattrReaderTests {
    /// Hand-crafts a 96-byte inline xattr region following the exact layout
    /// the formatter's writer produces: 4-byte magic 0xEA020000, 16-byte
    /// entries forward from offset 4, values packed from the end of the
    /// region backwards, `valueOffset` measured from the end of the magic
    /// header.
    private func inlineRegion(_ attrs: [(index: UInt8, name: String, value: [UInt8])]) -> Data {
        var buffer = [UInt8](repeating: 0, count: 96)
        func put16(_ value: Int, at index: Int) {
            buffer[index] = UInt8(value & 0xff)
            buffer[index + 1] = UInt8((value >> 8) & 0xff)
        }
        func put32(_ value: Int, at index: Int) {
            for i in 0..<4 {
                buffer[index + i] = UInt8((value >> (8 * i)) & 0xff)
            }
        }
        put32(0xEA02_0000, at: 0)
        var front = 4
        var end = 96
        for attr in attrs {
            let paddedValue = (attr.value.count + 3) & ~3
            end -= paddedValue
            buffer[front] = UInt8(attr.name.count)
            buffer[front + 1] = attr.index
            put16(end - 4, at: front + 2)  // value offset, relative to magic end
            put32(attr.value.count, at: front + 8)
            for (i, byte) in attr.name.utf8.enumerated() {
                buffer[front + 16 + i] = byte
            }
            for (i, byte) in attr.value.enumerated() {
                buffer[end + i] = byte
            }
            front += 16 + ((attr.name.count + 3) & ~3)
        }
        return Data(buffer)
    }

    /// A reader over a formatter-written fixture device (the superblock
    /// supplies the block size; the device exists so block reads would work).
    private func makeReader() throws -> (fixture: Ext4TreeFixture, device: URL, reader: EXT4XattrReader) {
        let fixture = Ext4TreeFixture(name: "xattr-reader")
        let device = try fixture.write(files: ["/seed": "seed"])
        let ext4Reader = try EXT4.EXT4Reader(blockDevice: FilePath(device.path))
        let xattrReader = EXT4XattrReader(blockDevice: FilePath(device.path), superBlock: ext4Reader.superBlock)
        return (fixture, device, xattrReader)
    }

    @Test("decodes a hand-crafted region, expanding name prefixes")
    func decodesHandCraftedRegion() throws {
        let (fixture, _, reader) = try makeReader()
        defer { fixture.cleanUp() }

        let region = inlineRegion([
            (index: 1, name: "a", value: [1, 2, 3, 4]),
            (index: 6, name: "capability", Array(0..<20)),
        ])

        #expect(
            reader.xattrs(inline: region, block: 0)
                == ["user.a": Data([1, 2, 3, 4]), "security.capability": Data(Array(0..<20))])
    }

    @Test("two differently laid-out regions holding the same set decode equal")
    func differentlyOrderedEqualSetsDecodeEqual() throws {
        let (fixture, _, reader) = try makeReader()
        defer { fixture.cleanUp() }

        let ab = inlineRegion([(index: 1, name: "a", value: [1, 2, 3, 4]), (index: 1, name: "b", value: [9])])
        let ba = inlineRegion([(index: 1, name: "b", value: [9]), (index: 1, name: "a", value: [1, 2, 3, 4])])
        // Raw bytes differ (entry order and value placement moved), so the
        // walker's fast-path signal diverges — but the decoded sets match,
        // so the full comparison must not report a change.
        #expect(ab != ba)
        #expect(reader.xattrs(inline: ab, block: 0) == reader.xattrs(inline: ba, block: 0))
    }

    @Test("a non-zero inline region without the magic header is an empty set")
    func garbageWithoutMagicIsEmptySet() throws {
        let (fixture, _, reader) = try makeReader()
        defer { fixture.cleanUp() }

        #expect(reader.xattrs(inline: Data(repeating: 0xAA, count: 96), block: 0) == [:])
    }

    @Test("system.data is representation, not a reported attribute")
    func systemDataIsSkipped() throws {
        let (fixture, _, reader) = try makeReader()
        defer { fixture.cleanUp() }

        let region = inlineRegion([(index: 7, name: "data", value: [1, 2, 3])])
        #expect(reader.xattrs(inline: region, block: 0) == [:])
    }

    @Test("a corrupt value offset makes the set unreadable")
    func corruptOffsetIsUnreadable() throws {
        let (fixture, _, reader) = try makeReader()
        defer { fixture.cleanUp() }

        var region = [UInt8](inlineRegion([(index: 1, name: "a", value: [1, 2, 3, 4])]))
        // The first entry starts at byte 4; its valueOffset field is at 6.
        region[6] = 0xFF
        region[7] = 0xFF
        #expect(reader.xattrs(inline: Data(region), block: 0) == nil)
    }

    @Test("the inode tuple converts to the same bytes reflection produces")
    func inlineRegionMatchesInodeTuple() throws {
        let fixture = Ext4TreeFixture(name: "xattr-reader")
        defer { fixture.cleanUp() }
        let device = try fixture.write(
            files: ["/tagged": "data", "/plain": "data"],
            xattrs: ["/tagged": ["user.k": Data("v".utf8)]])

        let ext4Reader = try EXT4.EXT4Reader(blockDevice: FilePath(device.path))
        let (_, tagged) = try ext4Reader.stat(FilePath("/tagged"))
        let (_, plain) = try ext4Reader.stat(FilePath("/plain"))

        // Cross-check with reflection — the same approach Apple's internal
        // tupleToArray uses — over the 96-element inlineXattrs tuple.
        let mirrored = Mirror(reflecting: tagged.inlineXattrs).children.compactMap { $0.value as? UInt8 }
        #expect(EXT4XattrReader.inlineRegion(of: tagged) == Data(mirrored))
        #expect(EXT4XattrReader.inlineRegion(of: tagged) != nil)
        #expect(EXT4XattrReader.inlineRegion(of: plain) == nil)
    }

    @Test("formatter-written xattrs round-trip through the decoder")
    func formatterXattrsRoundTrip() throws {
        let fixture = Ext4TreeFixture(name: "xattr-reader")
        defer { fixture.cleanUp() }
        // Inline storage (fits the 96-byte region) and block-backed storage
        // (256-byte value spills to an xattr block).
        let device = try fixture.write(
            files: ["/inline": "a", "/blockbacked": "b"],
            xattrs: [
                "/inline": ["user.small": Data("fits".utf8)],
                "/blockbacked": ["user.big": Data(repeating: 0x42, count: 256)],
            ])

        let ext4Reader = try EXT4.EXT4Reader(blockDevice: FilePath(device.path))
        let reader = EXT4XattrReader(blockDevice: FilePath(device.path), superBlock: ext4Reader.superBlock)
        let (_, inlineInode) = try ext4Reader.stat(FilePath("/inline"))
        let (_, blockInode) = try ext4Reader.stat(FilePath("/blockbacked"))

        #expect(
            reader.xattrs(
                inline: EXT4XattrReader.inlineRegion(of: inlineInode),
                block: UInt64(inlineInode.xattrBlockLow)
            )
                == ["user.small": Data("fits".utf8)])

        let big = reader.xattrs(
            inline: EXT4XattrReader.inlineRegion(of: blockInode),
            block: UInt64(blockInode.xattrBlockLow))
        #expect(big == ["user.big": Data(repeating: 0x42, count: 256)])
    }
}
