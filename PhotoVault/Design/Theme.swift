import SwiftUI

// MARK: - 颜色工具

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// 亮/暗两套色值，随系统外观自动切换
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rgbHex: dark)
                : UIColor(rgbHex: light)
        })
    }
}

extension UIColor {
    convenience init(rgbHex: UInt32) {
        self.init(
            red: CGFloat((rgbHex >> 16) & 0xFF) / 255,
            green: CGFloat((rgbHex >> 8) & 0xFF) / 255,
            blue: CGFloat(rgbHex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 设计令牌

enum Theme {

    // 品牌主色
    static let accent = Color(light: 0x2F6FED, dark: 0x5B8DFF)

    // 背景层级：底 → 卡片 → 抬升
    static let background = Color(light: 0xF4F5F7, dark: 0x0E1014)
    static let surface = Color(light: 0xFFFFFF, dark: 0x191C22)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x22262E)
    static let fill = Color(light: 0xEBEDF1, dark: 0x22262E)

    // 文本
    static let label = Color(light: 0x12141A, dark: 0xF2F4F8)
    static let secondaryLabel = Color(light: 0x767E90, dark: 0x8B93A6)
    static let tertiaryLabel = Color(light: 0xA5ACBA, dark: 0x646C7D)

    // 扁平风格用极细描边代替阴影
    static let hairline = Color(light: 0xE4E7EC, dark: 0x2A2F39)

    static let danger = Color(light: 0xE8453C, dark: 0xFF6B60)

    // MARK: 全屏预览
    //
    // 预览页不要写死黑色：浅色主题下四周应该是白的，否则和整个 App 割裂。

    /// 图片四周的底色
    static let viewerBackground = Color(light: 0xFFFFFF, dark: 0x000000)
    /// 预览页上的图标和文字。
    /// 浅色下不用接近纯黑：预览页整片留白，纯黑控件显得很重，
    /// 中性灰既压得住又不抢照片。
    static let viewerLabel = Color(light: 0x5A6172, dark: 0xFFFFFF)
    /// 预览页上圆形按钮的底
    static let viewerControl = Color(light: 0x000000, dark: 0xFFFFFF)

    // MARK: 圆角

    enum Radius {
        static let card: CGFloat = 22
        static let cover: CGFloat = 18
        static let tile: CGFloat = 12
        static let chip: CGFloat = 10
        static let button: CGFloat = 14
    }

    enum Metric {
        /// 屏幕左右安全边距（Pro Max 宽屏下留 20 更舒展）
        static let margin: CGFloat = 20
        static let cardGap: CGFloat = 14
        static let photoGap: CGFloat = 4
    }

    // MARK: 分组配色（扁平实色）

    static let paletteHex: [UInt32] = [
        0xFF6B6B,   // 珊瑚
        0xFF922B,   // 橙
        0xFCC419,   // 黄
        0x51CF66,   // 绿
        0x22B8CF,   // 青
        0x4C6EF5,   // 蓝
        0x845EF7,   // 紫
        0xF06595    // 粉
    ]

    static let palette: [Color] = paletteHex.map { Color(hex: $0) }

    private static func normalized(_ index: Int) -> Int {
        ((index % paletteHex.count) + paletteHex.count) % paletteHex.count
    }

    static func color(at index: Int) -> Color {
        palette[normalized(index)]
    }

    /// 给网页端用的 #RRGGBB
    static func cssColor(at index: Int) -> String {
        String(format: "#%06X", paletteHex[normalized(index)])
    }
}

// MARK: - 通用修饰符

/// 扁平卡片：实色底 + 1px 描边，不用阴影
struct FlatCard: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    var padding: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func flatCard(radius: CGFloat = Theme.Radius.card, padding: CGFloat = 0) -> some View {
        modifier(FlatCard(radius: radius, padding: padding))
    }

    /// 让整块区域可点击（包括透明部分）
    func tappableArea() -> some View {
        contentShape(Rectangle())
    }
}

/// 导航栏上的圆形图标外观。
/// 直接作用在 label 上而不是用 ButtonStyle —— Menu 不保证把 buttonStyle 传给它的 label。
///
/// 字号按字形单独给，不要所有图标共用一个值：SF Symbols 的 size 约等于字高，
/// 宽度却随字形变化很大。arrow.up.arrow.down 是左右并排的两个箭头，
/// 同字号下比 plus 宽约一半，共用字号就会显得要撑破圆底。
struct CircleIconLook: ViewModifier {
    var glyphSize: CGFloat
    /// 可视圆直径
    var diameter: CGFloat = 30
    /// 触摸区域，比可视圆大一圈，避免圆变小之后不好点。
    /// 相邻两个按钮用 HStack(spacing: 0) 摆放时，可视圆之间的间距就等于
    /// hitSize - diameter = 8pt，不用再另外调 spacing。
    var hitSize: CGFloat = 38

    func body(content: Content) -> some View {
        content
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: diameter, height: diameter)
            .background(Theme.accent.opacity(0.12), in: Circle())
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
    }
}

extension View {
    /// - Parameter glyph: 字形点数。窄字形（plus、checkmark）用 14，
    ///   宽字形（arrow.up.arrow.down）用 11.5 才能和窄字形看起来一样重。
    func circleIcon(glyph: CGFloat = 14) -> some View {
        modifier(CircleIconLook(glyphSize: glyph))
    }
}

/// 主要操作按钮：实色块、无渐变
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(tint.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
    }
}

/// 次要操作按钮：填充灰块
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.label)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Theme.fill.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
    }
}

/// 轻微缩放的按压反馈，用于卡片
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
