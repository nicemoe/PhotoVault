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

struct Book: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var author: String = ""
    var format: BookFormat
    var addedAt: Date = Date()
    var chapters: [ChapterMeta] = []
    var totalCharacters: Int = 0
    var progress = ReadingProgress()
    /// 封面色，按书名哈希取，避免每本书都长一样
    var colorIndex: Int = 0

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

struct ReaderSettings: Codable, Hashable {
    var fontSize: Double = 19
    var lineSpacing: Double = 9
    var margin: Double = 22
    var font: ReaderFont = .system
    var theme: ReaderTheme = .paper
    var mode: ReadingMode = .paged
    /// 段首缩进两个字
    var firstLineIndent: Bool = true

    static let fontSizeRange: ClosedRange<Double> = 13...30
    static let lineSpacingRange: ClosedRange<Double> = 2...20
}
