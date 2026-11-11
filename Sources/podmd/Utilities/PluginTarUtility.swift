// SPDX-License-Identifier: Apache-2.0
import ContainerizationArchive
import Crypto
import Foundation

/// The result of splitting a plugin-create tarball.
struct PluginTarSplit: Equatable {
    /// The raw bytes of the tarball's `config.json` entry.
    let configJSON: Data
    /// `sha256:<hex>` — the digest of the rewritten, gzip-compressed rootfs
    /// tar, moby's `rootFSBlob.Digest()`.
    let rootfsDigest: String
}

enum PluginTarUtilityError: Error, Equatable {
    /// moby's splitConfigRootFSFromTar failure for a tarball with no
    /// `rootfs/` tree: "no rootfs found".
    case noRootFS
    /// moby's CreateFromContext failure when no config.json was seen:
    /// "config not found".
    case noConfig
    /// The tar could not be read.
    case archiveReadFailed(String)
    /// The rewritten rootfs tar could not be written.
    case archiveWriteFailed(String)
}

/// moby's `splitConfigRootFSFromTar` (`plugin/backend_linux.go`) over an
/// in-memory tarball: walk the archive, pull out the top-level `config.json`
/// entry, and re-emit every `rootfs/…` entry as a NEW tar with the
/// `rootfs/` prefix stripped (hardlink targets under `rootfs/` are rewritten
/// too, case-insensitively, exactly like moby).
///
/// The digest: moby pipes the rewritten tar through Go's gzip into its blob
/// store and reports that blob's digest as `rootfs.diff_ids[0]`. podm
/// re-emits the same entry set through libarchive (pax + gzip) and digests
/// THAT stream — the content is the same entry set, but tar/gzip framing is
/// implementation-defined, so the digest is content-defined rather than
/// byte-identical to dockerd's (documented deviation; podm stores no payload
/// half, the digest is metadata about the ingest).
enum PluginTarUtility {
    /// moby `plugin/manager.go`: the tarball's config entry name and the
    /// rootfs directory prefix.
    static let configFileName = "config.json"
    static let rootFSFileName = "rootfs"

    /// Splits `tarData`, using `workDirectory` for the on-disk staging files
    /// (the input tar and the rewritten rootfs tar). The caller owns the
    /// directory's lifetime; nothing is left behind inside it on success.
    static func split(tarData: Data, workDirectory: URL) throws -> PluginTarSplit {
        let fm = FileManager.default
        let inputURL = workDirectory.appendingPathComponent("plugin-context.tar")
        guard fm.createFile(atPath: inputURL.path, contents: tarData, attributes: [.posixPermissions: 0o600])
        else {
            throw PluginTarUtilityError.archiveReadFailed("could not stage the uploaded tarball")
        }
        defer { try? fm.removeItem(at: inputURL) }

        let reader: ArchiveReader
        do {
            reader = try ArchiveReader(file: inputURL)
        } catch {
            throw PluginTarUtilityError.archiveReadFailed(error.localizedDescription)
        }

        let rootfsURL = workDirectory.appendingPathComponent("plugin-rootfs.tar.gz")
        let writer: ArchiveWriter
        do {
            writer = try ArchiveWriter(format: .pax, filter: .gzip, file: rootfsURL)
        } catch {
            throw PluginTarUtilityError.archiveWriteFailed(error.localizedDescription)
        }

        var configJSON: Data?
        var hasRootFS = false
        do {
            var iterator = reader.makeStreamingIterator()
            while let (entry, entryReader) = iterator.next() {
                // libarchive reports read failures as entries with no path;
                // the bridge has no separate error signal (see
                // ArchiveReader.StreamingIterator).
                guard let rawPath = entry.path else {
                    throw PluginTarUtilityError.archiveReadFailed("could not read the next tar entry")
                }
                let name = cleaned(rawPath)
                if name == configFileName {
                    // moby keeps the LAST config.json it sees (*config is
                    // reassigned per hit).
                    configJSON = try readAll(of: entryReader)
                    continue
                }
                let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard parts.first == rootFSFileName else {
                    try discard(entryReader)
                    continue
                }
                hasRootFS = true
                // Strip the rootfs/ prefix: path.Join(parts[1:]) — an empty
                // remainder (the rootfs dir entry itself) becomes ".".
                let remainder = parts.dropFirst().joined(separator: "/")
                entry.path = remainder.isEmpty ? "." : remainder
                // moby: hardlink targets that point back under rootfs/ are
                // rewritten too (case-insensitive prefix check, like moby's
                // strings.ToLower comparison).
                if let link = entry.hardlink, link.lowercased().hasPrefix("\(rootFSFileName)/") {
                    entry.hardlink = String(link.dropFirst(rootFSFileName.count + 1))
                }
                do {
                    let transaction = writer.makeTransactionWriter()
                    try transaction.writeHeader(entry: entry)
                    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                    while true {
                        let read = entryReader.read(&buffer, maxLength: buffer.count)
                        guard read > 0 else {
                            if read < 0 {
                                throw PluginTarUtilityError.archiveReadFailed("could not read entry data")
                            }
                            break
                        }
                        try buffer.withUnsafeBytes { raw in
                            let chunk = UnsafeRawBufferPointer(
                                rebasing: raw.prefix(read))
                            try transaction.writeChunk(data: chunk)
                        }
                    }
                    try transaction.finish()
                } catch let error as PluginTarUtilityError {
                    throw error
                } catch {
                    throw PluginTarUtilityError.archiveWriteFailed(error.localizedDescription)
                }
            }
        } catch let error as PluginTarUtilityError {
            try? writer.finishEncoding()
            try? fm.removeItem(at: rootfsURL)
            throw error
        } catch {
            try? writer.finishEncoding()
            try? fm.removeItem(at: rootfsURL)
            throw PluginTarUtilityError.archiveReadFailed(error.localizedDescription)
        }

        do {
            try writer.finishEncoding()
        } catch {
            try? fm.removeItem(at: rootfsURL)
            throw PluginTarUtilityError.archiveWriteFailed(error.localizedDescription)
        }

        guard hasRootFS else {
            try? fm.removeItem(at: rootfsURL)
            throw PluginTarUtilityError.noRootFS
        }
        guard let configJSON else {
            try? fm.removeItem(at: rootfsURL)
            throw PluginTarUtilityError.noConfig
        }

        let digest: String
        do {
            digest = try sha256Hex(of: rootfsURL)
        } catch {
            throw PluginTarUtilityError.archiveReadFailed("could not digest the rewritten rootfs tar")
        }
        try? fm.removeItem(at: rootfsURL)
        return PluginTarSplit(configJSON: configJSON, rootfsDigest: digest)
    }

