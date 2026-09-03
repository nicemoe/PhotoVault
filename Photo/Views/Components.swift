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
    var side: CGFloat
    var columns: [GridItem]

    /// - Parameter preferredItemWidth: 单个卡片的理想宽度，用来决定列数
    init(contentWidth: CGFloat, gap: CGFloat, preferredItemWidth: CGFloat, minimumColumns: Int = 2) {
        let count = max(minimumColumns, Int((contentWidth + gap) / (preferredItemWidth + gap)))
        let total = contentWidth - gap * CGFloat(count - 1)
        columnCount = count
        side = max(1, total / CGFloat(count))
        columns = Array(repeating: GridItem(.fixed(side), spacing: gap), count: count)
    }

    /// 固定列数（照片墙用）
    init(contentWidth: CGFloat, gap: CGFloat, fixedColumns: Int) {
        let total = contentWidth - gap * CGFloat(fixedColumns - 1)
        columnCount = fixedColumns
        side = max(1, total / CGFloat(fixedColumns))
        columns = Array(repeating: GridItem(.fixed(side), spacing: gap), count: fixedColumns)
    }
}

// MARK: - 异步缩略图

struct AssetImage: View {
    let asset: Asset
    var maxPixel: Int = 480
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        // 用 overlay 而不是 ZStack：填充模式下图片会溢出，
        // overlay 不参与父视图定尺，外层 clipped 才能真正裁掉多出来的部分。
        Theme.fill
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            }
            .clipped()
            .task(id: asset.id) {
                if let hit = ThumbnailCache.shared.cached(asset, maxPixel: maxPixel) {
                    image = hit
                    return
                }
                let loaded = await ThumbnailCache.shared.thumbnail(for: asset, maxPixel: maxPixel)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
            }
    }
}

// MARK: - 封面拼贴

struct CoverCollage: View {
    let assets: [Asset]
    var tint: Color = Theme.accent
    var emptyIcon: String = "photo.on.rectangle.angled"
    var maxPixel: Int = 480

    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            switch assets.count {
            case 0:
                ZStack {
                    tint.opacity(0.12)
                    Image(systemName: emptyIcon)
                        .font(.system(size: min(w, h) * 0.26, weight: .regular))
                        .foregroundStyle(tint.opacity(0.55))
                }
            case 1:
                AssetImage(asset: assets[0], maxPixel: maxPixel)
            case 2:
                HStack(spacing: gap) {
                    AssetImage(asset: assets[0], maxPixel: maxPixel).frame(width: (w - gap) / 2)
                    AssetImage(asset: assets[1], maxPixel: maxPixel).frame(width: (w - gap) / 2)
                }
            case 3:
                HStack(spacing: gap) {
                    AssetImage(asset: assets[0], maxPixel: maxPixel).frame(width: w * 0.62 - gap)
                    VStack(spacing: gap) {
                        AssetImage(asset: assets[1], maxPixel: 320).frame(height: (h - gap) / 2)
                        AssetImage(asset: assets[2], maxPixel: 320).frame(height: (h - gap) / 2)
                    }
                }
            default:
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        AssetImage(asset: assets[0], maxPixel: 320).frame(width: (w - gap) / 2)
                        AssetImage(asset: assets[1], maxPixel: 320).frame(width: (w - gap) / 2)
                    }
                    .frame(height: (h - gap) / 2)
                    HStack(spacing: gap) {
                        AssetImage(asset: assets[2], maxPixel: 320).frame(width: (w - gap) / 2)
                        AssetImage(asset: assets[3], maxPixel: 320).frame(width: (w - gap) / 2)
                    }
                    .frame(height: (h - gap) / 2)
                }
            }
        }
        .background(Theme.fill)
    }
}

// MARK: - 分组卡片

struct GroupCard: View {
    let group: PhotoGroup
    let side: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverCollage(assets: group.coverAssets, tint: Theme.color(at: group.colorIndex))
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(Theme.color(at: group.colorIndex))
                        .frame(width: 10, height: 10)
                        .padding(10)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 26, height: 26)
                        )
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                Text("\(group.folderCount) 个目录 · \(group.photoCount) 张")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
            .padding(.top, 10)
        }
        .frame(width: side)
    }
}

// MARK: - 目录卡片

struct FolderCard: View {
    let folder: Folder
    let side: CGFloat
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverCollage(assets: folder.coverAssets, tint: tint, emptyIcon: "folder")
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                Text("\(folder.photoCount) 张照片")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .frame(width: side, alignment: .leading)
            .padding(.top, 10)
        }
        .frame(width: side)
    }
}

// MARK: - 空状态

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Theme.accent)
            }

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

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 200)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 排序菜单

struct SortMenu: View {
    @Binding var mode: SortMode
    var onManualReorder: () -> Void

    var body: some View {
        Menu {
            Picker("排序方式", selection: $mode) {
                ForEach(SortMode.allCases) { m in
                    Label(m.title, systemImage: m.icon).tag(m)
                }
            }
            Divider()
            Button {
                onManualReorder()
            } label: {
                Label("手动调整顺序…", systemImage: "arrow.up.arrow.down.square")
            }
        } label: {
            // 这个字形是左右并排两个箭头，比 plus 宽得多，字号要相应压小
            Image(systemName: "arrow.up.arrow.down").circleIcon(glyph: 11.5)
        }
    }
}

// MARK: - 顶部统计条

struct StatBar: View {
    let items: [(String, String)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.label)
                    Text(item.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .flatCard(radius: 16)
            }
        }
    }
}

// MARK: - 轻提示

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
