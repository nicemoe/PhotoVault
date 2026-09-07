import Foundation

// MARK: - 拿磁盘和索引对账

extension LibraryStore {

    /// 扫一遍 Media，把磁盘上多出来的收进来、少掉的清出去。
    ///
    /// 开了文件共享之后，Media 就是用户直接看得见、动得了的东西：他会在
    /// 访达里新建 `Media/视频/搞笑/`、往里丢文件，也会直接删掉不要的。
    /// 所以这里不再单独开一个「导入」文件夹，磁盘本身就是入口——
    /// 目录结构本来就是分组和目录，一一对得上：
    ///
    ///     Media/2025 京都/大阪/IMG_0001.jpg  →  分组「2025 京都」→ 目录「大阪」
    ///     Media/视频/a.mp4                   →  分组「视频」→ 目录「未分类」
    ///
    /// 「哪些是新的」靠对账：asset.fileName 存的正是相对 Media 的路径，
    /// 拿磁盘上扫到的路径和它比一遍就知道。不用比文件数——比数不可靠，
    /// 删一个加一个数字还一样。
    ///
    /// 返回 (收进来的, 清出去的)。
    @discardableResult
    func syncWithDisk() async -> (added: Int, removed: Int) {
        // 扫盘甩到后台：一万张照片走一遍目录树要几百毫秒，
        // 压在主线程上每次切回前台都要顿一下
        let onDisk = await Task.detached(priority: .utility) { Self.scanMedia() }.value

        var known: Set<String> = []
        for group in library.groups {
            for folder in group.folders {
                for asset in folder.assets { known.insert(asset.fileName.lowercased()) }
            }
        }

        // 一、磁盘上有、索引里没有 —— 新丢进来的
        var added = 0
        for path in onDisk.keys.sorted() where !known.contains(path.lowercased()) {
            guard let folderID = folderID(forDiskPath: path) else { continue }
            if await register(path: path, in: folderID) { added += 1 }
        }

        // 二、索引里有、磁盘上没有 —— 在访达里被删掉了。
        //
        // 记录本身不存内容，文件没了这条记录就是个打不开的空壳，留着只会
        // 在列表里显示成一块灰。所以跟着删。
        let removed = removeAssets(notIn: Set(onDisk.keys.map { $0.lowercased() }))

        if added > 0 || removed > 0 { saveNow() }
        return (added, removed)
    }

    // MARK: 扫盘

    /// Media 下所有能认的媒体文件，key 是相对 Media 的路径
    nonisolated private static func scanMedia() -> [String: Bool] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: Paths.media,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [:] }

        let rootParts = Paths.media.standardizedFileURL.pathComponents
        var out: [String: Bool] = [:]

        for case let url as URL in walker {
            let name = url.lastPathComponent
            let isVideo = MediaFormats.isVideo(fileName: name)
            guard isVideo || MediaFormats.isImage(fileName: name) else { continue }

            let parts = url.standardizedFileURL.pathComponents
            guard parts.count > rootParts.count,
                  Array(parts.prefix(rootParts.count)) == rootParts else { continue }
            out[parts.dropFirst(rootParts.count).joined(separator: "/")] = isVideo
        }
        return out
    }

    // MARK: 收进来

    /// 相对路径 → 该落在哪个目录，分组和目录不存在就照着磁盘建出来
    private func folderID(forDiskPath path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }   // 直接躺在 Media 根下的不收

        let groupDir = parts[0]
        let group = groups.first { $0.dirName == groupDir }
            ?? makeGroup(dirName: groupDir)
        guard let group else { return nil }

        // 中间几段是目录，最后一段是文件名
        var current: UUID?
        for dir in parts.dropFirst().dropLast().prefix(8) {
            guard let next = makeFolder(dirName: dir, under: current, in: group.id) else { break }
            current = next
        }
        if let current { return current }

        // 文件直接躺在分组目录下，没有目录可落——收进「未分类」，
        // 和从别处导入的规矩一致
        return makeFolder(dirName: "未分类", under: nil, in: group.id)
    }

    /// 按磁盘上的目录名找分组，没有就建一个同名的。
    /// 注意认的是 dirName 不是显示名：磁盘上那个才是权威。
    private func makeGroup(dirName: String) -> PhotoGroup? {
        // addGroup 会自己洗一遍名字、避重，算出来的 dirName 可能和磁盘上的
        // 不一样。这里要的是和磁盘完全一致，所以照磁盘回填一次。
        let group = addGroup(name: dirName)
        setDirName(dirName, forGroup: group.id)
        return self.group(group.id)
    }

    private func makeFolder(dirName: String, under parentID: UUID?, in groupID: UUID) -> UUID? {
        if let hit = group(groupID)?.folders.first(where: {
            $0.parentID == parentID && $0.dirName == dirName
        }) {
            return hit.id
        }
        guard let folder = addFolder(to: groupID, name: dirName, parent: parentID) else { return nil }
        setDirName(dirName, forFolder: folder.id)
        return folder.id
    }

    /// 探一下这个文件，挂进索引。文件本身不动——它已经在该在的位置了。
    private func register(path: String, in folderID: UUID) async -> Bool {
        let url = Paths.media.appendingPathComponent(path)
        let name = (path as NSString).lastPathComponent

        if MediaFormats.isVideo(fileName: name) {
            // 从电脑往共享目录拷东西的时候，很可能撞上还没拷完的文件。
            // 半个 mp4 连时长都读不出来，收进去就成了一条永远显示「不支持」
            // 的记录。读不出来就先放着，下次回到前台再试。
            let info = await VideoProbe.inspect(url)
            guard info.duration > 0 || info.width > 0 else { return false }

            let bytes = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let asset = Asset(fileName: path,
                              originalName: Self.displayName(from: name),
                              kind: .video,
                              width: info.width,
                              height: info.height,
                              byteCount: bytes ?? 0,
                              duration: info.duration)
            return attach(asset, to: folderID)
        }

        let probe = await Task.detached(priority: .utility) { () -> (ImageProbe.Info, Int)? in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let info = ImageProbe.inspect(data) else { return nil }
            return (info, data.count)
        }.value
        guard let (info, bytes) = probe else { return false }

        let asset = Asset(fileName: path,
                          originalName: Self.displayName(from: name),
                          width: info.width,
                          height: info.height,
                          byteCount: bytes)
        return attach(asset, to: folderID)
    }

}
