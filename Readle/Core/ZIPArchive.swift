import Foundation

/// Reads EPUB ZIP members in memory. No extraction directory or third-party dependencies.
struct ZIPArchive {
    private struct Entry {
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let offset: Int
    }
    private let data: Data
    private let entries: [String: Entry]

    init(data: Data) throws {
        guard data.count >= 22 else { throw BookError.invalid("EPUB 文件不完整。") }
        self.data = data
        var end: Int?
        for position in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if data.u32(position) == 0x06054b50, position + 22 + Int(data.u16(position + 20)) == data.count { end = position; break }
        }
        guard let end, data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              data.u16(end + 8) == data.u16(end + 10) else { throw BookError.invalid("不支持分卷或损坏的 EPUB 文件。") }
        let count = Int(data.u16(end + 10))
        var cursor = Int(data.u32(end + 16))
        guard count > 0, count < 20_000, cursor < end else { throw BookError.invalid("EPUB 目录无效或过大。") }
        var entries: [String: Entry] = [:]
        var totalSize = 0
        for _ in 0..<count {
            guard cursor + 46 <= end, data.u32(cursor) == 0x02014b50 else { throw BookError.invalid("EPUB 目录损坏。") }
            let flags = data.u16(cursor + 8)
            guard flags & 1 == 0 else { throw BookError.invalid("无法读取加密的 EPUB，请使用无 DRM 的电子书。") }
            let length = Int(data.u16(cursor + 28))
            let extra = Int(data.u16(cursor + 30))
            let comment = Int(data.u16(cursor + 32))
            guard cursor + 46 + length + extra + comment <= end,
                  let name = String(data: data.subdata(in: cursor + 46..<cursor + 46 + length), encoding: .utf8) else {
                throw BookError.invalid("EPUB 文件路径无法解析。")
            }
            let size = Int(data.u32(cursor + 24))
            totalSize += size
            guard size <= 32_000_000, totalSize <= 250_000_000 else { throw BookError.invalid("这本 EPUB 解压后过大，请使用较小的电子书。") }
            entries[name] = Entry(method: data.u16(cursor + 10), crc: data.u32(cursor + 16), compressedSize: Int(data.u32(cursor + 20)), size: size, offset: Int(data.u32(cursor + 42)))
            cursor += 46 + length + extra + comment
        }
        self.entries = entries
    }

    func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw BookError.invalid("EPUB 缺少文件：\(name)") }
        let offset = entry.offset
        guard offset + 30 <= data.count, data.u32(offset) == 0x04034b50 else { throw BookError.invalid("EPUB 内容损坏。") }
        let start = offset + 30 + Int(data.u16(offset + 26)) + Int(data.u16(offset + 28))
        guard start <= data.count, entry.compressedSize <= data.count - start else { throw BookError.invalid("EPUB 内容不完整。") }
        let compressed = data.subdata(in: start..<start + entry.compressedSize)
        let output: Data
        switch entry.method {
        case 0: output = compressed
        case 8:
            var result = Data(count: max(entry.size, 1))
            var stream = z_stream()
            let status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else { throw BookError.invalid("无法初始化 EPUB 解压。") }
            defer { inflateEnd(&stream) }
            let inflateStatus: Int32 = compressed.withUnsafeBytes { source in
                result.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard inflateStatus == Z_STREAM_END, stream.total_out == entry.size else { throw BookError.invalid("EPUB 解压失败，文件可能已损坏。") }
            output = result.prefix(entry.size)
        default: throw BookError.invalid("这本 EPUB 使用了不支持的压缩格式。")
        }
        let checksum = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)) }
        guard output.count == entry.size, UInt32(checksum) == entry.crc else { throw BookError.invalid("EPUB 文件校验失败。") }
        return output
    }
}

private extension Data {
    func u16(_ index: Int) -> UInt16 { UInt16(self[index]) | UInt16(self[index + 1]) << 8 }
    func u32(_ index: Int) -> UInt32 { UInt32(u16(index)) | UInt32(u16(index + 2)) << 16 }
}
