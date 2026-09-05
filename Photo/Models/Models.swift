import Foundation
import UIKit   // AppTheme 要用 UIUserInterfaceStyle

// MARK: - 图片

enum AssetKind: String, Codable, Hashable {
    case image
    case video
}

struct Asset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// 存放在 Documents/Media/ 下的文件名
    var fileName: String
    var kind: AssetKind = .image
    var width: Int = 0
    var height: Int = 0
    var byteCount: Int = 0
    /// 视频时长（秒）；图片是 0
    var duration: Double = 0
    var createdAt: Date = Date()

    init(id: UUID = UUID(), fileName: String, kind: AssetKind = .image,
         width: Int = 0, height: Int = 0, byteCount: Int = 0,
         duration: Double = 0, createdAt: Date = Date()) {
        self.id = id
        self.fileName = fileName
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
        kind = try c.decodeIfPresent(AssetKind.self, forKey: .kind) ?? .image
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    var isVideo: Bool { kind == .video }

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
    var createdAt: Date = Date()
    var assets: [Asset] = []

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil,
         createdAt: Date = Date(), assets: [Asset] = []) {
        self.id = id
        self.name = name
        self.parentID = parentID
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
    var createdAt: Date = Date()
    var folders: [Folder] = []

    /// 含所有层级
    var folderCount: Int { folders.count }
    var photoCount: Int { folders.reduce(0) { $0 + $1.assets.count } }

    /// 跨目录取最近的 4 张做封面拼贴
    var coverAssets: [Asset] {
        let all = folders.flatMap(\.assets).sorted { $0.createdAt > $1.createdAt }
        return Array(all.prefix(4))
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
