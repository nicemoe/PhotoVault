import Foundation
import SwiftUI

// MARK: - 书

enum BookFormat: String, Codable {
    case txt
    case epub

    var label: String {
        switch self {
        case .txt:  return "TXT"
        case .epub: return "EPUB"
        }
    }
}

/// 章节元信息。正文单独存盘，这里只留标题和字数，
/// 否则一本长篇的全文会一直挂在内存里。
struct ChapterMeta: Identifiable, Codable, Hashable {
    var id = UUID()
    var index: Int
    var title: String
    var characterCount: Int
}

/// 阅读进度。
///
/// 存「章节 + 章内字符偏移」而不是页码：页码会随字号、行距、屏幕尺寸、
/// 翻页/滚动模式变化，字符偏移不会，换任何设置都能回到原来那句话。
struct ReadingProgress: Codable, Hashable {
    var chapterIndex: Int = 0
    var characterOffset: Int = 0
    var updatedAt: Date = Date()
}

/// 书签。存章节 + 章内字符偏移，和阅读进度同一套定位方式，
/// 所以改字号、换翻页模式之后依然能跳回原来那句话。
struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var chapterIndex: Int
    var characterOffset: Int
    var chapterTitle: String
    /// 书签处的开头几十个字，方便在列表里认出来
    var snippet: String
    var createdAt: Date = Date()
}

struct Book: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    /// 这本书在 Books/ 下的目录叫什么。
    ///
    /// 不直接拿 title 当目录名：书名可以重复、可以带 / : * 这些文件系统不认的
    /// 字符。这里存一份洗过、且和别的书不重名的，改书名时一起更新并把磁盘上的
    /// 目录搬过去。空串表示还没分配（旧数据），加载时补。
    var dirName: String = ""
    /// 原文件在「书库」下的文件名。
    ///
    /// 拆成章节之后原文件是留着的：能原样导出、分章逻辑改进了能拿它重拆、
    /// 章节文件坏了也能重建。空串表示这本书是老版本导进来的，那会儿原文件
    /// 拆完就删了，找不回来。
    var sourceName: String = ""
    var author: String = ""
    var format: BookFormat
    var addedAt: Date = Date()
    var chapters: [ChapterMeta] = []
    var totalCharacters: Int = 0
    var progress = ReadingProgress()
    /// 封面色，按书名哈希取，避免每本书都长一样
    var colorIndex: Int = 0
    var bookmarks: [Bookmark] = []

    init(id: UUID = UUID(), title: String, dirName: String = "",
         sourceName: String = "", author: String = "", format: BookFormat,
         addedAt: Date = Date(), chapters: [ChapterMeta] = [], totalCharacters: Int = 0,
         progress: ReadingProgress = ReadingProgress(), colorIndex: Int = 0,
         bookmarks: [Bookmark] = []) {
        self.id = id
        self.title = title
        self.dirName = dirName
        self.sourceName = sourceName
        self.author = author
        self.format = format
        self.addedAt = addedAt
        self.chapters = chapters
        self.totalCharacters = totalCharacters
        self.progress = progress
        self.colorIndex = colorIndex
        self.bookmarks = bookmarks
    }

    /// 手写解码，全部 decodeIfPresent。
    /// Swift 合成的 Decodable 不拿属性默认值兜缺失的键，直接抛错——
    /// 那样每加一个字段，旧的 books.json 就解不出来，整个书架会被清空。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "未命名"
        dirName = try c.decodeIfPresent(String.self, forKey: .dirName) ?? ""
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        format = try c.decodeIfPresent(BookFormat.self, forKey: .format) ?? .txt
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        chapters = try c.decodeIfPresent([ChapterMeta].self, forKey: .chapters) ?? []
        totalCharacters = try c.decodeIfPresent(Int.self, forKey: .totalCharacters) ?? 0
        progress = try c.decodeIfPresent(ReadingProgress.self, forKey: .progress) ?? ReadingProgress()
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
    }

    var chapterCount: Int { chapters.count }

    /// 0...1
    var progressRatio: Double {
        guard totalCharacters > 0 else { return 0 }
        let before = chapters.prefix(progress.chapterIndex).reduce(0) { $0 + $1.characterCount }
        return min(1, Double(before + progress.characterOffset) / Double(totalCharacters))
    }

    var progressText: String {
        guard !chapters.isEmpty else { return "未开始" }
        if progressRatio <= 0 { return "未开始" }
        return String(format: "已读 %.0f%%", progressRatio * 100)
    }

    var currentChapterTitle: String {
        guard chapters.indices.contains(progress.chapterIndex) else { return "" }
        return chapters[progress.chapterIndex].title
    }
}

