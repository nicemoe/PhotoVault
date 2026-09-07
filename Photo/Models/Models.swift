import Foundation
import UIKit   // AppTheme 要用 UIUserInterfaceStyle

// MARK: - 图片

enum AssetKind: String, Codable, Hashable {
    case image
    case video
}

/// 这个文件用哪个解码器。
///
/// 有 auto 还要有手动的两档，是因为花屏这件事程序判断不了：AVFoundation
/// 把一个它不会解的编码画成马赛克时，不报错、不失败，从代码里看和正常播放
/// 一模一样。而封装名也只能猜个大概——被人强行转过壳的 mp4 里塞着 Xvid，
/// 扩展名是 mp4，照样花。所以最后得留一个开关给眼睛用。
enum DecoderChoice: String, Codable, CaseIterable {
    /// 按封装猜。见 MediaFormats.prefersSoftware
    case auto
    /// 硬件解码，省电、seek 跟手
    case hardware
    /// KSPlayer + FFmpeg，什么都能解，费电
    case software

    var label: String {
        switch self {
        case .auto:     return "自动"
        case .hardware: return "硬解"
        case .software: return "软解"
        }
    }
}

struct Asset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// 相对 Documents/Media/ 的路径，形如「2025 京都/大阪/IMG_0001.jpg」。
    ///
    /// 早先这里存的是一个 UUID 文件名、全部平铺在 Media 下。开了文件共享
    /// 之后从访达看到的就是一堆 UUID，导出来没法用，所以改成照库里的层级摆。
    var fileName: String
    /// 导入时的原始文件名（不含扩展名）。
    /// 界面上显示的标题用它——磁盘上那份名字可能因为重名被加了序号。
    /// 从系统相册选的照片拿不到文件名，这里会是空的。
    var originalName: String = ""
    var kind: AssetKind = .image
    var width: Int = 0
    var height: Int = 0
    var byteCount: Int = 0
    /// 用哪个解码器。默认 auto，看着花屏就手动切一次，记在这儿。
    var decoder: DecoderChoice = .auto
    /// 视频时长（秒）；图片是 0
    var duration: Double = 0
    /// 上次看到第几秒。0 表示没看过、或者已经看完了。
    ///
    /// 只在离开播放页时写一次，不是每秒都写——进度这种东西差个几秒无所谓，
    /// 而每秒落一次盘会让整个 library.json 反复重写。
    var playbackSeconds: Double = 0
    var createdAt: Date = Date()

    init(id: UUID = UUID(), fileName: String, originalName: String = "",
         kind: AssetKind = .image,
         width: Int = 0, height: Int = 0, byteCount: Int = 0,
         duration: Double = 0, createdAt: Date = Date()) {
        self.id = id
        self.fileName = fileName
        self.originalName = originalName
        self.kind = kind
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.duration = duration
        self.createdAt = createdAt
    }

    /// 同 Folder，必须手写解码：旧的 library.json 里没有 kind 和 duration，
    /// 合成的 Decodable 会因为缺键直接抛错，整个库读不出来。
    /// 旧数据解出来 kind 全是 image，正好是升级前的样子。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        originalName = try c.decodeIfPresent(String.self, forKey: .originalName) ?? ""
        kind = try c.decodeIfPresent(AssetKind.self, forKey: .kind) ?? .image
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        playbackSeconds = try c.decodeIfPresent(Double.self, forKey: .playbackSeconds) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        // 写 self.：这个初始化方法的参数正好也叫 decoder，不写就指到参数上了
        self.decoder = try c.decodeIfPresent(DecoderChoice.self, forKey: .decoder) ?? .auto
    }

    var isVideo: Bool { kind == .video }

    /// 看过一截、又没看完的才算「能接着看」。
    ///
    /// 两头都掐掉：开头十几秒就走的，多半是点开看了一眼，下次还从头开始更顺；
    /// 快到结尾的，人已经看完了，再从最后五秒接着放没意义。
    var resumeAt: Double {
        guard isVideo, duration > 0, playbackSeconds > 0 else { return 0 }
        guard playbackSeconds > min(15, duration * 0.05) else { return 0 }
        guard playbackSeconds < duration - max(10, duration * 0.02) else { return 0 }
        return playbackSeconds
    }

    /// 看了百分之多少，0 表示没看过。列表里的那根细条用这个。
    var watchedRatio: Double {
        guard isVideo, duration > 0, playbackSeconds > 0 else { return 0 }
        return min(1, playbackSeconds / duration)
    }

    var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    /// 0:07 / 1:23 / 1:02:03
    var durationText: String {
        let total = max(0, Int(duration.rounded()))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

// MARK: - 目录（分组下的一层）

struct Folder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// 父目录；nil 表示直接挂在分组下。
    ///
    /// 同一分组里所有层级的目录都平铺在 group.folders 中，父子关系只靠这个
    /// 字段表达。做成嵌套数组的话，改名、加图这类操作每次都得先递归定位到
    /// 那一层，删父目录时也容易漏掉子树。
    var parentID: UUID?
    /// 这个目录在磁盘上叫什么。
    ///
    /// 不直接拿 name 当目录名：name 可以随便重复、可以带 / : * 这些文件系统
    /// 不认的字符。这里存一份洗过、且在同级里不重名的，改名时一起更新并把
    /// 磁盘上的目录搬过去。空串表示还没分配（旧数据），加载时补。
    var dirName: String = ""
    var createdAt: Date = Date()
    var assets: [Asset] = []

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil,
         dirName: String = "", createdAt: Date = Date(), assets: [Asset] = []) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.dirName = dirName
        self.createdAt = createdAt
        self.assets = assets
    }

    /// 必须手写解码，全部用 decodeIfPresent 兜默认值。
    ///
    /// Swift 合成的 Decodable 不会拿属性默认值当缺失时的兜底——键不在就直接
    /// 抛错。旧的 library.json 里没有 parentID，用合成版会连整个库都解不出来，
    /// 用户的照片会全部消失。旧数据解出来 parentID 全是 nil，也就是全在顶层，
    /// 正好是升级前的样子。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名"
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        dirName = try c.decodeIfPresent(String.self, forKey: .dirName) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    /// 只算本目录自己的，不含子目录
    var photoCount: Int { assets.count }
}

