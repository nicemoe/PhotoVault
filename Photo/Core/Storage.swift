import Foundation

/// 磁盘路径。放在数据仓库之外，服务端线程也能安全读取。
enum Paths {
    static let documents: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

}

/// 写一份在访达里改不动、删不掉的文件。
///
/// 开了文件共享之后 Documents 整个是敞开的，索引就摆在 Books 旁边。
/// 它是给人看的——想知道 App 怎么记账，打开看一眼、拷一份走都行；
/// 但不该给人改：手改坏了，书架虽然能照着 Books 里的文件重建，
/// 阅读进度和书签还是没了。
///
/// iOS 没有「对 App 可写、对访达只读」这种开关，两边是同一个身份。
/// 能用的是 BSD 的 user immutable 标志（就是 `chflags uchg`）：
/// 打上之后，写、改名、删除一律 EPERM，访达里会直接报错做不了。
/// App 自己也一样被挡，所以每次落盘前先摘掉、写完再打上。
///
/// 单说 0444 那种只读权限位是不够的：能不能删一个文件，看的是所在目录
/// 的写权限，不是文件自己的——只读文件照样能在访达里拖进废纸篓。
enum LockedFile {

    static func write(_ data: Data, to url: URL) {
        // 原子写是「写个临时文件再改名盖上去」，盖不掉一个上了锁的文件，
        // 所以先摘锁。中途被杀最多是这一次没锁上，下次写完照样补上。
        unlock(url)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        // 原子写换的是一个新 inode，锁不会跟过来，得重新打
        try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
    }

    /// 摘锁。要移动、删除这个文件之前必须先来一下，否则一律 EPERM。
    static func unlock(_ url: URL) {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
    }
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
