import SwiftUI

struct PhotoViewer: View {

    let assets: [Asset]
    let startIndex: Int
    let folderID: UUID

    /// 幻灯片切换间隔
    private static let slideInterval: Duration = .seconds(5)

    @Environment(LibraryStore.self) private var store
    @Environment(WiFiService.self) private var wifi
    @Environment(\.dismiss) private var dismiss

    // 用 id 而不是下标做 selection：删掉中间某张后下标会整体前移，翻页会串图
    @State private var currentID: UUID?
    @State private var showChrome = true
    @State private var isPlaying = false
    /// 横竖屏切换会把播放页整个重建，用这两个把进度接上
    @State private var resumeAsset: UUID?
    @State private var resumeTime: Double = 0

    init(assets: [Asset], startIndex: Int, folderID: UUID) {
        self.assets = assets
        self.startIndex = startIndex
        self.folderID = folderID
        let first = assets.indices.contains(startIndex) ? assets[startIndex] : assets.first
        _currentID = State(initialValue: first?.id)
        // 视频进来就先把工具栏收起来，别挡着画面；点一下屏幕再出来
        _showChrome = State(initialValue: !(first?.isVideo ?? false))
    }

    /// 过滤掉已经被删掉的。每次访问都要建一次 Set，所以在 body 里只算一次往下传。
    private var liveAssets: [Asset] {
        let existing = Set((store.folder(folderID)?.assets ?? []).map(\.id))
        return assets.filter { existing.contains($0.id) }
    }

    /// 当前这一页的背后是不是深色。
    ///
    /// 视频统一放在黑底上，这时工具栏必须走白色——浅色模式下 viewerLabel 是
    /// 深灰，压在黑底上等于看不见。
    private var onDarkSurface: Bool {
        liveAssets.first { $0.id == currentID }?.isVideo ?? false
    }

    private var controlTint: Color { onDarkSurface ? .white : Theme.viewerLabel }

    var body: some View {
        // 这一层不要 ignoresSafeArea：上下两条栏（关闭、分享、删除）得留在
        // 安全区里，越界的话按钮会被状态栏和 home 指示条压住。
        // 需要全屏铺的是画面本身，那由背景、TabView 和视频页各自声明。
        GeometryReader { proxy in
            viewer(landscape: proxy.size.width > proxy.size.height)
        }
    }

