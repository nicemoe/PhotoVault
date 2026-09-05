import Foundation

/// 磁盘路径。放在数据仓库之外，服务端线程也能安全读取。
enum Paths {
    static let documents: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    /// 「导入」文件夹。Info.plist 开了文件共享，电脑用访达、手机用「文件」
    /// 都能直接把书拖进这里，App 回到前台就收走。
    ///
    /// 不直接扫 Documents 根目录：那里还躺着 books.json 和每本书的正文，
    /// 混在一起既容易误删，也分不清哪些是新拖进来的。
    static let inbox: URL = {
        let url = documents.appendingPathComponent("导入", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // 放一份说明。用 .md 而不是 .txt，免得自己被当成一本书导进去。
        let readme = url.appendingPathComponent("使用说明.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            let text = """
            # 导入

            把 TXT 或 EPUB 放进这个文件夹，回到 App 就会自动收进书架，
            原文件随后会被删掉（内容已经存进 App 里了）。

            子文件夹里的书也会一起收。
            """
            try? Data(text.utf8).write(to: readme, options: .atomic)
        }
        return url
    }()
}

/// JSON 编解码配置。日期统一用 ISO8601，换机、跨版本读写都不会歪。
enum Coders {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
