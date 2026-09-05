import Foundation

// MARK: - 「导入」文件夹

extension LibraryStore {

    /// 收走「导入」文件夹里的照片和视频。App 一进前台就跑一次。
    ///
    /// 文件夹结构照搬成分组和目录：
    ///
    ///     导入/2025 京都/大阪/a.jpg  →  分组「2025 京都」→ 目录「大阪」
    ///     导入/2025 京都/a.jpg       →  分组「2025 京都」→ 目录「未分类」
    ///     导入/a.jpg                 →  分组「电脑导入」→ 目录「未分类」
    ///
    /// 导进来之后原文件就没了（视频是直接搬走的，图片读完删掉）：内容已经
    /// 存进 App 自己的目录，留着只会让人以为没导成功，下次进前台又导一遍。
    /// 返回收进来的个数。
    @discardableResult
    func importFromInbox() async -> Int {
        // 扫目录和读文件都甩到后台：这两件事都是磁盘 IO，
        // 压在主线程上会让 App 刚回到前台就卡一下
        let files = await Task.detached(priority: .utility) { Self.scanInbox() }.value
        guard !files.isEmpty else { return 0 }

        var saved = 0
        for file in files {
            let folderID = folderID(for: file.relativePath)
            let name = file.url.lastPathComponent
            let url = file.url

            if MediaFormats.isVideo(fileName: name) {
                // 先探一次再收。
                //
                // 从电脑往这个文件夹拷东西的时候，App 一切到前台就开扫，
                // 很可能撞上还没拷完的文件。半个文件 AVFoundation 连时长都
                // 读不出来，收进去就成了一条永远显示「不支持」的记录，而
                // 电脑上那个文件后来是好的——查起来毫无头绪。
                //
                // 读不出来就先留着，下次回到前台再试。宁可晚一轮，
                // 也别把半个文件收成一条坏记录。
                let info = await VideoProbe.inspect(url)
                guard info.duration > 0 || info.width > 0 else { continue }

                // 视频不读进内存：几百 MB 一读就被系统杀。
                // addVideo 内部是搬文件，搬走之后源文件自然就没了。
                if await addVideo(from: url, to: folderID, name: name) != nil { saved += 1 }
            } else {
                let data = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                guard let data else { continue }
                if await addImage(data: data, to: folderID, name: name) != nil {
                    try? FileManager.default.removeItem(at: url)
                    saved += 1
                }
            }
        }

        await Task.detached(priority: .utility) { Self.pruneEmptyFolders() }.value
        return saved
    }

    // MARK: 扫描

    private struct InboxFile: Sendable {
        var url: URL
        /// 相对「导入」文件夹的路径，含文件名
        var relativePath: [String]
    }

    nonisolated private static func scanInbox() -> [InboxFile] {
        let fm = FileManager.default
        let root = Paths.inbox
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [] }

        // 逐级 standardized 之后再比前缀：枚举器给的 URL 可能带 /private 前缀，
        // 直接和 root.path 比会一个都对不上。
        let rootParts = root.standardizedFileURL.pathComponents
        var out: [InboxFile] = []

        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard MediaFormats.isImage(fileName: name) || MediaFormats.isVideo(fileName: name) else { continue }

            let parts = url.standardizedFileURL.pathComponents
            guard parts.count > rootParts.count,
                  Array(parts.prefix(rootParts.count)) == rootParts else { continue }
            out.append(InboxFile(url: url, relativePath: Array(parts.dropFirst(rootParts.count))))
        }

        // 按路径排序，同一个文件夹里的东西就会连着导，顺序也和电脑上看到的一致
        return out.sorted { $0.relativePath.joined(separator: "/") < $1.relativePath.joined(separator: "/") }
    }

    nonisolated private static func pruneEmptyFolders() {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: Paths.inbox,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        for dir in subdirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            removeIfEmpty(dir)
        }
    }

    /// 先递归清空子目录再看自己，一趟就能把整棵空目录树收掉
    nonisolated private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            removeIfEmpty(item)
        }
        if let left = try? fm.contentsOfDirectory(atPath: dir.path), left.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: 落到哪个目录

    /// 相对路径 → 目录 ID。分组和目录不存在就建，同名的直接复用。
    private func folderID(for relativePath: [String]) -> UUID {
        // 最后一段是文件名本身
        let dirs = relativePath.dropLast().compactMap(Self.sanitize).prefix(8)

        let groupName = dirs.first ?? "电脑导入"
        let group = self.group(named: groupName)

        var current: UUID?
        for name in dirs.dropFirst() {
            guard let next = folder(named: name, under: current, in: group.id) else { break }
            current = next.id
        }
        if let current { return current }

        // 分组底下直接放着文件，没有目录可落——建一个兜底的
        return folder(named: "未分类", under: nil, in: group.id)?.id
            ?? addFolder(to: group.id, name: "未分类")?.id
            ?? UUID()
    }

    /// 目录名当成不可信输入：跳过 . 和 ..，去掉首尾空白，空的丢掉
    private static func sanitize(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return name
    }

    private func group(named name: String) -> PhotoGroup {
        if let hit = groups.first(where: { $0.name == name }) { return hit }
        return addGroup(name: name)
    }
}
