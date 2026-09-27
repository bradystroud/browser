import Compression
import Darwin
import Foundation

public enum ZipArchiveError: Error, Equatable, LocalizedError {
    case notAZip
    case unsafeEntry(String)
    case symbolicLink(String)
    case duplicateEntry(String)
    case tooManyEntries
    case tooLarge
    case unsupported(String)
    case corrupt(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "The extension's archive is damaged."
        case .unsafeEntry(let name): return "The extension's archive has a file outside its own folder (\(name))."
        case .symbolicLink(let name): return "The extension's archive contains a symbolic link (\(name))."
        case .duplicateEntry(let name): return "The extension's archive names a file twice (\(name))."
        case .tooManyEntries: return "The extension's archive has too many files."
        case .tooLarge: return "The extension's archive is too large once unpacked."
        case .unsupported(let name): return "The extension's archive stores \(name) in a way this browser can't read."
        case .corrupt(let name): return "The extension's archive is damaged (\(name))."
        case .writeFailed(let name): return "The extension couldn't be written to disk (\(name))."
        }
    }
}

/// A zip read and extracted entirely in-process, from one parse of its
/// central directory. Nothing else reads the archive, so what is checked is
/// exactly what is written.
///
/// Refused whole: more than one end-of-central-directory record, or bytes
/// after its comment (a decoy record hidden in a comment could otherwise
/// point a reader at a different directory); a local header whose name is
/// not its central-directory name; any entry whose Unix mode is a symbolic
/// link or other non-regular file, whatever system it says made it; names
/// that are absolute, climb out with `..`, or repeat another name ignoring
/// case (the disk is case-insensitive); encryption; methods other than
/// stored and deflate; a CRC or size that does not match. Files are then
/// created only by this code, directory by directory, with
/// `O_CREAT | O_EXCL | O_NOFOLLOW`, inside a folder that did not exist
/// before -- so no write can follow a link out of it.
public enum ZipArchive {
    public struct Entry: Equatable {
        public let name: String
        public let isDirectory: Bool
        let method: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    public static let maximumEntries = 20_000
    public static let maximumUnpackedBytes = 1024 * 1024 * 1024

    private static let eocdSignature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]

    public static func entries(in zip: Data) throws -> [Entry] {
        let b = [UInt8](zip)
        guard b.count >= 22 else { throw ZipArchiveError.notAZip }
        let floor = max(0, b.count - 22 - 0xffff)
        var found: [Int] = []
        var at = b.count - 22
        while at >= floor {
            if b[at] == 0x50, b[at + 1] == 0x4b, b[at + 2] == 0x05, b[at + 3] == 0x06 { found.append(at) }
            at -= 1
        }
        guard found.count == 1, let eocd = found.first else { throw ZipArchiveError.notAZip }
        let commentLength = Int(le16(b, eocd + 20))
        guard eocd + 22 + commentLength == b.count else { throw ZipArchiveError.notAZip }
        guard le16(b, eocd + 4) == 0, le16(b, eocd + 6) == 0 else { throw ZipArchiveError.notAZip }
        let count = Int(le16(b, eocd + 10))
        guard Int(le16(b, eocd + 8)) == count else { throw ZipArchiveError.notAZip }
        let size = Int(le32(b, eocd + 12))
        let offset = Int(le32(b, eocd + 16))
        // 0xffff / 0xffffffff mark Zip64, which no extension needs.
        guard count != 0xffff, offset != 0xffff_ffff, offset <= eocd, size <= eocd - offset else {
            throw ZipArchiveError.notAZip
        }
        guard count <= maximumEntries else { throw ZipArchiveError.tooManyEntries }

        var entries: [Entry] = []
        var seen = Set<String>()
        var total = 0
        var p = offset
        for _ in 0..<count {
            guard p + 46 <= offset + size, le32(b, p) == 0x0201_4b50 else { throw ZipArchiveError.notAZip }
            let flags = le16(b, p + 8)
            let method = le16(b, p + 10)
            let crc = le32(b, p + 16)
            let compressed = Int(le32(b, p + 20))
            let uncompressed = Int(le32(b, p + 24))
            let nameLength = Int(le16(b, p + 28))
            let extraLength = Int(le16(b, p + 30))
            let commentLen = Int(le16(b, p + 32))
            let external = le32(b, p + 38)
            let local = Int(le32(b, p + 42))
            let nameStart = p + 46
            guard nameStart + nameLength <= offset + size else { throw ZipArchiveError.notAZip }
            guard let name = String(bytes: b[nameStart..<(nameStart + nameLength)], encoding: .utf8) else {
                throw ZipArchiveError.corrupt("an entry's name")
            }
            p = nameStart + nameLength + extraLength + commentLen

            guard isSafeRelativePath(name) else { throw ZipArchiveError.unsafeEntry(name) }
            // Whatever "made by" says, a Unix file type in the high half of
            // the external attributes is honoured by some extractors; only
            // a regular file or a directory is accepted.
            let mode = external >> 16
            let type = mode & 0o170000
            if type == 0o120000 { throw ZipArchiveError.symbolicLink(name) }
            let isDirectory = name.hasSuffix("/")
            guard type == 0 || type == 0o100000 || (type == 0o040000 && isDirectory) else {
                throw ZipArchiveError.unsafeEntry(name)
            }
            guard flags & 0x0001 == 0 else { throw ZipArchiveError.unsupported(name) }
            guard method == 0 || method == 8 else { throw ZipArchiveError.unsupported(name) }
            guard compressed != 0xffff_ffff, uncompressed != 0xffff_ffff, local < offset else {
                throw ZipArchiveError.unsupported(name)
            }
            let key = (isDirectory ? String(name.dropLast()) : name).lowercased()
            guard seen.insert(key).inserted else { throw ZipArchiveError.duplicateEntry(name) }
            total += uncompressed
            guard total <= maximumUnpackedBytes else { throw ZipArchiveError.tooLarge }
            entries.append(Entry(name: name, isDirectory: isDirectory, method: method, crc32: crc,
                                 compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: local))
        }
        // A file and a directory can't share a path either ("a" and "a/b").
        let files = Set(entries.filter { !$0.isDirectory }.map { $0.name.lowercased() })
        for entry in entries {
            let parts = entry.name.lowercased().split(separator: "/")
            for depth in 1..<max(parts.count, 1) where files.contains(parts[0..<depth].joined(separator: "/")) {
                throw ZipArchiveError.duplicateEntry(entry.name)
            }
        }
        return entries
    }

