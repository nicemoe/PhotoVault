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
    @State private var loaded: Bool

    /// 建视图的时候就先问一次内存缓存。
    ///
    /// 原来一律等 .task 起来了才问：哪怕图早就在缓存里，也要先画一遍灰底、
    /// 排一个任务、下一拍再把图塞进去重画一遍——每张图两次渲染加一次任务
    /// 调度。目录网格一格四张图，往下滑每冒出一行就要付八次，
    /// 「渲染出来很多小图」的时候那一顿就是这么来的。
    ///
    /// 命中缓存的话第一帧就带着图，任务里直接返回，一次渲染搞定。
    /// 这个查询是一次 NSCache 取值，比它省下的那次渲染便宜得多。
    init(asset: Asset, maxPixel: Int = 480, contentMode: ContentMode = .fill) {
        self.asset = asset
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        let hit = ThumbnailCache.shared.cached(asset, maxPixel: maxPixel)
        _image = State(initialValue: hit)
        _loaded = State(initialValue: hit != nil)
    }

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
                    // 多半在 init 里就已经放进来了。同一张就别再赋一次值——
                    // @State 不比较新旧，赋了就是一次白刷新。
                    if image !== hit { image = hit }
                    if !loaded { loaded = true }
                    return
                }
                // 走到这儿说明缓存里没有。手上还留着图的话，是这个格子被换给了
                // 另一张（.task 的 id 变了），旧的那张不作数了。
                if image != nil {
                    image = nil
                    loaded = false
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

    /// 不用 GeometryReader。
    ///
    /// 原来整个拼贴套在 GeometryReader 里，靠量出来的宽高算每一格的尺寸。
    /// 在 LazyVGrid 里这是笔白付的开销：GeometryReader 不给子视图提议尺寸，
    /// 父容器得再走一轮布局才定得下来，而目录网格每滑出一行就要新建一批格子，
    /// 每个格子都付一次。资产网格一个格子就一张图、没有 GeometryReader，
    /// 所以滑起来顺——「目录那层卡、点进去看视频不卡」的差别就在这儿。
    ///
    /// 外面已经用 aspectRatio 把容器摁成正方形了，里面要的只是「均分」，
    /// 交给 maxWidth / maxHeight: .infinity 就够，不需要知道具体多少点。
    var body: some View {
        Group {
            switch assets.count {
            case 0:
                Image(systemName: emptyIcon)
                    .resizable()
                    .scaledToFit()
                    // 相当于原来那句「边长的 26%」，只是不用去问边长
                    .scaleEffect(0.3)
                    .foregroundStyle(tint.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint.opacity(0.12))
            case 1:
                AssetImage(asset: assets[0], maxPixel: maxPixel)
            case 2:
                HStack(spacing: gap) {
                    AssetImage(asset: assets[0], maxPixel: maxPixel).frame(maxWidth: .infinity)
                    AssetImage(asset: assets[1], maxPixel: maxPixel).frame(maxWidth: .infinity)
                }
            case 3:
                // 原来大图占 62%，那个比例非得量出宽度才算得了。
                // 改成对半分：省掉那轮布局，看着也更规整。
                HStack(spacing: gap) {
                    AssetImage(asset: assets[0], maxPixel: maxPixel)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: gap) {
                        AssetImage(asset: assets[1], maxPixel: 256).frame(maxHeight: .infinity)
                        AssetImage(asset: assets[2], maxPixel: 256).frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                }
            default:
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        AssetImage(asset: assets[0], maxPixel: 256).frame(maxWidth: .infinity)
                        AssetImage(asset: assets[1], maxPixel: 256).frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                    HStack(spacing: gap) {
                        AssetImage(asset: assets[2], maxPixel: 256).frame(maxWidth: .infinity)
                        AssetImage(asset: assets[3], maxPixel: 256).frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity)
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
                // 高度直接给死，不靠 aspectRatio 去谈。
                //
                // 拼贴里全是 Color 打底的图片位，整棵子树没有固有尺寸，
                // 这时候让 aspectRatio 把它摁成正方形，要多走一轮尺寸协商，
                // 而 LazyVGrid 每滑出一行都要新建一批格子，每格都付一次。
                // side 本来就是按列宽算好的，用它就完了。
                .frame(height: side)
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

    let folder: Folder
    /// 子目录数、含子目录的总张数、封面。由列表一次算好整组的再分发下来。
    ///
    /// 原来是卡片自己去 store 问，一张卡问三次，每次都从头走一遍子树——
    /// 而 subtree 是 O(目录数²)。一屏几十张卡就是几十万次结构体拷贝，
    /// 划一下就卡。这几个数本来就只有列表那一层能一次算完。
    let summary: PhotoGroup.FolderSummary
    let side: CGFloat
    var tint: Color = Theme.accent

    private var subfolderCount: Int { summary.subfolders }
    private var totalPhotos: Int { summary.photos }

    /// 有子目录时说清楚「本目录 N 张」和「一共 M 张」，
    /// 否则一个只放子目录的空壳目录会显示成「0 张照片」，看着像坏了
    private var caption: String {
        guard subfolderCount > 0 else { return "\(folder.photoCount) 张照片" }
        return "\(subfolderCount) 个子目录 · 共 \(totalPhotos) 张"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 目录封面只用一张。
            //
            // 原来是四宫格。目录里全是视频的时候，那意味着每个目录要抽四次帧，
            // 而抽一帧是开一个解码器解一帧出来，一百到三百毫秒——一屏十来张
            // 卡片就是四五十次。抽帧、解码、视图数、状态更新，全都是四倍。
            //
            // 卡片本身才一百七十点宽，四宫格每格八十来点，本来也看不出什么。
            // 换成单张：那四样开销一起砍到四分之一，图还更看得清。
            // 背后露出一层，看着像叠着的一摞。
            //
            // 封面从四宫格改成单张之后，卡片一眼看上去和一张照片没区别了。
            // 「这是一摞不是一张」得靠形状说，角标太小、要盯着才看得见——
            // 而人是先看到形状的。
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                    .fill(tint.opacity(0.28))
                    .frame(height: side)
                    .padding(.horizontal, 11)
                    .offset(y: -6)

                CoverCollage(assets: Array(summary.covers.prefix(1)), tint: tint, emptyIcon: "folder")
                    .frame(maxWidth: .infinity)
                    // 高度直接给死，不靠 aspectRatio 去谈。
                    //
                    // 拼贴里全是 Color 打底的图片位，整棵子树没有固有尺寸，
                    // 这时候让 aspectRatio 把它摁成正方形，要多走一轮尺寸协商，
                    // 而 LazyVGrid 每滑出一行都要新建一批格子，每格都付一次。
                    // side 本来就是按列宽算好的，用它就完了。
                    .frame(height: side)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover,
                                                style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        // 角标一律给。原来只在「有子目录」时才出现，于是末端那些
                        // 只装文件的目录反倒没有任何标记——而恰恰是它们最容易被
                        // 当成一张照片。
                        Image(systemName: subfolderCount > 0 ? "folder.fill" : "square.stack.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.4), in: Circle())
                            .padding(8)
                    }
            }
            // 给背后露出的那一条留位置
            .padding(.top, 6)

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