// MARK: - 阅读设置

enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case paper      // 米白
    case eyecare    // 护眼绿
    case sepia      // 羊皮纸
    case gray       // 灰
    case night      // 夜间

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper:   return "白"
        case .eyecare: return "绿"
        case .sepia:   return "黄"
        case .gray:    return "灰"
        case .night:   return "夜"
        }
    }

    var background: Color {
        switch self {
        case .paper:   return Color(hex: 0xFBFBF9)
        case .eyecare: return Color(hex: 0xCCE8CF)
        case .sepia:   return Color(hex: 0xF5EBD9)
        case .gray:    return Color(hex: 0xCFD1CE)
        case .night:   return Color(hex: 0x121316)
        }
    }

    var text: Color {
        switch self {
        case .night: return Color(hex: 0x9AA0A8)
        default:     return Color(hex: 0x2B2A28)
        }
    }

    /// 工具栏等次要元素
    var secondary: Color {
        switch self {
        case .night: return Color(hex: 0x6B7079)
        default:     return Color(hex: 0x8A8781)
        }
    }

    var isDark: Bool { self == .night }
}

enum ReaderFont: String, Codable, CaseIterable, Identifiable {
    case system
    case serif
    case rounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:  return "系统"
        case .serif:   return "宋体"
        case .rounded: return "圆体"
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .system:
            return .systemFont(ofSize: size)
        case .serif:
            let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
                .withDesign(.serif) ?? UIFont.systemFont(ofSize: size).fontDescriptor
            return UIFont(descriptor: descriptor, size: size)
        case .rounded:
            let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
                .withDesign(.rounded) ?? UIFont.systemFont(ofSize: size).fontDescriptor
            return UIFont(descriptor: descriptor, size: size)
        }
    }
}

enum ReadingMode: String, Codable, CaseIterable, Identifiable {
    case paged      // 点击左右翻页
    case scroll     // 上下滚动

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paged:  return "翻页"
        case .scroll: return "滚动"
        }
    }

    var icon: String {
        switch self {
        case .paged:  return "book"
        case .scroll: return "arrow.up.arrow.down"
        }
    }
}

/// 翻页效果。
///
/// 仿真卷曲交给系统的 UIPageViewController(.pageCurl)——它是硬件加速的，
/// 而且能跟手拖出卷角，自己用 SwiftUI 画不出这个效果。
enum PageAnimation: String, Codable, CaseIterable, Identifiable {
    case curl
    case slide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curl:  return "仿真"
        case .slide: return "平移"
        }
    }

    var transitionStyle: UIPageViewController.TransitionStyle {
        switch self {
        case .curl:  return .pageCurl
        case .slide: return .scroll
        }
    }
}

/// 书架的展示方式
enum ShelfLayout: String, Codable, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "卡片"
        case .list: return "列表"
        }
    }

    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

struct ReaderSettings: Codable, Hashable {
    var fontSize: Double = 19
    var lineSpacing: Double = 9
    var margin: Double = 22
    var font: ReaderFont = .system
    var theme: ReaderTheme = .paper
    var mode: ReadingMode = .paged
    var pageAnimation: PageAnimation = .curl
    /// 自动翻页的间隔（秒）
    var autoFlipInterval: Double = 8
    /// 阅读时的屏幕亮度。nil = 跟随系统，不去动它。
    var brightness: Double?

    static let fontSizeRange: ClosedRange<Double> = 13...30
    static let lineSpacingRange: ClosedRange<Double> = 2...20
    static let autoFlipRange: ClosedRange<Double> = 3...30

    init() {}

    /// 必须手写解码，全部用 decodeIfPresent 兜默认值。
    ///
    /// Swift 合成的 Decodable 不会拿属性默认值当缺失时的兜底——键不在就直接抛错。
    /// 那样每加一个新设置字段，旧的 books.json 都会解码失败，
    /// 连带整个 BookIndex 解不出来，用户的书架会被清空。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 19
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 9
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 22
        font = try c.decodeIfPresent(ReaderFont.self, forKey: .font) ?? .system
        theme = try c.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? .paper
        mode = try c.decodeIfPresent(ReadingMode.self, forKey: .mode) ?? .paged
        pageAnimation = try c.decodeIfPresent(PageAnimation.self, forKey: .pageAnimation) ?? .curl
        autoFlipInterval = try c.decodeIfPresent(Double.self, forKey: .autoFlipInterval) ?? 8
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness)
    }
}
