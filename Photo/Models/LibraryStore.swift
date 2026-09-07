import Foundation
import ImageIO
import UniformTypeIdentifiers
import Observation

/// 磁盘路径。放在 actor 之外，服务端线程也能安全读取。
enum Paths {

    static let documents: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    /// 照片和视频。开了文件共享之后这里就是入口——直接往里建目录、丢文件，
    /// App 回到前台会扫一遍收进来。
    static let media: URL = {
        let url = documents.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // 放一份说明。用 .md，不在收媒体的后缀里，不会被当成一张图收进去。
        let readme = url.appendingPathComponent("使用说明.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            let text = """
            # 媒体库

            这个文件夹就是 App 的媒体库本身，目录结构对应分组和目录：

                Media/2025 京都/大阪/IMG_0001.jpg   →  分组「2025 京都」→ 目录「大阪」
                Media/视频/a.mp4                    →  分组「视频」→ 目录「未分类」

            **直接在这里新建文件夹、丢照片视频就行**，回到 App 会自动收进去，
            文件不会被搬走也不会改名。在这里删掉的，App 里也会跟着消失。

            分组那一层是必须的：直接躺在 Media 根下的文件不会被收。

            这个文件夹里只有你自己的照片和视频，没有 App 记账用的东西——
            分组记录、视频封面都收在 App 内部，不用也不该在这儿管。
            """
            try? Data(text.utf8).write(to: readme, options: .atomic)
        }
        return url
    }()

    /// 视频封面缓存。
    /// 抽一帧要一两百毫秒，只放内存的话每次冷启动划列表都会卡，所以落盘。
    ///
    /// 原来放在 Documents 里，和 Media 并排——那是把 App 自己的中间产物
    /// 摆进了人的文件夹。它是从视频里抽出来的，删了会自己重生，
    /// 不该出现在访达里。
    static let posters: URL = {
        let url = AppStore.root.appendingPathComponent("Posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        AppStore.migrateDirFromDocuments("Posters", to: url)
        // 封面能重新抽，没必要让它把 iCloud 备份撑大
        AppStore.excludeFromBackup(url)
        return url
    }()

    /// 分组、目录、每个文件的记录。
    ///
    /// 早先放在 Documents 里，还给它打过 BSD 的 immutable 标志让访达改不动。
    /// 那是在补一个不该存在的问题——搬进内部目录，它压根就不出现在那儿。
    static let libraryFile: URL = {
        let url = AppStore.file("library.json")
        AppStore.migrateFromDocuments("library.json", to: url)
        return url
    }()

    static func url(for asset: Asset) -> URL {
        media.appendingPathComponent(asset.fileName)
    }

    static func poster(for assetID: UUID) -> URL {
        posters.appendingPathComponent("\(assetID.uuidString).jpg")
    }
}

/// 全局数据仓库：分组 / 目录 / 图片的增删改查 + 磁盘持久化。
/// 所有变更都在主线程进行（WiFi 服务端会 hop 到主线程调用）。
@MainActor
@Observable
final class LibraryStore {

    private(set) var library = Library()

    /// 正在和磁盘对账。挡住重入，见 syncWithDisk。
    var isSyncing = false

    nonisolated static func fileURL(for asset: Asset) -> URL { Paths.url(for: asset) }
    nonisolated static func posterURL(for assetID: UUID) -> URL { Paths.poster(for: assetID) }

    // MARK: 生命周期

    init() {
        load()
    }

    /// 读索引。读不到就空着起来，然后靠 Media 里的文件重建。
    ///
    /// 索引不是唯一的真相，文件才是——每张图、每个视频都实实在在躺在
    /// Media 下，目录结构本身就是分组和目录。所以 library.json 被删、被写坏、
    /// 根本没建过，都不该是个死局：空着起来，第一次对账时磁盘上的文件一个
    /// 都对不上号，全当新文件收一遍，图库就按目录结构长回来了。
    /// 丢的是只存在索引里的那些东西——收藏、排序、自定义封面。
    ///
    /// 「文件不存在」和「文件在但解不开」要分开对待。前者是正常的（第一次
    /// 启动就是这样），后者说明本来有东西、现在读不出来了——先把它挪到旁边
    /// 留个底再重建，不然第一次自动保存就把还能救的东西盖掉了。
    private func load() {
        guard let data = try? Data(contentsOf: Paths.libraryFile) else { return }
        guard let decoded = try? Coders.makeDecoder().decode(Library.self, from: data) else {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.moveItem(
                at: Paths.libraryFile,
                to: AppStore.file("library.损坏-\(stamp).json"))
            return
        }
        library = decoded
    }

    private var saveTask: Task<Void, Never>?

    /// 合并 0.4s 内的多次写入，避免批量导入时反复落盘
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = library
        saveTask = Task { [snapshot] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let snapshot = library
        Task.detached(priority: .utility) { await Self.write(snapshot) }
    }

    /// 服务端逐个收文件时用。
    ///
    /// 和 saveNow 的区别只在要不要合并。网页那边挑一整个相册上传，是几千个
    /// 请求挨着来，每来一个就整份索引写一遍的话，写入量是文件数的平方——
    /// 一万个文件累计约 13 GB。合并之后连着来的并成一次。
    ///
    /// 掉最后 400ms 的记录不要紧：文件已经落在 Media 里，下次启动对账会把
    /// 它收回来。索引不是唯一的真相，磁盘才是。
    func scheduleSaveFromServer() { scheduleSave() }

    private nonisolated static func write(_ snapshot: Library) async {
        guard let data = try? Coders.makeEncoder().encode(snapshot) else { return }
        try? data.write(to: Paths.libraryFile, options: .atomic)
    }

    // MARK: 查询

    var groups: [PhotoGroup] { library.groups }

    var sortedGroups: [PhotoGroup] { library.groups.sorted(by: library.groupSort) }

    var groupSort: SortMode {
        get { library.groupSort }
        set { library.groupSort = newValue; scheduleSave() }
    }

    var folderSort: SortMode {
        get { library.folderSort }
        set { library.folderSort = newValue; scheduleSave() }
    }

    var appearance: AppTheme {
        get { library.appearance }
        set { library.appearance = newValue; scheduleSave() }
    }

    var totalPhotoCount: Int { library.groups.reduce(0) { $0 + $1.photoCount } }
    var totalImageCount: Int { library.groups.reduce(0) { $0 + $1.imageCount } }
    var totalVideoCount: Int { library.groups.reduce(0) { $0 + $1.videoCount } }

    func group(_ id: UUID) -> PhotoGroup? {
        library.groups.first { $0.id == id }
    }

    func folder(_ id: UUID) -> Folder? {
        for g in library.groups {
            if let f = g.folders.first(where: { $0.id == id }) { return f }
        }
        return nil
    }

    /// 返回 (分组下标, 目录下标)
    private func locate(folder id: UUID) -> (Int, Int)? {
        for (gi, g) in library.groups.enumerated() {
            if let fi = g.folders.firstIndex(where: { $0.id == id }) { return (gi, fi) }
        }
        return nil
    }

    func groupID(containing folderID: UUID) -> UUID? {
        guard let (gi, _) = locate(folder: folderID) else { return nil }
        return library.groups[gi].id
    }

    private func group(containing folderID: UUID) -> PhotoGroup? {
        guard let (gi, _) = locate(folder: folderID) else { return nil }
        return library.groups[gi]
    }

    // MARK: 目录树查询

    /// 某个目录的直接子目录
    func children(of folderID: UUID) -> [Folder] {
        group(containing: folderID)?.children(of: folderID) ?? []
    }

    /// 从分组根到该目录的一串目录，做面包屑用
    func path(to folderID: UUID) -> [Folder] {
        group(containing: folderID)?.path(to: folderID) ?? []
    }

    /// 含子目录的照片数
    func totalPhotoCount(in folderID: UUID) -> Int {
        group(containing: folderID)?.totalPhotoCount(in: folderID) ?? 0
    }

    /// 含子目录的子目录数（不含自己）
    func totalFolderCount(in folderID: UUID) -> Int {
        group(containing: folderID)?.totalFolderCount(in: folderID) ?? 0
    }

    /// 目录封面：自己没图就往子目录里找
    func coverAssets(for folderID: UUID) -> [Asset] {
        group(containing: folderID)?.coverAssets(for: folderID) ?? []
    }

    /// 这个目录所在的那一组，每个目录的汇总。
    ///
    /// 上面那三个（totalPhotoCount / totalFolderCount / coverAssets）是按单个
    /// 目录问的，一屏几十张卡片就要问几十次，每次都从头走一遍子树。列表那一层
    /// 改成叫这个：整组一次算完再分发，见 PhotoGroup.folderSummaries。
    /// 那三个留给对话框、选择器这些一次只问一两个的地方。
    func folderSummaries(inGroupOf folderID: UUID) -> [UUID: PhotoGroup.FolderSummary] {
        group(containing: folderID)?.folderSummaries() ?? [:]
    }

    func asset(_ id: UUID) -> Asset? {
        for g in library.groups {
            for f in g.folders {
                if let a = f.assets.first(where: { $0.id == id }) { return a }
            }
        }
        return nil
    }

    /// 记下这个视频看到第几秒了。
    ///
    /// 一次播放最多来两次：离开播放页时一次，App 退到后台时一次（那一下
    /// 之后可能就被上划杀掉了，不趁机存就全丢了）。播放中不写盘——进度差
    /// 几秒无所谓，而每秒写一次等于把整个 library.json 反复重写一遍。
    ///
    /// 既然一次播放才这么几下，就直接 saveNow 落盘，不走那个 400ms 的合并
    /// 队列：合并是为了扛住批量导入那种连珠炮，而这里恰恰相反——最需要写
    /// 进去的那一次，正好是 App 马上要被杀掉的那一次。
    ///
    /// 存 0 表示「当没看过」，刚点开就走的和已经看完的都归到这一类。
    func setPlayback(_ seconds: Double, for assetID: UUID) {
        for gi in library.groups.indices {
            for fi in library.groups[gi].folders.indices {
                guard let ai = library.groups[gi].folders[fi].assets
                    .firstIndex(where: { $0.id == assetID }) else { continue }
                var asset = library.groups[gi].folders[fi].assets[ai]
                guard asset.isVideo else { return }
                let clean = seconds.isFinite ? max(0, seconds) : 0
                guard abs(clean - asset.playbackSeconds) > 1 else { return }
                asset.playbackSeconds = clean
                library.groups[gi].folders[fi].assets[ai] = asset
                saveNow()
                return
            }
        }
    }

    // MARK: 分组

    @discardableResult
    func addGroup(name: String) -> PhotoGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "新分组" : trimmed
        let group = PhotoGroup(
            name: display,
            colorIndex: library.groups.count % Theme.palette.count,
            dirName: MediaLayout.unique(MediaLayout.sanitize(display),
                                        taken: Set(library.groups.map(\.dirName)))
        )
        library.groups.append(group)
        makeDirectory(group.dirName)
        scheduleSave()
        return group
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        library.groups[i].name = trimmed

        // 磁盘上的目录跟着改名，子树里所有资产的路径也要改写
        let taken = Set(library.groups.enumerated().compactMap { $0.offset == i ? nil : $0.element.dirName })
        let newDir = MediaLayout.unique(MediaLayout.sanitize(trimmed), taken: taken)
        let oldDir = library.groups[i].dirName
        if newDir != oldDir, relocate(from: oldDir, to: newDir) {
            library.groups[i].dirName = newDir
        }
        scheduleSave()
    }

    func setGroupColor(_ id: UUID, index: Int) {
        guard let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        library.groups[i].colorIndex = index
        scheduleSave()
    }

    func deleteGroup(_ id: UUID) {
        guard let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        let removed = library.groups.remove(at: i)
        for folder in removed.folders {
            for asset in folder.assets { removeFile(asset) }
        }
        // 整个分组的目录一起删掉，不然会留下一棵空壳目录树
        if !removed.dirName.isEmpty {
            try? FileManager.default.removeItem(at: Paths.media.appendingPathComponent(removed.dirName))
        }
        scheduleSave()
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        library.groups.move(fromOffsets: source, toOffset: destination)
        library.groupSort = .manual
        scheduleSave()
    }

    // MARK: 目录

    @discardableResult
    func addFolder(to groupID: UUID, name: String, parent parentID: UUID? = nil) -> Folder? {
        guard let gi = library.groups.firstIndex(where: { $0.id == groupID }) else { return nil }
        // 父目录必须在同一个分组里，否则会造出一个谁也看不到的孤儿目录
        if let parentID, !library.groups[gi].folders.contains(where: { $0.id == parentID }) {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "新目录" : trimmed
        let taken = Set(library.groups[gi].folders.filter { $0.parentID == parentID }.map(\.dirName))
        let folder = Folder(name: display, parentID: parentID,
                            dirName: MediaLayout.unique(MediaLayout.sanitize(display), taken: taken))
        library.groups[gi].folders.append(folder)
        if let path = dirPath(ofFolder: folder.id) { makeDirectory(path) }
        scheduleSave()
        return folder
    }

    /// 在某个目录下按名字取子目录，没有就建一个。
    /// 网页拖文件夹上来时按相对路径逐级建目录用。
    @discardableResult
    func folder(named name: String, under parentID: UUID?, in groupID: UUID) -> Folder? {
        guard let gi = library.groups.firstIndex(where: { $0.id == groupID }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let hit = library.groups[gi].folders.first(where: {
            $0.parentID == parentID && $0.name == trimmed
        }) {
            return hit
        }
        return addFolder(to: groupID, name: trimmed, parent: parentID)
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let (gi, fi) = locate(folder: id) else { return }
        let oldPath = dirPath(ofFolder: id)
        library.groups[gi].folders[fi].name = trimmed

        let parent = library.groups[gi].folders[fi].parentID
        let taken = Set(library.groups[gi].folders.enumerated().compactMap {
            ($0.offset == fi || $0.element.parentID != parent) ? nil : $0.element.dirName
        })
        let newDir = MediaLayout.unique(MediaLayout.sanitize(trimmed), taken: taken)
        let oldDir = library.groups[gi].folders[fi].dirName
        if newDir != oldDir {
            // 先把新名字落下去才能算出新路径，搬不动再改回来——
            // 记录指着一个不存在的目录，比名字没改过来难受得多
            library.groups[gi].folders[fi].dirName = newDir
            if let oldPath, let newPath = dirPath(ofFolder: id),
               !relocate(from: oldPath, to: newPath) {
                library.groups[gi].folders[fi].dirName = oldDir
            }
        }
        scheduleSave()
    }

    /// 删目录连同整棵子树，磁盘文件一并清掉
    func deleteFolder(_ id: UUID) {
        guard let (gi, _) = locate(folder: id) else { return }
        let doomed = library.groups[gi].subtree(of: id)
        let doomedIDs = Set(doomed.map(\.id))
        let doomedPath = dirPath(ofFolder: id)
        for folder in doomed {
            for asset in folder.assets { removeFile(asset) }
        }
        library.groups[gi].folders.removeAll { doomedIDs.contains($0.id) }
        if let doomedPath {
            try? FileManager.default.removeItem(at: Paths.media.appendingPathComponent(doomedPath))
        }
        scheduleSave()
    }

    /// 把目录（连同子树）挂到别处。parent 为 nil 表示挂在目标分组的根下。
    func moveFolder(_ id: UUID, toGroup targetGroupID: UUID, parent parentID: UUID? = nil) {
        guard id != parentID,
              let (gi, fi) = locate(folder: id),
              let ti = library.groups.firstIndex(where: { $0.id == targetGroupID }) else { return }

        if let parentID {
            // 目标父目录得真的在目标分组里
            guard library.groups[ti].folders.contains(where: { $0.id == parentID }) else { return }
            // 不能移进自己的子孙里——那样这棵子树就从树上断开了，谁也访问不到，
            // 界面上还会因为 parent 链成环而走不到头
            if ti == gi, library.groups[gi].subtree(of: id).contains(where: { $0.id == parentID }) {
                return
            }
        }

        let oldPath = dirPath(ofFolder: id)

        if ti == gi {
            library.groups[gi].folders[fi].parentID = parentID
        } else {
            // 跨分组要把整棵子树一起搬走，只搬根节点的话子目录会留在原分组变成孤儿
            var moving = library.groups[gi].subtree(of: id)
            let movingIDs = Set(moving.map(\.id))
            library.groups[gi].folders.removeAll { movingIDs.contains($0.id) }
            if let root = moving.firstIndex(where: { $0.id == id }) {
                moving[root].parentID = parentID
            }
            library.groups[ti].folders.append(contentsOf: moving)
        }

        // 换了地方就可能和新邻居重名，重新挑一个再把磁盘上的目录搬过去
        if let (ngi, nfi) = locate(folder: id) {
            let taken = Set(library.groups[ngi].folders.enumerated().compactMap {
                ($0.offset == nfi || $0.element.parentID != parentID) ? nil : $0.element.dirName
            })
            library.groups[ngi].folders[nfi].dirName =
                MediaLayout.unique(MediaLayout.sanitize(library.groups[ngi].folders[nfi].name), taken: taken)
        }
        if let oldPath, let newPath = dirPath(ofFolder: id) {
            relocate(from: oldPath, to: newPath)
        }
        scheduleSave()
    }

    /// 在同一父目录下重排。
    /// source/destination 是「同级列表」里的下标，不是 folders 数组的下标——
    /// folders 里平铺着所有层级，直接按它的下标移会把别的层级也搅乱。
    func moveFolders(in groupID: UUID, parent parentID: UUID?,
                     from source: IndexSet, to destination: Int) {
        guard let gi = library.groups.firstIndex(where: { $0.id == groupID }) else { return }
        var siblings = library.groups[gi].folders.filter { $0.parentID == parentID }
        siblings.move(fromOffsets: source, toOffset: destination)

        // 把重排后的同级序列填回它们原来占的那些位置，其他层级原地不动
        var next = siblings.makeIterator()
        library.groups[gi].folders = library.groups[gi].folders.map { folder in
            folder.parentID == parentID ? (next.next() ?? folder) : folder
        }
        library.folderSort = .manual
        scheduleSave()
    }

    // MARK: 图片

    /// 探测尺寸并落盘。不碰内存中的数据结构，所以可以在后台线程跑。
    /// 写到指定位置。文件名由调用方按目标目录算好——它要看库里的层级，
    /// 那是主线程的事，这里只管落盘。
    nonisolated static func persist(_ data: Data, to url: URL,
                                    relativePath: String, originalName: String) -> Asset? {
        guard let info = ImageProbe.inspect(data) else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }

        return Asset(fileName: relativePath,
                     originalName: Self.displayName(from: originalName),
                     width: info.width,
                     height: info.height,
                     byteCount: data.count)
    }

    /// 取文件名里最后一段并去掉扩展名。网页拖文件夹上来时带的是相对路径。
    nonisolated static func displayName(from raw: String) -> String {
        let last = raw.split(separator: "/").last.map(String.init) ?? raw
        return (last as NSString).deletingPathExtension
    }

    /// 把已落盘的图片挂到目录下（只动内存结构，必须在主线程）
    @discardableResult
    func attach(_ asset: Asset, to folderID: UUID) -> Bool {
        guard let (gi, fi) = locate(folder: folderID) else {
            // 目录在落盘期间被删了，清掉这个孤儿文件
            try? FileManager.default.removeItem(at: Paths.url(for: asset))
            return false
        }
        library.groups[gi].folders[fi].assets.append(asset)
        scheduleSave()
        return true
    }

    /// 落盘 + 挂载一步到位。磁盘 IO 在后台线程，主线程只做数组插入。
    @discardableResult
    func addImage(data: Data, to folderID: UUID, name: String = "") async -> Asset? {
        guard folder(folderID) != nil, let dir = dirPath(ofFolder: folderID) else { return nil }

        // 扩展名要先探出来才能定文件名——从相册选的图常常连文件名都没有。
        // 探测放后台：一次导一千张的话，每张在主线程上多花两毫秒也是两秒。
        let probe = Task.detached(priority: .userInitiated) { ImageProbe.inspect(data) }
        guard let info = await probe.value else { return nil }
        let (relative, url) = destination(inDir: dir, rawName: name, fallbackExt: info.fileExtension)

        // Task.detached 的尾随闭包不能直接写在 guard 条件里：
        // 编译器会把那个 { 当成 guard 的语句块开头。先把任务提出来。
        let work = Task.detached(priority: .userInitiated) {
            LibraryStore.persist(data, to: url, relativePath: relative, originalName: name)
        }
        guard let asset = await work.value else { return nil }

        return attach(asset, to: folderID) ? asset : nil
    }

    // MARK: 视频

    /// 把一个已经在磁盘上的视频文件搬进媒体库。
    ///
    /// 视频不能像图片那样先读成 Data——手机拍的 1 分钟 4K 就有几百 MB，
    /// 读进内存直接会被系统杀掉。这里只做文件搬移和元信息探测。
    nonisolated static func persistVideo(from source: URL, to target: URL,
                                         relativePath: String,
                                         originalName: String = "") async -> Asset? {
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        do {
            // 先试移动。同卷内是改目录项，不复制字节，几百 MB 也是瞬间完成。
            // 跨卷（临时目录常常和 Documents 不同卷）会失败，再退回复制。
            do { try FileManager.default.moveItem(at: source, to: target) }
            catch { try FileManager.default.copyItem(at: source, to: target) }
        } catch {
            return nil
        }

        let info = await VideoProbe.inspect(target)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0

        return Asset(fileName: relativePath,
                     originalName: Self.displayName(from: originalName),
                     kind: .video,
                     width: info.width,
                     height: info.height,
                     byteCount: bytes ?? 0,
                     duration: info.duration)
    }

    @discardableResult
    func addVideo(from source: URL, to folderID: UUID, name: String = "") async -> Asset? {
        guard folder(folderID) != nil, let dir = dirPath(ofFolder: folderID) else { return nil }
        // 扩展名优先按原始文件名取：网页上传那条路的临时文件是个纯 UUID，
        // 一点后缀都没有，只看 source 的话会落成 .mov，而 AVURLAsset 是按
        // 扩展名定 UTI 挑解析器的，对不上就打不开。
        var ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty { ext = source.pathExtension.lowercased() }
        if ext.isEmpty { ext = "mp4" }

        let (relative, target) = destination(inDir: dir, rawName: name, fallbackExt: ext)
        guard let asset = await LibraryStore.persistVideo(from: source, to: target,
                                                          relativePath: relative,
                                                          originalName: name) else { return nil }
        return attach(asset, to: folderID) ? asset : nil
    }

    func deleteAssets(_ ids: Set<UUID>, from folderID: UUID) {
        guard !ids.isEmpty, let (gi, fi) = locate(folder: folderID) else { return }
        let removed = library.groups[gi].folders[fi].assets.filter { ids.contains($0.id) }
        library.groups[gi].folders[fi].assets.removeAll { ids.contains($0.id) }
        for asset in removed { removeFile(asset) }
        scheduleSave()
    }

    func moveAssets(_ ids: Set<UUID>, from folderID: UUID, to targetFolderID: UUID) {
        guard folderID != targetFolderID,
              let (gi, fi) = locate(folder: folderID),
              let (tgi, tfi) = locate(folder: targetFolderID) else { return }
        var moving = library.groups[gi].folders[fi].assets.filter { ids.contains($0.id) }
        guard !moving.isEmpty, let dir = dirPath(ofFolder: targetFolderID) else { return }

        // 记录搬完了，磁盘上的文件也得搬——不然新目录里是空的，
        // 而旧目录里躺着一堆库里已经不认的文件
        let dirURL = Paths.media.appendingPathComponent(dir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        var taken = MediaLayout.names(in: dirURL)
        for i in moving.indices {
            let src = Paths.url(for: moving[i])
            let leaf = (moving[i].fileName as NSString).lastPathComponent
            let unique = MediaLayout.uniqueFile(stem: (leaf as NSString).deletingPathExtension,
                                                ext: (leaf as NSString).pathExtension,
                                                taken: taken)
            taken.insert(unique)
            let dst = dirURL.appendingPathComponent(unique)
            try? FileManager.default.moveItem(at: src, to: dst)
            moving[i].fileName = dir.isEmpty ? unique : dir + "/" + unique
        }

        library.groups[gi].folders[fi].assets.removeAll { ids.contains($0.id) }
        library.groups[tgi].folders[tfi].assets.append(contentsOf: moving)
        scheduleSave()
    }

    // MARK: 磁盘布局
    //
    // 文件按库里的层级摆：Media/<分组>/<各级目录>/<原文件名>。
    // 开了文件共享之后，从访达打开共享目录看到的就是这棵树，直接拖走就能用。
    // 代价是分组和目录改名、移动的时候要同步搬磁盘上的东西，都在这一节里。

    /// 目录在 Media 下的相对路径
    func dirPath(ofFolder folderID: UUID) -> String? {
        guard let group = group(containing: folderID) else { return nil }
        var parts = [group.dirName]
        parts.append(contentsOf: path(to: folderID).map(\.dirName))
        return parts.filter { !$0.isEmpty }.joined(separator: "/")
    }

    private func makeDirectory(_ relative: String) {
        guard !relative.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: Paths.media.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    /// 目录换了位置：磁盘上搬一次，再把这棵子树里所有资产记录的路径前缀改掉。
    ///
    /// 搬目录是一次 rename，不管里面有几千个文件都是瞬间的；逐个搬文件才慢。
    /// 返回是否真的搬成了。
    ///
    /// 搬不动的时候一定不能改记录：新名字是拿索引里的名字避重算出来的，
    /// 但磁盘上可能躺着一个没进索引的同名目录——那时 moveItem 会失败，
    /// 而记录如果已经改了，整组照片就都指着一个不存在的目录，
    /// 界面上是一片灰。宁可名字没改过来。
    @discardableResult
    private func relocate(from old: String, to new: String) -> Bool {
        guard !old.isEmpty, !new.isEmpty, old != new else { return false }

        let src = Paths.media.appendingPathComponent(old)
        let dst = Paths.media.appendingPathComponent(new)
        if FileManager.default.fileExists(atPath: src.path) {
            guard !FileManager.default.fileExists(atPath: dst.path) else { return false }
            try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            do { try FileManager.default.moveItem(at: src, to: dst) }
            catch { return false }
        }

        let oldPrefix = old + "/", newPrefix = new + "/"
        for gi in library.groups.indices {
            for fi in library.groups[gi].folders.indices {
                for ai in library.groups[gi].folders[fi].assets.indices {
                    let path = library.groups[gi].folders[fi].assets[ai].fileName
                    guard path.hasPrefix(oldPrefix) else { continue }
                    library.groups[gi].folders[fi].assets[ai].fileName =
                        newPrefix + String(path.dropFirst(oldPrefix.count))
                }
            }
        }
        // 目录变了，记着的那些占用名不作数了
        claimedNames.removeValue(forKey: old)
        claimedNames.removeValue(forKey: new)
        return true
    }

    /// 每个目录里已经占掉的文件名。
    ///
    /// 挑落点要避开重名，而重名得问磁盘——库里的记录可能和磁盘对不上。
    /// 但原来是每存一个文件就把整个目录列一遍：往同一个目录导一千张照片
    /// 就是一千次列举，而目录还在一张张变长，总代价是平方级的，还全压在
    /// 主线程上。记住结果之后，每存一张只多一次 stat。
    ///
    /// 只进不出。文件删掉之后这里还留着那个名字，最多让下一张白带个 (2)，
    /// 不会出错。反过来漏记才是要命的——那会挑中一个磁盘上已经存在的名字，
    /// 写下去就把人家的照片覆盖了。所以落笔前对选中的那一个名字再确认一次。
    private var claimedNames: [String: Set<String>] = [:]

    /// 在某个目录里给新文件挑个不重名的落点，返回（相对路径, 完整 URL）
    private func destination(inDir dir: String, rawName: String,
                             fallbackExt: String) -> (String, URL) {
        let dirURL = Paths.media.appendingPathComponent(dir)
        let raw = (rawName as NSString).lastPathComponent
        var stem = MediaLayout.sanitize((raw as NSString).deletingPathExtension)
        if stem.isEmpty { stem = "未命名" }
        var ext = (raw as NSString).pathExtension.lowercased()
        if ext.isEmpty { ext = fallbackExt }

        var taken = claimedNames[dir] ?? MediaLayout.names(in: dirURL)
        var leaf = MediaLayout.uniqueFile(stem: stem, ext: ext, taken: taken)
        // 缓存只进不出，可能漏了别处刚放进来的文件。覆盖掉别人的照片太惨，
        // 所以对选中的这一个名字再问一次磁盘——一次 stat，比列整个目录
        // 便宜几个数量级；真撞上了才重新列一遍。
        if FileManager.default.fileExists(atPath: dirURL.appendingPathComponent(leaf).path) {
            taken = MediaLayout.names(in: dirURL)
            leaf = MediaLayout.uniqueFile(stem: stem, ext: ext, taken: taken)
        }
        taken.insert(leaf)
        claimedNames[dir] = taken

        let relative = dir.isEmpty ? leaf : dir + "/" + leaf
        return (relative, dirURL.appendingPathComponent(leaf))
    }

    /// 忘掉记住的那些名字，下次重新问磁盘。
    /// 对账时叫一次就够：那正是磁盘和索引可能对不上的时刻。
    func forgetClaimedNames() { claimedNames.removeAll() }

    // MARK: 给磁盘对账用的小口子
    //
    // library 是 private(set)，同文件之外改不了。DiskSync 要按磁盘上的
    // 实际目录名回填、要摘掉文件已经没了的记录，所以在这儿开三个口子，
    // 而不是把整个 library 放开写。

    /// 按磁盘上的目录名回填。磁盘那个才是权威——addGroup/addFolder 会自己
    /// 洗名字避重，算出来的可能和磁盘上的不一样。
    func setDirName(_ name: String, forGroup id: UUID) {
        guard let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        library.groups[i].dirName = name
    }

    func setDirName(_ name: String, forFolder id: UUID) {
        guard let (gi, fi) = locate(folder: id) else { return }
        library.groups[gi].folders[fi].dirName = name
    }

    /// 摘掉文件已经不在磁盘上的记录，返回摘掉几条。
    ///
    /// 视频封面是单独落盘的（Posters/<资产 id>.jpg），记录摘了它不会自己消失，
    /// 得一起删——不然在访达里删几百个视频，Posters 里就留几百张没人认领的图。
    func removeAssets(notIn existing: Set<String>) -> Int {
        var removed = 0
        for gi in library.groups.indices {
            for fi in library.groups[gi].folders.indices {
                let before = library.groups[gi].folders[fi].assets.count
                library.groups[gi].folders[fi].assets.removeAll { asset in
                    let gone = !existing.contains(asset.fileName.lowercased())
                    if gone {
                        ThumbnailCache.shared.invalidate(asset.id)
                        if asset.isVideo {
                            try? FileManager.default.removeItem(at: Paths.poster(for: asset.id))
                        }
                    }
                    return gone
                }
                removed += before - library.groups[gi].folders[fi].assets.count
            }
        }
        return removed
    }

    /// Posters 里所有还认得出主人的封面
    var livePosterNames: Set<String> {
        var names: Set<String> = []
        for group in library.groups {
            for folder in group.folders {
                for asset in folder.assets where asset.isVideo {
                    names.insert("\(asset.id.uuidString).jpg")
                }
            }
        }
        return names
    }

    private func removeFile(_ asset: Asset) {
        try? FileManager.default.removeItem(at: Paths.url(for: asset))
        // 视频的封面是单独落盘的，不一起删就会留一堆没人认领的 jpg
        if asset.isVideo {
            try? FileManager.default.removeItem(at: Paths.poster(for: asset.id))
        }
        ThumbnailCache.shared.invalidate(asset.id)
    }

}

// MARK: - App 内部目录

/// App 内部目录。放索引、封面这些「我们自己记账用」的东西。
///
/// 和 Documents 的分工：Documents 开了文件共享，访达里看得见、拖得动，
/// 那里只该放人自己的东西——照片和视频。索引和封面不是人的东西，
/// 它们是实现细节，摆在媒体旁边只会让人误以为该管，手删了还得连累收藏和排序。
///
/// 原来试过留在 Documents 里、给文件打 BSD 的 immutable 标志（`chflags uchg`）
/// 让访达改不动。能work，但那是在补一个不该存在的问题——最省事的办法是
/// 它压根就不出现在那儿。
enum AppStore {

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// 从 Documents 搬一个文件进来。旧版本把它放在共享目录里，这里搬一次家。
    ///
    /// 目标已经在了就不动——搬过一次之后 Documents 那份如果又冒出来
    /// （从备份恢复、别的设备同步过来），也是旧的，不该盖掉现在这份。
    static func migrateFromDocuments(_ name: String, to target: URL) {
        let fm = FileManager.default
        let old = Paths.documents.appendingPathComponent(name)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: target.path) else { return }
        // 旧版本给索引上过 immutable 锁，锁着的文件搬不动，先摘掉
        try? fm.setAttributes([.immutable: false], ofItemAtPath: old.path)
        try? fm.moveItem(at: old, to: target)
    }

    /// 从 Documents 搬一个目录里的东西进来。
    ///
    /// 不能像文件那样直接 move：新目录在这之前已经建好了，move 到一个
    /// 已存在的路径会失败。逐个搬，搬完把空掉的旧目录删了。
    /// 封面丢了会自己重新抽，所以搬不动的那几张就算了，不值得为它报错。
    static func migrateDirFromDocuments(_ name: String, to target: URL) {
        let fm = FileManager.default
        let old = Paths.documents.appendingPathComponent(name, isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        for item in names {
            try? fm.moveItem(at: old.appendingPathComponent(item),
                             to: target.appendingPathComponent(item))
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
            try? fm.removeItem(at: old)
        }
    }

    /// 从 iCloud/iTunes 备份里排除。
    ///
    /// 给能重算的东西用——封面丢了从视频里再抽一帧就有，没必要让它把
    /// 用户的备份撑大。索引不用排除：收藏、排序、看到第几秒只此一份，
    /// 换手机的时候恰恰是最该跟过去的。
    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - 编解码配置

/// JSONEncoder/Decoder 不是 Sendable，这里每次新建，避免跨线程共用同一个实例
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

// MARK: - 图片探测

enum ImageProbe {
    struct Info {
        var width: Int
        var height: Int
        var fileExtension: String
        var mimeType: String
    }

    /// 不解码整张图，只读元数据拿尺寸和类型
    static func inspect(_ data: Data) -> Info? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }

        var ext = "jpg"
        var mime = "image/jpeg"
        if let uti = CGImageSourceGetType(source) as String?,
           let type = UTType(uti) {
            ext = type.preferredFilenameExtension ?? "jpg"
            mime = type.preferredMIMEType ?? "image/jpeg"
        }
        return Info(width: width, height: height, fileExtension: ext, mimeType: mime)
    }

    static func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