    /// moby's entry-name normalization (`splitConfigRootFSFromTar`):
    /// `path.Clean(hdr.Name)`, then the leading "/" of an absolute result
    /// is stripped (Go's `name[1:]`). Go's Clean PRESERVES unresolved `..`
    /// at the front of a RELATIVE name (`path.Clean("../config.json")` is
    /// `"../config.json"`) and only clamps them for ABSOLUTE names
    /// (`path.Clean("/../config.json")` is `"/config.json"`, then the strip
    /// gives `"config.json"`). A preserved leading `..` can never equal
    /// `config.json` nor carry the `rootfs/` prefix, so moby simply SKIPS
    /// such entries — it never discards the parents, which would turn a
    /// `../config.json` into a valid config entry.
    static func cleaned(_ raw: String) -> String {
        let isAbsolute = raw.hasPrefix("/")
        var components: [String] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: false) {
            switch part {
            case "", ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if isAbsolute {
                    // ".." above the root of an absolute path clamps to it.
                    continue
                } else {
                    // A relative name keeps its unresolved leading parents.
                    components.append("..")
                }
            default:
                components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }
    /// Streaming SHA-256 over a staged file, in bounded chunks: the whole
    /// compressed rootfs is never held in memory on top of the uploaded tar
    /// (concurrent creates would multiply that whole-file allocation). The
    /// digest is identical to hashing the file in one `Data(contentsOf:)`
    /// read — only the peak memory differs.
    static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads an entry's full data through its streaming reader.
    private static func readAll(of reader: ArchiveEntryReader) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let read = reader.read(&buffer, maxLength: buffer.count)
            guard read > 0 else {
                if read < 0 {
                    throw PluginTarUtilityError.archiveReadFailed("could not read config.json data")
                }
                break
            }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }

    /// Drains an entry the split does not keep — libarchive requires the
    /// data to be consumed before the next header is read.
    private static func discard(_ reader: ArchiveEntryReader) throws {
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let read = reader.read(&buffer, maxLength: buffer.count)
            guard read > 0 else {
                if read < 0 {
                    throw PluginTarUtilityError.archiveReadFailed("could not skip a tar entry")
                }
                break
            }
        }
    }
}
