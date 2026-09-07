import Foundation

/// 磁盘路径。放在数据仓库之外，服务端线程也能安全读取。
enum Paths {
    static let documents: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
