import SwiftUI

// MARK: - 宽度测量
//
// LazyVGrid 里用 .aspectRatio 让无固有尺寸的视图变成正方形，
// 依赖 SwiftUI 对「高度未指定」提案的处理，结果不够确定。
// 这里直接量出可用宽度，自己算格子边长，布局就完全可控了。

struct WidthReader: ViewModifier {
    @Binding var width: CGFloat

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in width = newValue }
            }
        }
    }
}

extension View {
    func readingWidth(_ width: Binding<CGFloat>) -> some View {
        modifier(WidthReader(width: width))
    }
}

enum ScreenMetrics {
    /// 还没量到容器宽度时的兜底值。
    ///
    /// 绝对不要用「量到宽度」当渲染开关：内容不渲染 → ScrollView 没内容 →
    /// 背景里的 GeometryReader 量到 0 → 内容继续不渲染，直接死锁成白屏。
    /// 宁可先按兜底宽度画一帧，量准了再自动纠正。
    @MainActor
    static var fallbackWidth: CGFloat {
        let width = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.bounds.width }
            .first
        return width ?? 393
    }
}

/// 由容器宽度推出卡片网格的列数与边长
struct CardGridLayout {
    var columnCount: Int
    /// 单元格的估算边长，只用来给缩略图挑分辨率，不用来定尺寸
    var side: CGFloat
    var columns: [GridItem]

    /// - Parameter preferredItemWidth: 单个卡片的理想宽度，用来决定列数
    init(contentWidth: CGFloat, gap: CGFloat, preferredItemWidth: CGFloat, minimumColumns: Int = 2) {
        let count = max(minimumColumns, Int((contentWidth + gap) / (preferredItemWidth + gap)))
        self.init(contentWidth: contentWidth, gap: gap, fixedColumns: count)
    }

    /// 固定列数（照片墙用）
    init(contentWidth: CGFloat, gap: CGFloat, fixedColumns: Int) {
        let count = max(1, fixedColumns)
        let total = contentWidth - gap * CGFloat(count - 1)
        columnCount = count
        side = max(1, total / CGFloat(count))
        columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: count)
    }
}

// MARK: - 空状态

struct EmptyState: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            // 一个大加号，不做成按钮：上面的文字已经说清楚要干什么了，
            // 再套一个写着同样话的方块只是把一句话说两遍。
            if let action {
                Button(action: action) {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(actionTitle ?? "添加")
            }
        }
        .padding(.horizontal, 40)
        // 撑出一块高度再居中，文字和加号才落在这块空白的正中，
        // 而不是贴着上一块内容
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .center)
    }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    var icon: String
    var text: String
}

struct ToastOverlay: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 9) {
                    Image(systemName: toast.icon)
                        .font(.system(size: 14, weight: .semibold))
                    Text(toast.text)
                        .font(.system(size: 14.5, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color(light: 0x1B1F27, dark: 0x2C313B), in: Capsule())
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        self.toast = nil
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toast)
    }
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View {
        modifier(ToastOverlay(toast: toast))
    }
}
