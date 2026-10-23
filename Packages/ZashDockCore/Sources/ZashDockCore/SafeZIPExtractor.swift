import Foundation
import CZlib

/// A small, deliberately restrictive ZIP reader for official web distributions. ZIP64, encryption,
/// special files, overlapping records and ambiguous paths are rejected before any file is written.
public struct SafeZIPExtractor: Sendable {
    public struct Limits: Sendable {
        public var maxArchiveBytes: Int64 = 128 * 1_024 * 1_024
        public var maxExpandedBytes: Int = 256 * 1_024 * 1_024
        public var maxFileBytes: Int = 64 * 1_024 * 1_024
        public var maxEntries: Int = 20_000
        public var maxCompressionRatio: Int = 250
        public static let standard = Limits()
        public init() {}
    }
    public let limits: Limits
    public init(limits: Limits = .standard) { self.limits = limits }

    /// Destination must be an empty, newly created private staging directory.
    public func extract(_ archive: URL, to destination: URL) throws {
        let values = try archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, Int64(size) <= limits.maxArchiveBytes else { throw invalid("ZIP 文件无效或过大。") }
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        let entries = try directory(bytes)
        let destinationValues = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard destinationValues.isDirectory == true, destinationValues.isSymbolicLink != true,
              try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else { throw invalid("解压目标必须是空的受管目录。") }
        let roots = Set(entries.filter { !$0.directory }.map(\.path))
        let prefix: String
        if roots.contains("index.html") { prefix = "" }
        else if roots.contains("dist/index.html"), entries.allSatisfy({ $0.path == "dist/" || $0.path.hasPrefix("dist/") }) { prefix = "dist/" }
        else { throw invalid("ZIP 缺少根目录 index.html，或含有非网页发行目录。") }
        guard entries.contains(where: { !$0.directory && $0.path.hasPrefix(prefix) && $0.path.hasSuffix(".js") }) else {
            throw invalid("ZIP 缺少 JavaScript 网页资源。")
        }
        for entry in entries {
            try Task.checkCancellation()
            let relative = String(entry.path.dropFirst(prefix.count))
            if relative.isEmpty { continue }
            let target = destination.appendingPathComponent(relative, isDirectory: entry.directory)
            guard target.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else { throw invalid("ZIP 路径越界。") }
            if entry.directory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let compressed = bytes.subdata(in: entry.dataRange)
                let expanded = try decompress(compressed, entry: entry)
                let checksum = expanded.withUnsafeBytes { buffer in
                    crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(expanded.count))
                }
                guard UInt32(checksum) == entry.crc else { throw invalid("ZIP 文件 CRC 校验失败。") }
                try AtomicFile.write(expanded, to: target)
            }
        }
        let index = try Data(contentsOf: destination.appendingPathComponent("index.html"))
        guard !index.isEmpty, index.count < 4_194_304,
              let html = String(data: index, encoding: .utf8), html.lowercased().contains("<html"), html.lowercased().contains("<script") else {
            throw invalid("index.html 不是有效的应用入口。")
        }
    }

    private struct Entry {
        let path: String; let directory: Bool; let method: UInt16; let crc: UInt32
        let expandedSize: Int; let dataRange: Range<Int>; let recordRange: Range<Int>
    }
    private func directory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw invalid("ZIP 不完整。") }
        let first = max(0, data.count - 65_557)
        guard let end = findEnd(data, lowerBound: first) else { throw invalid("ZIP 缺少中央目录。") }
        // The exact footer check below also prevents interpreting signatures inside the ZIP comment.
        guard end + 22 + Int(try data.u16(end + 20)) == data.count,
              try data.u16(end + 4) == 0, try data.u16(end + 6) == 0,
              try data.u16(end + 8) == data.u16(end + 10) else { throw invalid("不支持分卷或无效 ZIP。") }
        let count = Int(try data.u16(end + 10))
        let centralSize = Int(try data.u32(end + 12)), centralOffset = Int(try data.u32(end + 16))
        guard count > 0, count <= limits.maxEntries, centralOffset + centralSize == end,
              centralOffset >= 0 else { throw invalid("ZIP 中央目录大小或条目数量无效。") }
        var cursor = centralOffset, total = 0, entries: [Entry] = [], names = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            guard try data.u32(cursor) == 0x02014b50 else { throw invalid("ZIP 中央记录无效。") }
            let flags = try data.u16(cursor + 8), method = try data.u16(cursor + 10)
            let crc = try data.u32(cursor + 16), compressed = Int(try data.u32(cursor + 20)), expanded = Int(try data.u32(cursor + 24))
            let nameLength = Int(try data.u16(cursor + 28)), extraLength = Int(try data.u16(cursor + 30)), commentLength = Int(try data.u16(cursor + 32))
            let external = try data.u32(cursor + 38), local = Int(try data.u32(cursor + 42))
            guard nameLength > 0, nameLength <= 1_024, cursor + 46 + nameLength + extraLength + commentLength <= end,
                  try data.u16(cursor + 34) == 0,
                  flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  expanded <= limits.maxFileBytes, compressed <= Int(limits.maxArchiveBytes),
                  compressed > 0 || expanded == 0,
                  expanded <= max(1, compressed) * limits.maxCompressionRatio else { throw invalid("ZIP 压缩类型、大小或压缩比不安全。") }
            try validateExtra(data, range: (cursor + 46 + nameLength)..<(cursor + 46 + nameLength + extraLength))
            let nameBytes = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let path = String(data: nameBytes, encoding: .utf8) else { throw invalid("ZIP 文件名不是 UTF-8。") }
            let isDirectory = path.hasSuffix("/")
            try validatePath(path, directory: isDirectory)
            let mode = external >> 16, type = mode & 0xf000
            guard (type == 0 || type == 0x8000 || type == 0x4000),
                  (type != 0x4000 || isDirectory), (!isDirectory || type != 0x8000),
                  (external & 0x10 == 0 || isDirectory), !isDirectory || (expanded == 0 && compressed == 0) else {
                throw invalid("ZIP 含符号链接、特殊文件或伪装目录。")
            }
            let normalized = normalize(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            guard names.insert(normalized).inserted else { throw invalid("ZIP 含重复或大小写冲突路径。") }
            guard try data.u32(local) == 0x04034b50,
                  try data.u16(local + 6) == flags, try data.u16(local + 8) == method,
                  Int(try data.u16(local + 26)) == nameLength else { throw invalid("ZIP 本地头与中央目录不匹配。") }
            let localExtra = Int(try data.u16(local + 28))
            let start = local + 30 + nameLength + localExtra, finish = start + compressed
            guard local >= 0, start <= centralOffset, finish <= centralOffset,
                  data.subdata(in: (local + 30)..<(local + 30 + nameLength)) == nameBytes else { throw invalid("ZIP 本地文件路径或数据范围无效。") }
            try validateExtra(data, range: (local + 30 + nameLength)..<start)
            var recordEnd = finish
            if flags & 8 == 0 {
                guard try data.u32(local + 14) == crc,
                      Int(try data.u32(local + 18)) == compressed, Int(try data.u32(local + 22)) == expanded else { throw invalid("ZIP 本地大小或 CRC 不匹配。") }
            } else {
                for (offset, expected) in [(14, crc), (18, UInt32(compressed)), (22, UInt32(expanded))] {
                    let value = try data.u32(local + offset)
                    guard value == 0 || value == expected else { throw invalid("ZIP 数据描述符冲突。") }
                }
                let descriptor = (try data.u32(finish)) == 0x08074b50 ? finish + 4 : finish
                guard try data.u32(descriptor) == crc,
                      Int(try data.u32(descriptor + 4)) == compressed,
                      Int(try data.u32(descriptor + 8)) == expanded else { throw invalid("ZIP 数据描述符不匹配。") }
                recordEnd = descriptor + 12
            }
            guard recordEnd <= centralOffset else { throw invalid("ZIP 数据覆盖中央目录。") }
            total += expanded
            guard total <= limits.maxExpandedBytes else { throw invalid("ZIP 解压后总体积超过限制。") }
            entries.append(.init(path: path, directory: isDirectory, method: method, crc: crc,
                                 expandedSize: expanded, dataRange: start..<finish, recordRange: local..<recordEnd))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == end else { throw invalid("ZIP 中央目录长度不匹配。") }
        let ranges = entries.map(\.recordRange).sorted { $0.lowerBound < $1.lowerBound }
        var position = 0
        for range in ranges {
            guard range.lowerBound == position else { throw invalid("ZIP 本地记录重叠或含隐藏记录。") }
            position = range.upperBound
        }
        guard position == centralOffset else { throw invalid("ZIP 本地记录尾部不完整。") }
        let files = Set(entries.filter { !$0.directory }.map { normalize($0.path) })
        for entry in entries {
            let components = entry.path.split(separator: "/")
            for length in 1..<components.count {
                guard !files.contains(normalize(components.prefix(length).joined(separator: "/"))) else {
                    throw invalid("ZIP 文件和父目录路径冲突。")
                }
            }
        }
        return entries
    }
    private func findEnd(_ data: Data, lowerBound: Int) -> Int? {
        stride(from: data.count - 22, through: lowerBound, by: -1).first {
            (try? data.u32($0)) == 0x06054b50 && (try? data.u16($0 + 20)).map { Int($0) } == data.count - $0 - 22
        }
    }
    private func normalize(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
    private func validateExtra(_ data: Data, range: Range<Int>) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor + 4 <= range.upperBound else { throw invalid("ZIP 扩展字段损坏。") }
            let kind = try data.u16(cursor), size = Int(try data.u16(cursor + 2))
            guard kind != 0x0001, cursor + 4 + size <= range.upperBound else { throw invalid("不支持 ZIP64 或无效扩展字段。") }
            cursor += 4 + size
        }
    }
    private func validatePath(_ path: String, directory: Bool) throws {
        let trimmed = directory ? String(path.dropLast()) : path
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("%"),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !components.isEmpty, components.count <= 32,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
              !trimmed.isEmpty else { throw invalid("ZIP 含不安全文件路径。") }
    }
    private func decompress(_ compressed: Data, entry: Entry) throws -> Data {
        if entry.method == 0 {
            guard compressed.count == entry.expandedSize else { throw invalid("ZIP 未压缩文件大小不匹配。") }
            return compressed
        }
        var result = Data(count: max(1, entry.expandedSize))
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid("无法初始化 ZIP 解压器。") }
        defer { inflateEnd(&stream) }
        let status: Int32 = compressed.withUnsafeBytes { input in
            result.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == entry.expandedSize, stream.total_in == compressed.count else { throw invalid("ZIP 解压失败或展开大小不匹配。") }
        result.count = entry.expandedSize
        return result
    }
    private func invalid(_ message: String) -> ZashDockError { .verification(message) }
}

private extension Data {
    func u16(_ index: Int) throws -> UInt16 {
        guard index >= 0, index <= count - 2 else { throw ZashDockError.verification("ZIP 记录越界。") }
        return UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }
    func u32(_ index: Int) throws -> UInt32 {
        guard index >= 0, index <= count - 4 else { throw ZashDockError.verification("ZIP 记录越界。") }
        return UInt32(self[index]) | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
    }
}