// MARK: - 分组（首页一层）

struct PhotoGroup: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorIndex: Int = 0
    /// 这个分组在 Media 下叫什么。理由同 Folder.dirName。
    var dirName: String = ""
    var createdAt: Date = Date()
    var folders: [Folder] = []

    init(id: UUID = UUID(), name: String, colorIndex: Int = 0, dirName: String = "",
         createdAt: Date = Date(), folders: [Folder] = []) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.dirName = dirName
        self.createdAt = createdAt
        self.folders = folders
    }

    /// 加了 dirName 就必须手写解码。
    ///
    /// Swift 合成的 Decodable 不拿属性默认值兜底——键不在就直接抛错，
    /// 旧的 library.json 里没有 dirName，会连整个库都解不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名"
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        dirName = try c.decodeIfPresent(String.self, forKey: .dirName) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
    }

    /// 含所有层级
    var folderCount: Int { folders.count }
    /// 图片 + 视频的总数
    var photoCount: Int { folders.reduce(0) { $0 + $1.assets.count } }
    var imageCount: Int { folders.reduce(0) { $0 + $1.assets.lazy.filter { !$0.isVideo }.count } }
    var videoCount: Int { folders.reduce(0) { $0 + $1.assets.lazy.filter(\.isVideo).count } }

    /// 跨目录取最近的 4 张做封面拼贴
    var coverAssets: [Asset] {
        Self.newest(4, in: folders.lazy.flatMap(\.assets))
    }

    /// 取最近的 n 个，不把整个集合排一遍。
    ///
    /// 原来是 flatMap 成一个新数组、整个排序、再取前四个。一个五千张照片的
    /// 分组，画一次封面就要拷五千个结构体再排一遍序，只为拿四张出来——
    /// 而首页上每个分组卡片都要来这么一次，每次刷新都重算。
    ///
    /// 换成边走边留前 n 名。n 是 4，所以里面那个 firstIndex 最多比四次；
    /// 绝大多数元素在第一个 if 就被挡掉了，一次比较都不用。
    static func newest(_ n: Int, in assets: some Sequence<Asset>) -> [Asset] {
        guard n > 0 else { return [] }
        var best: [Asset] = []
        best.reserveCapacity(n + 1)
        for a in assets {
            if best.count == n, a.createdAt <= best[n - 1].createdAt { continue }
            let at = best.firstIndex { a.createdAt > $0.createdAt } ?? best.count
            best.insert(a, at: at)
            if best.count > n { best.removeLast() }
        }
        return best
    }
}