    private func viewer(landscape: Bool) -> some View {
        let live = liveAssets
        let current = live.first { $0.id == currentID } ?? live.first
        let position = live.firstIndex { $0.id == current?.id }
        let landscapeVideo = landscape && onDarkSurface

        return ZStack {
            (onDarkSurface ? Color.black : Theme.viewerBackground).ignoresSafeArea()

            if let asset = current, asset.isVideo {
                // 视频一律不进 TabView，横竖屏都一样。
                //
                // TabView 的分页容器会把页面内容缩小（不传 ignoresSafeArea），
                // 还会裁掉溢出的部分，而且它的翻页手势由内部的 UIScrollView
                // 负责，SwiftUI 压不住——画面铺不满、横拖快进被抢，都出在这儿。
                // 与其一处处去猜是哪层缩了它，不如让视频页直接对着窗口铺。
                // 换上一个/下一个用底部的传输键。
                videoPage(for: asset, in: live)
                    .ignoresSafeArea()
            } else {
                TabView(selection: $currentID) {
                    ForEach(live) { asset in
                        // 单击切换工具栏的手势挂在图片上，不能挂在外层 ZStack：
                        // 挂外层会盖住上下两条栏，把分享、删除这些按钮的点击吞掉。
                        Group {
                            if asset.isVideo {
                                // 只给当前这一页装播放器：TabView 会预建左右相邻页，
                                // 每页都挂一个 AVPlayer 的话会同时开好几路解码
                                videoPage(for: asset, in: live)
                            } else {
                                ZoomableImage(asset: asset) {
                                    withAnimation(.easeOut(duration: 0.2)) { showChrome.toggle() }
                                }
                            }
                        }
                        .tag(Optional(asset.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }

            // 横屏看视频时不再显示上下两条栏：那是全屏播放的姿势，
            // 播放控件由视频页自己出，两套栏叠在一起会互相压住
            // 视频页的上下两条都由播放器自己出：顶栏是标题+画质+倍速+关闭，
            // 底部是进度条和传输键。这里再压一条分享/删除既重复又挡画面，
            // 删除在外面的列表里长按或多选都能做。
            if showChrome, !onDarkSurface {
                VStack {
                    topBar(current)
                    Spacer()
                    bottomBar(total: live.count, position: position)
                }
                .transition(.opacity)
            }
        }
        // 看视频时状态栏一律收起：播放页有自己的顶栏，两条叠着占地方
        .statusBarHidden(!showChrome || onDarkSurface)
        // 幻灯片：isPlaying 变化时 task 重启，停止时自动取消
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.slideInterval)
                guard !Task.isCancelled, isPlaying else { return }
                advance()
            }
        }
        .onChange(of: isPlaying) { _, playing in
            // WiFi 传输也会占用这个开关，关掉时要考虑它还开着的情况
            UIApplication.shared.isIdleTimerDisabled = playing || wifi.isRunning
        }
        .onDisappear {
            isPlaying = false
            UIApplication.shared.isIdleTimerDisabled = wifi.isRunning
            // 退出预览时把方向掰回竖屏，别把整个 App 留在横屏上
            ScreenOrientation.request(landscape: false)
        }
        // initial: true —— 进来时目录就已经空了的话，count 不会再变化，得靠首次求值兜底
        .onChange(of: live.count, initial: true) { _, count in
            if count == 0 { dismiss() }
        }
        // 翻到视频就自动收起工具栏：视频是要看画面的，翻回图片再放出来
        .onChange(of: currentID) { _, id in
            guard let asset = liveAssets.first(where: { $0.id == id }) else { return }
            if asset.isVideo, showChrome {
                withAnimation(.easeOut(duration: 0.2)) { showChrome = false }
            }
        }
    }

    // MARK: 顶栏

    /// 和视频页一个布局：左边标题和尺寸，右边关闭。
    private func topBar(_ asset: Asset?) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: asset))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if let asset {
                    Text("\(asset.width) × \(asset.height) · \(byteText(asset.byteCount))")
                        .font(.system(size: 11.5, weight: .medium))
                        .opacity(0.7)
                }
            }

            Spacer(minLength: 12)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
        }
        .foregroundStyle(controlTint)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// 标题就是导入时的原始文件名。
    /// 拿不到名字的（老数据、少数给不出文件表示的来源）就留空，
    /// 不拿目录名或日期去顶——那看着像文件名其实不是。
    private func title(for asset: Asset?) -> String {
        asset?.originalName ?? ""
    }

    private func videoPage(for asset: Asset, in live: [Asset]) -> some View {
        VideoPage(asset: asset,
                  isCurrent: asset.id == currentID,
                  chromeVisible: showChrome,
                  onSingleTap: { withAnimation(.easeOut(duration: 0.2)) { showChrome.toggle() } },
                  onClose: { dismiss() },
                  onPrevious: neighbour(of: asset, in: live, step: -1),
                  onNext: neighbour(of: asset, in: live, step: 1),
                  title: title(for: asset),
                  // 从哪儿接着播。这一次浏览里翻走又翻回来（横竖屏切换也算，
                  // 视图整个会重建）用内存里那个，精确到秒；不然用上次退出时
                  // 存进索引的位置——那才是「上次看到哪儿了」。
                  startAt: resumeAsset == asset.id ? resumeTime : asset.resumeAt,
                  announceResume: resumeAsset != asset.id && asset.resumeAt > 0,
                  onLeave: { time in
                      resumeAsset = asset.id
                      resumeTime = time
                      store.setPlayback(time, for: asset.id)
                  })
    }

    /// 相邻的那一个。到头了返回 nil，播放器把按钮置灰。
    private func neighbour(of asset: Asset, in live: [Asset], step: Int) -> (() -> Void)? {
        guard let index = live.firstIndex(where: { $0.id == asset.id }) else { return nil }
        let target = index + step
        guard live.indices.contains(target) else { return nil }
        let id = live[target].id
        return { withAnimation(.easeInOut(duration: 0.25)) { currentID = id } }
    }

    /// 幻灯片下一张，到末尾回到第一张
    private func advance() {
        let live = liveAssets
        guard live.count > 1 else { return }
        let index = live.firstIndex { $0.id == currentID } ?? 0
        let next = live[(index + 1) % live.count]
        withAnimation(.easeInOut(duration: 0.35)) { currentID = next.id }
    }

    // MARK: 底栏

    /// 只留序号和幻灯片的播放键。分享去掉；删除在外面的列表里长按或多选
    /// 都能做，压在画面上既重复又挡图。
    private func bottomBar(total: Int, position: Int?) -> some View {
        VStack(spacing: 4) {
            if total > 0 {
                Text("\((position ?? 0) + 1) / \(total)")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.75)
            }

            HStack(spacing: 30) {
                transportButton("backward.end.fill", enabled: (position ?? 0) > 0) { step(-1) }
                transportButton(isPlaying ? "pause.fill" : "play.fill",
                                size: 26, enabled: total > 1) { isPlaying.toggle() }
                transportButton("forward.end.fill", enabled: (position ?? 0) + 1 < total) { step(1) }
            }
        }
        .foregroundStyle(controlTint)
        .padding(.bottom, 8)
    }

    private func transportButton(_ icon: String, size: CGFloat = 20, enabled: Bool = true,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 54, height: 46)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    /// 上一张 / 下一张
    private func step(_ delta: Int) {
        let live = liveAssets
        guard let index = live.firstIndex(where: { $0.id == currentID }) else { return }
        let target = index + delta
        guard live.indices.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { currentID = live[target].id }
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - 可缩放图片

struct ZoomableImage: View {

    let asset: Asset
    /// 单击（用来切换工具栏的显示）。放在这里而不是外层，避免和上下栏的按钮抢点击。
    var onSingleTap: () -> Void = {}

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.viewerBackground
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                } else {
                    ProgressView()
                        .tint(Theme.viewerLabel)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(magnifyGesture)
            .simultaneousGesture(panGesture, including: scale > 1.01 ? .all : .subviews)
            // 双击必须声明在单击之前，否则单击会先把手势吃掉
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    if scale > 1.01 {
                        scale = 1; steadyScale = 1
                        offset = .zero; steadyOffset = .zero
                    } else {
                        scale = 2.6; steadyScale = 2.6
                    }
                }
            }
            .onTapGesture { onSingleTap() }
        }
        .task(id: asset.id) {
            let url = LibraryStore.fileURL(for: asset)
            let loaded = await Task.detached(priority: .userInitiated) {
                ThumbnailCache.downsample(url: url, maxPixel: 2600)
            }.value
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
        .onDisappear {
            scale = 1; steadyScale = 1
            offset = .zero; steadyOffset = .zero
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(1, min(steadyScale * value.magnification, 6))
            }
            .onEnded { _ in
                steadyScale = scale
                if scale <= 1.01 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        scale = 1; steadyScale = 1
                        offset = .zero; steadyOffset = .zero
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.01 else { return }
                offset = CGSize(width: steadyOffset.width + value.translation.width,
                                height: steadyOffset.height + value.translation.height)
            }
            .onEnded { _ in
                steadyOffset = offset
            }
    }
}

// MARK: - 系统分享面板

/// SwiftUI 的 ShareLink 在 fullScreenCover 里经常不弹面板，
/// 这里直接找到最上层的 view controller 自己 present。
enum ShareSheet {

    @MainActor
    static func present(fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        present(items: [fileURL])
    }

    @MainActor
    static func present(items: [Any]) {
        guard let top = topViewController() else { return }

        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)

        // iPad 上不给锚点会直接崩
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX,
                                        y: top.view.bounds.maxY - 60,
                                        width: 1, height: 1)
            popover.permittedArrowDirections = []
        }

        top.present(controller, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }

        // fullScreenCover 自己就是一层 presented controller，要一直找到最上面那层
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
