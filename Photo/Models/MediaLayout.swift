import Foundation

/// 媒体文件在磁盘上怎么摆。
///
/// 原来是平铺在 Media 下、文件名一律是 UUID。那样最省事：不会重名、
/// 改名移动都不用碰磁盘。但开了文件共享之后，从访达打开看到的就是一堆
/// `E621E1F8-….jpg`，导出来完全没法用。
///
/// 现在照着库里的层级摆：`Media/<分组>/<目录>/<原文件名>`，共享目录本身
/// 就是可读可导的。代价是分组和目录改名、移动的时候得同步搬磁盘上的东西，
/// 还要处理重名和文件名里的非法字符——都在这个文件和 LibraryStore 里。
enum MediaLayout {

    /// 目录名和文件名一律过一遍这个。
    ///
    /// 不只是为了 iOS：这些文件迟早要从访达拖到 Windows 上去，所以按更严的
    /// 那一套来——Windows 不认 \ / : * ? " < > |，也不许结尾是点或空格。
    static func sanitize(_ raw: String) -> String {
        let banned = Set<Character>("\\/:*?\"<>|")
        var out = ""
        out.reserveCapacity(raw.count)
        for c in raw {
            if banned.contains(c) || c.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                out.append("_")
            } else {
                out.append(c)
            }
        }
        // 结尾的点和空格在 Windows 上会被悄悄吃掉，先去掉免得对不上
        while let last = out.last, last == "." || last == " " {
            out.removeLast()
        }
        // 名字太长有些文件系统扛不住，留够加序号的余地
        if out.count > 80 { out = String(out.prefix(80)) }
        return out.isEmpty ? "未命名" : out
    }

    /// 在一堆已经占用的名字里挑一个不重的：「大阪」「大阪 (2)」「大阪 (3)」…
    /// 比较时不分大小写——iOS 上的文件系统不分，拷到 Windows 上也不分。
    static func unique(_ base: String, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(base.lowercased()) else { return base }
        var n = 2
        while true {
            let candidate = "\(base) (\(n))"
            if !lowered.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    /// 文件名版本：序号要加在扩展名前面，`a (2).jpg` 而不是 `a.jpg (2)`
    static func uniqueFile(stem: String, ext: String, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        let join = { (s: String) in ext.isEmpty ? s : s + "." + ext }

        guard lowered.contains(join(stem).lowercased()) else { return join(stem) }
        var n = 2
        while true {
            let candidate = join("\(stem) (\(n))")
            if !lowered.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    /// 目录里已经有哪些名字。磁盘是唯一权威——库里的记录可能和磁盘对不上，
    /// 真要重名了受苦的是文件系统。
    static func names(in directory: URL) -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(items)
    }
}