// MARK: - 目录树

extension PhotoGroup {

    /// 直接挂在分组下的目录
    var rootFolders: [Folder] { folders.filter { $0.parentID == nil } }

    func children(of folderID: UUID) -> [Folder] {
        folders.filter { $0.parentID == folderID }
    }

    /// 目录自己 + 所有子孙。删除、计数、判断循环都用它。
    func subtree(of folderID: UUID) -> [Folder] {
        var result: [Folder] = []
        var pending = folders.filter { $0.id == folderID }
        while let node = pending.popLast() {
            result.append(node)
            pending.append(contentsOf: folders.filter { $0.parentID == node.id })
        }
        return result
    }

    /// 含子目录的照片数
    func totalPhotoCount(in folderID: UUID) -> Int {
        subtree(of: folderID).reduce(0) { $0 + $1.assets.count }
    }

    /// 含子目录的子目录数（不含自己）
    func totalFolderCount(in folderID: UUID) -> Int {
        max(0, subtree(of: folderID).count - 1)
    }

    /// 目录封面：自己没图就往子目录里找，否则空目录套满图的子目录会显示成空的
    func coverAssets(for folderID: UUID) -> [Asset] {
        let all = subtree(of: folderID).flatMap(\.assets).sorted { $0.createdAt > $1.createdAt }
        return Array(all.prefix(4))
    }

    /// 一个目录的汇总：含子目录在内的照片数、子目录数、封面。
    ///
    /// covers 留四个而不是一个：分组卡片的四宫格还要用。目录卡片只取第一张，
    /// 多留三个的成本就是几个结构体，比为两处各走一遍子树便宜。
    struct FolderSummary {
        var photos = 0
        var subfolders = 0
        var covers: [Asset] = []
    }

    /// 一次把整组每个目录的汇总都算出来。
    ///
    /// 原来是每张目录卡片各算各的，而且一张卡要算三样：totalPhotoCount、
    /// totalFolderCount、coverAssets。每样都从 subtree 重新走一遍子树，
    /// 而 subtree 自己是 O(目录数²)——它在遍历里对整个 folders 数组做 filter。
    /// coverAssets 还要把子树里所有照片 flatMap 成新数组再整个排序，
    /// 只为取前四张。一个五十个目录、五千张照片的分组，画一屏就是几十万次
    /// 结构体拷贝加上几十次全量排序，划一下就卡。
    ///
    /// 换成自底向上走一遍：先按 parentID 建索引，再从叶子往上累加。
    /// 整组一次 O(目录数 + 照片数)，视图算一次传给所有卡片。
    ///
    /// 封面能这样往上并，是因为子树里最新的四张一定在「自己最新的四张」和
    /// 「每个子目录最新的四张」这些候选里——不可能有第五名混进最终的前四。
    func folderSummaries() -> [UUID: FolderSummary] {
        var byID: [UUID: Folder] = [:]
        var children: [UUID: [UUID]] = [:]
        byID.reserveCapacity(folders.count)
        for f in folders {
            byID[f.id] = f
            if let parent = f.parentID { children[parent, default: []].append(f.id) }
        }

        var out: [UUID: FolderSummary] = [:]
        out.reserveCapacity(folders.count)
        var visited = Set<UUID>()

        // 迭代式后序遍历：先把子目录算完，再回来算自己。
        //
        // 不用递归——目录层级是人随便建的，深一点就有撑爆栈的风险。
        // visited 顺带把环挡住了：数据万一坏成环，这里只是算得不准，
        // 而原来那个 subtree 碰上环会一直转下去，界面直接死住。
        for root in folders.map(\.id) where !visited.contains(root) {
            var stack: [(id: UUID, done: Bool)] = [(root, false)]
            while let top = stack.popLast() {
                guard top.done else {
                    guard visited.insert(top.id).inserted else { continue }
                    stack.append((top.id, true))
                    for child in children[top.id] ?? [] where !visited.contains(child) {
                        stack.append((child, false))
                    }
                    continue
                }
                guard let folder = byID[top.id] else { continue }
                var summary = FolderSummary(photos: folder.assets.count,
                                            subfolders: 0,
                                            covers: Self.newest(4, in: folder.assets))
                for child in children[top.id] ?? [] {
                    guard let sub = out[child] else { continue }
                    summary.photos += sub.photos
                    summary.subfolders += sub.subfolders + 1
                    summary.covers = Self.newest(4, in: summary.covers + sub.covers)
                }
                out[top.id] = summary
            }
        }
        return out
    }

