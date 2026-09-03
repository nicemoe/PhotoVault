import Foundation
import SwiftUI   // AppTheme 要用 ColorScheme

// MARK: - 图片

struct Asset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// 存放在 Documents/Media/ 下的文件名
    var fileName: String
    var width: Int = 0
    var height: Int = 0
    var byteCount: Int = 0
    var createdAt: Date = Date()

    var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }
}

// MARK: - 目录（分组下的一层）

struct Folder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var assets: [Asset] = []

    var photoCount: Int { assets.count }
    /// 封面用最近加入的几张
    var coverAssets: [Asset] { Array(assets.suffix(4).reversed()) }
}

// MARK: - 分组（首页一层）

struct PhotoGroup: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorIndex: Int = 0
    var createdAt: Date = Date()
    var folders: [Folder] = []

    var folderCount: Int { folders.count }
    var photoCount: Int { folders.reduce(0) { $0 + $1.assets.count } }

    /// 跨目录取最近的 4 张做封面拼贴
    var coverAssets: [Asset] {
        let all = folders.flatMap(\.assets).sorted { $0.createdAt > $1.createdAt }
        return Array(all.prefix(4))
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

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// nil 表示交给系统决定
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
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