    /// The bytes of `entry`, read through its local header -- whose name must
    /// be the central directory's -- and checked against its size and CRC.
    public static func contents(of entry: Entry, in zip: Data) throws -> Data {
        try zip.withUnsafeBytes { raw -> Data in
            let b = raw.bindMemory(to: UInt8.self)
            let p = entry.localHeaderOffset
            guard p + 30 <= b.count, le32(b, p) == 0x0403_4b50 else { throw ZipArchiveError.corrupt(entry.name) }
            let nameLength = Int(le16(b, p + 26))
            let extraLength = Int(le16(b, p + 28))
            let nameStart = p + 30
            guard nameStart + nameLength <= b.count,
                  String(bytes: b[nameStart..<(nameStart + nameLength)], encoding: .utf8) == entry.name
            else { throw ZipArchiveError.corrupt(entry.name) }
            let start = nameStart + nameLength + extraLength
            guard start <= b.count, entry.compressedSize <= b.count - start else { throw ZipArchiveError.corrupt(entry.name) }
            let stored = Data(b[start..<(start + entry.compressedSize)])
            let out: Data
            if entry.method == 0 {
                out = stored
            } else {
                out = try inflate(stored, expectedSize: entry.uncompressedSize, name: entry.name)
            }
            guard out.count == entry.uncompressedSize, crc32(out) == entry.crc32 else {
                throw ZipArchiveError.corrupt(entry.name)
            }
            return out
        }
    }

    /// Extracts every entry into `folder`, which must not exist yet.
    public static func extract(_ zip: Data, into folder: URL) throws {
        let list = try entries(in: zip)
        let root = folder.path
        guard mkdir(root, 0o755) == 0 else { throw ZipArchiveError.writeFailed(folder.lastPathComponent) }
        for entry in list {
            let parts = entry.name.split(separator: "/").map(String.init)
            let directories = entry.isDirectory ? parts : Array(parts.dropLast())
            var path = root
            for part in directories {
                path += "/" + part
                if mkdir(path, 0o755) != 0 {
                    var info = stat()
                    guard errno == EEXIST, lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                        throw ZipArchiveError.writeFailed(entry.name)
                    }
                }
            }
            guard !entry.isDirectory, let file = parts.last else { continue }
            let data = try contents(of: entry, in: zip)
            let target = path + "/" + file
            let fd = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            guard fd >= 0 else { throw ZipArchiveError.writeFailed(entry.name) }
            defer { close(fd) }
            let written = data.withUnsafeBytes { buffer -> Int in
                var done = 0
                while done < buffer.count {
                    let n = write(fd, buffer.baseAddress! + done, buffer.count - done)
                    if n <= 0 { return -1 }
                    done += n
                }
                return done
            }
            guard written == data.count else { throw ZipArchiveError.writeFailed(entry.name) }
        }
    }

    public static func isSafeRelativePath(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        let body = name.hasSuffix("/") ? parts.dropLast() : parts[...]
        return !body.isEmpty && !body.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    // MARK: - Pieces

    private static func inflate(_ data: Data, expectedSize: Int, name: String) throws -> Data {
        if expectedSize == 0 { return Data() }
        var out = Data(count: expectedSize)
        let produced = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard produced == expectedSize else { throw ZipArchiveError.corrupt(name) }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }

    private static func le16<C: RandomAccessCollection>(_ b: C, _ at: Int) -> UInt16 where C.Element == UInt8, C.Index == Int {
        UInt16(b[at]) | UInt16(b[at + 1]) << 8
    }

    private static func le32<C: RandomAccessCollection>(_ b: C, _ at: Int) -> UInt32 where C.Element == UInt8, C.Index == Int {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
}