    /// 从分组根到该目录的一串目录，做面包屑用
    func path(to folderID: UUID) -> [Folder] {
        var chain: [Folder] = []
        var cursor = folders.first { $0.id == folderID }
        // 万一数据坏了成了环，用步数兜底，别把界面卡死
        var guardCount = 0
        while let node = cursor, guardCount < 64 {
            chain.append(node)
            cursor = node.parentID.flatMap { pid in folders.first { $0.id == pid } }
            guardCount += 1
        }
        return chain.reversed()
    }
}

// MARK: - 排序

enum SortMode: String, Codable, CaseIterable, Identifiable {
    case manual
    case nameAsc
    case nameDesc
    case newest
    case oldest
    case countDesc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual:    return "自定义顺序"
        case .nameAsc:   return "名称 A → Z"
        case .nameDesc:  return "名称 Z → A"
        case .newest:    return "创建时间（新→旧）"
        case .oldest:    return "创建时间（旧→新）"
        case .countDesc: return "照片数量（多→少）"
        }
    }

    var icon: String {
        switch self {
        case .manual:    return "hand.draw"
        case .nameAsc:   return "textformat.abc"
        case .nameDesc:  return "textformat.abc"
        case .newest:    return "clock"
        case .oldest:    return "clock.arrow.circlepath"
        case .countDesc: return "photo.stack"
        }
    }
}

// MARK: - 外观

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    /// 只用在菜单行里。菜单行没有圆形底，所以可以放心用最标准的那套图标，
    /// 圆环字形在这里不会变成「圆套圆」。
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// 用 UIKit 的 overrideUserInterfaceStyle 而不是 SwiftUI 的 preferredColorScheme：
    /// 后者一旦设过非 nil 值，再设回 nil 并不会恢复成跟随系统，
    /// 只有 .unspecified 能真正还原。
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    @MainActor
    func apply() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }
}

// MARK: - 持久化根对象

struct Library: Codable {
    var groups: [PhotoGroup] = []
    var groupSort: SortMode = .manual
    var folderSort: SortMode = .manual
    var appearance: AppTheme = .system

    enum CodingKeys: String, CodingKey {
        case groups, groupSort, folderSort, appearance
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([PhotoGroup].self, forKey: .groups) ?? []
        groupSort = try c.decodeIfPresent(SortMode.self, forKey: .groupSort) ?? .manual
        folderSort = try c.decodeIfPresent(SortMode.self, forKey: .folderSort) ?? .manual
        appearance = try c.decodeIfPresent(AppTheme.self, forKey: .appearance) ?? .system
    }
}

// MARK: - 排序应用

extension Array where Element == PhotoGroup {
    func sorted(by mode: SortMode) -> [PhotoGroup] {
        switch mode {
        case .manual:    return self
        case .nameAsc:   return sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDesc:  return sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .newest:    return sorted { $0.createdAt > $1.createdAt }
        case .oldest:    return sorted { $0.createdAt < $1.createdAt }
        case .countDesc: return sorted { $0.photoCount > $1.photoCount }
        }
    }
}

extension Array where Element == Folder {
    func sorted(by mode: SortMode) -> [Folder] {
        switch mode {
        case .manual:    return self
        case .nameAsc:   return sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDesc:  return sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .newest:    return sorted { $0.createdAt > $1.createdAt }
        case .oldest:    return sorted { $0.createdAt < $1.createdAt }
        case .countDesc: return sorted { $0.assets.count > $1.assets.count }
        }
    }
}
