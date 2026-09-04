import Foundation
import Compression

/// 只够用来读 EPUB 的最小 ZIP 解析器。
///
/// 不引第三方库：解压用系统 Compression 框架的 COMPRESSION_ZLIB，
/// 它接收的正是 ZIP 里那种裸 deflate 流（没有 zlib 头）。
/// 只支持 stored(0) 和 deflate(8) 两种方式，EPUB 里不会出现别的。
enum MiniZip {

    struct Entry {
        var path: String
        var compressionMethod: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    enum ZipError: LocalizedError {
        case notZip
        case corrupted(String)

        var errorDescription: String? {
            switch self {
            case .notZip:            return "不是有效的 EPUB（ZIP）文件"
            case .corrupted(let m):  return "EPUB 文件损坏：\(m)"
            }
        }
    }

    // MARK: 目录

    static func entries(in data: Data) throws -> [String: Entry] {
        guard let eocd = findEndOfCentralDirectory(data) else { throw ZipError.notZip }

        let count = Int(read16(data, eocd + 10))
        var offset = Int(read32(data, eocd + 16))
        var result: [String: Entry] = [:]

        for _ in 0..<count {
            guard offset + 46 <= data.count, read32(data, offset) == 0x02014B50 else {
                throw ZipError.corrupted("中央目录项签名不对")
            }
            let method = read16(data, offset + 10)
            let compressed = Int(read32(data, offset + 20))
            let uncompressed = Int(read32(data, offset + 24))
            let nameLength = Int(read16(data, offset + 28))
            let extraLength = Int(read16(data, offset + 30))
            let commentLength = Int(read16(data, offset + 32))
            let localOffset = Int(read32(data, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { throw ZipError.corrupted("文件名越界") }
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            result[normalize(name)] = Entry(path: name,
                                            compressionMethod: method,
                                            compressedSize: compressed,
                                            uncompressedSize: uncompressed,
                                            localHeaderOffset: localOffset)

            offset = nameStart + nameLength + extraLength + commentLength
        }
        return result
    }

    // MARK: 取单个文件

    static func extract(_ entry: Entry, from data: Data) throws -> Data {
        let head = entry.localHeaderOffset
        guard head + 30 <= data.count, read32(data, head) == 0x04034B50 else {
            throw ZipError.corrupted("本地文件头签名不对")
        }
        // 本地头里的名字/扩展字段长度可能和中央目录不同，必须用本地头的
        let nameLength = Int(read16(data, head + 26))
        let extraLength = Int(read16(data, head + 28))
        let start = head + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { throw ZipError.corrupted("数据越界") }

        let payload = data[start..<end]

        switch entry.compressionMethod {
        case 0:
            return Data(payload)
        case 8:
            return try inflate(Data(payload), expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.corrupted("不支持的压缩方式 \(entry.compressionMethod)")
        }
    }

    /// 裸 deflate 解压
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard !data.isEmpty else { return Data() }
        // 中央目录里的原始大小可能为 0（用了 data descriptor），给个保守估计
        let capacity = expectedSize > 0 ? expectedSize : max(data.count * 8, 64 * 1024)

        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { outBuffer in
            data.withUnsafeBytes { inBuffer in
                guard let dst = outBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let src = inBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, capacity, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw ZipError.corrupted("解压失败") }
        return output.prefix(written)
    }

    // MARK: 字节读取

    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        // EOCD 在文件末尾，注释最长 65535，所以最多往前找这么多
        let minSize = 22
        guard data.count >= minSize else { return nil }
        let lowest = max(0, data.count - minSize - 0xFFFF)
        var i = data.count - minSize
        while i >= lowest {
            if read32(data, i) == 0x06054B50 { return i }
            i -= 1
        }
        return nil
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// ZIP 里的路径可能带 ./ 或反斜杠，统一一下方便查表
    static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}
