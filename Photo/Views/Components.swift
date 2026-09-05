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

/// 由容器宽度推出卡片网格的列数。
///
/// 列宽用 .flexible 而不是 .fixed —— 这是关键。
/// 用 .fixed 的话，列宽是拿「量到的容器宽度」算出来的一个死数；测量值只要
/// 一过时（转屏、分屏、任何让容器变宽又变窄的操作），网格就会按旧宽度排，
/// 内容整片挤出屏幕。.flexible 让每列自己填满实际容器，列数算多算少都只是
/// 疏密不同，不会错位。
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

// MARK: - 异步缩略图

struct AssetImage: View {
    let asset: Asset
    var maxPixel: Int = 480
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        // 用 overlay 而不是 ZStack：填充模式下图片会溢出，
        // overlay 不参与父视图定尺，外层 clipped 才能真正裁掉多出来的部分。
        Theme.fill
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if loaded, asset.isVideo {
                    // 抽不出封面的视频（多半是 iOS 解不了的格式）给个胶片占位，
                    // 不然格子就是一块空灰底，看着像坏了
                    Image(systemName: "film")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.tertiaryLabel)
                }
            }
            .clipped()
            .task(id: asset.id) {
                if let hit = ThumbnailCache.shared.cached(asset, maxPixel: maxPixel) {
                    image = hit
                    loaded = true
                    return
                }
                let made = await ThumbnailCache.shared.thumbnail(for: asset, maxPixel: maxPixel)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { image = made }
                loaded = true
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
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                .overlay(alignment: .topLeading) {
                    // 卡片缩到三列之后这个角标要跟着收，不然占掉封面一大块
                    Circle()
                        .fill(Theme.color(at: group.colorIndex))
                        .frame(width: 8, height: 8)
                        .padding(7)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 20, height: 20)
                        )
                        .padding(6)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                Text("\(group.folderCount) 个目录 · \(group.photoCount) 张")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 7)
        }
    }
}

// MARK: - 目录卡片

struct FolderCard: View {
    @Environment(LibraryStore.self) private var store

    let folder: Folder
    let side: CGFloat
    var tint: Color = Theme.accent

    /// 子目录数和含子目录的总张数
    private var subfolderCount: Int { store.totalFolderCount(in: folder.id) }
    private var totalPhotos: Int { store.totalPhotoCount(in: folder.id) }

    /// 有子目录时说清楚「本目录 N 张」和「一共 M 张」，
    /// 否则一个只放子目录的空壳目录会显示成「0 张照片」，看着像坏了
    private var caption: String {
        guard subfolderCount > 0 else { return "\(folder.photoCount) 张照片" }
        return "\(subfolderCount) 个子目录 · 共 \(totalPhotos) 张"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverCollage(assets: store.coverAssets(for: folder.id), tint: tint, emptyIcon: "folder")
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if subfolderCount > 0 {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.35), in: Circle())
                            .padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 7)
        }
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

            // 一个大加号，不做成按钮：空状态里已经用文字说清楚要干什么了，
            // 再套一个带文案的方块只是把同一句话说两遍。
            if let action {
                Button(action: action) {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .accessibilityLabel(actionTitle ?? "添加")
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 排序菜单

/// 三条杠菜单。各级页面共用：上半部分是本页专属的动作（排序、选择…），
/// 下半部分是全局的外观设置。
///
/// 各级页面右上角一律只有「+」和「三条杠」两个按钮，别的功能都收进来——
/// 排序、多选这些一页一个样，摆在外面会让每层的工具栏都长得不一样。
struct PageMenu<Content: View>: View {

    @Environment(LibraryStore.self) private var store
    @ViewBuilder var content: Content

    var body: some View {
        @Bindable var store = store

        Menu {
            content

            Divider()

            // 外观作为一个条目收在这里，点开才是三个选项。
            // 一级条目直接显示当前选中的值（跟随系统 / 浅色 / 深色），
            // 不要再加「外观」前缀——展开后的对勾已经说明了它是什么。
            Menu {
                Picker("", selection: $store.appearance) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.title, systemImage: theme.icon).tag(theme)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(store.appearance.title, systemImage: store.appearance.icon)
            }
        } label: {
            // 三条杠是自己画的，宽度/线宽/行距各自独立可调，
            // 见 HamburgerIcon 里的说明
            HamburgerIcon().circleIcon()
        }
    }
}

/// 排序条目，放进 PageMenu 里用
struct SortMenuSection: View {
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
            // 和外观那条一样，一级条目直接显示当前选的排序方式
            Label(mode.title, systemImage: mode.icon)
        }
    }
}

// MARK: - 顶部统计条

struct StatBar: View {
    let items: [(String, String)]

    /// 四格时每格只剩八十几点宽，数字大一点就要换行，所以按格数收一收
    private var numberSize: CGFloat { items.count > 3 ? 18 : 20 }
    private var padding: CGFloat { items.count > 3 ? 11 : 14 }

    var body: some View {
        HStack(spacing: items.count > 3 ? 8 : 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0)
                        .font(.system(size: numberSize, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(item.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, padding)
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
