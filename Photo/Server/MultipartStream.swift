import Foundation

/// 流式 multipart 解析：请求体在磁盘上，每一段的正文也直接写成文件，不进内存。
///
/// 视频动辄几百 MB，整份读进内存再切分会被系统直接杀掉，所以正文全程不落内存，
/// 内存里只留一个和分隔符差不多长的滑动窗口。
enum MultipartStream {

    struct Part {
        var name = ""
        var fileName: String?
        var contentType: String?
        /// 落在临时目录里的正文文件
        var fileURL: URL
        var byteCount = 0
    }

    private enum State {
        case seek       // 找下一个分隔符
        case after      // 刚吃掉分隔符，看后面是 -- 还是 CRLF
        case headers    // 读这一段的头
        case body       // 写这一段的正文
    }

    /// - Parameters:
    ///   - fileURL: 请求体文件
    ///   - directory: 各段正文写到哪儿；调用方负责用完删掉
    static func parse(fileURL: URL, boundary: String, into directory: URL) -> [Part] {
        guard let reader = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? reader.close() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let delim = Array("\r\n--\(boundary)".utf8)
        let crlf2 = Array("\r\n\r\n".utf8)
        // 正文里可能正好卡着分隔符的前半截，所以窗口尾部要留够 delim.count - 1 字节
        let keep = max(0, delim.count - 1)
        let chunkSize = 256 * 1024

        // 前置一个 CRLF，让第一个分隔符也带上前缀，后面就只有一种匹配形式
        var window = Array("\r\n".utf8)
        var parts: [Part] = []
        var state = State.seek
        var eof = false

        var headerBytes: [UInt8] = []
        var writer: FileHandle?
        var partURL: URL?
        var written = 0

        func openPart() {
            let url = directory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            writer = try? FileHandle(forWritingTo: url)
            partURL = url
            written = 0
        }

        func write(_ bytes: ArraySlice<UInt8>) {
            guard !bytes.isEmpty else { return }
            try? writer?.write(contentsOf: Data(bytes))
            written += bytes.count
        }

        func closePart() {
            try? writer?.close()
            writer = nil
            guard let url = partURL else { return }
            var part = Part(fileURL: url, byteCount: written)
            applyHeaders(headerBytes, to: &part)
            parts.append(part)
            partURL = nil
        }

        loop: while true {
            if !eof, window.count < delim.count + 4096 {
                if let data = try? reader.read(upToCount: chunkSize), !data.isEmpty {
                    window.append(contentsOf: data)
                } else {
                    eof = true
                }
            }

            switch state {
            case .seek:
                if let i = find(delim, in: window, from: 0) {
                    window.removeFirst(i + delim.count)
                    state = .after
                } else {
                    if eof { break loop }
                    // 分隔符之前的都是前导垃圾，只留可能咬住分隔符的那一小截
                    if window.count > keep { window.removeFirst(window.count - keep) }
                }

            case .after:
                if window.count < 2 {
                    if eof { break loop }
                    continue
                }
                if window[0] == 0x2D && window[1] == 0x2D { break loop }        // "--" 收尾
                if window[0] == 0x0D && window[1] == 0x0A {                      // CRLF，新的一段
                    window.removeFirst(2)
                    state = .headers
                } else {
                    state = .seek
                }

            case .headers:
                if let i = find(crlf2, in: window, from: 0) {
                    headerBytes = Array(window[0..<i])
                    window.removeFirst(i + crlf2.count)
                    openPart()
                    state = .body
                } else {
                    if eof { break loop }
                }

            case .body:
                if let i = find(delim, in: window, from: 0) {
                    write(window[0..<i])
                    window.removeFirst(i + delim.count)
                    closePart()
                    state = .after
                } else {
                    if eof {
                        write(window[0...])
                        window.removeAll()
                        closePart()
                        break loop
                    }
                    // 尾部这一小截先别写，它可能是分隔符的前半截
                    if window.count > keep {
                        let cut = window.count - keep
                        write(window[0..<cut])
                        window.removeFirst(cut)
                    }
                }
            }
        }

        // body 状态下走到 EOF 却没等到收尾分隔符：这一段是残的，扔掉
        if let url = partURL {
            try? writer?.close()
            try? FileManager.default.removeItem(at: url)
        }
        return parts
    }

    // MARK: 私有

    private static func applyHeaders(_ bytes: [UInt8], to part: inout Part) {
        let text = String(decoding: bytes, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            if key == "content-type" {
                part.contentType = value
            } else if key == "content-disposition" {
                for attr in value.split(separator: ";") {
                    let t = attr.trimmingCharacters(in: .whitespaces)
                    if t.lowercased().hasPrefix("name=") {
                        part.name = unquote(String(t.dropFirst(5)))
                    } else if t.lowercased().hasPrefix("filename=") {
                        part.fileName = unquote(String(t.dropFirst(9)))
                    }
                }
            }
        }
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") { t.removeFirst() }
        if t.hasSuffix("\"") { t.removeLast() }
        return t
    }

    /// 先比首字节再整体比对。窗口只有几百 KB，够用了。
    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        let first = needle[0]
        let last = hay.count - needle.count
        guard from <= last else { return nil }
        var i = from
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}
