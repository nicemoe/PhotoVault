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
    @State private var showDeleteConfirm = false
    @State private var isPlaying = false

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
        let live = liveAssets
        let current = live.first { $0.id == currentID } ?? live.first
        let position = live.firstIndex { $0.id == current?.id }

        ZStack {
            (onDarkSurface ? Color.black : Theme.viewerBackground).ignoresSafeArea()

            TabView(selection: $currentID) {
                ForEach(live) { asset in
                    // 单击切换工具栏的手势挂在图片上，不能挂在外层 ZStack：
                    // 挂外层会盖住上下两条栏，把分享、删除这些按钮的点击吞掉。
                    Group {
                        if asset.isVideo {
                            // 只给当前这一页装播放器：TabView 会预建左右相邻页，
                            // 每页都挂一个 AVPlayer 的话会同时开好几路解码
                            VideoPage(asset: asset,
                                      isCurrent: asset.id == currentID,
                                      chromeVisible: showChrome,
                                      onSingleTap: { withAnimation(.easeOut(duration: 0.2)) { showChrome.toggle() } })
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

            if showChrome {
                VStack {
                    topBar(total: live.count, position: position)
                    Spacer()
                    bottomBar(current)
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!showChrome)
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
        }
        .confirmationDialog(current?.isVideo == true ? "删除这个视频？" : "删除这张照片？",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let asset = current, let position else { return }
                // 先选好删完之后要停在哪一张：优先下一张，没有就上一张
                let next = position + 1 < live.count ? live[position + 1].id
                         : (position > 0 ? live[position - 1].id : nil)
                store.deleteAssets([asset.id], from: folderID)
                if let next { currentID = next } else { dismiss() }
            }
            Button("取消", role: .cancel) {}
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

    private func topBar(total: Int, position: Int?) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                topCircle {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(controlTint)
                }
            }

            Spacer()

            if total > 0 {
                Text("\((position ?? 0) + 1) / \(total)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(controlTint)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background {
                        if onDarkSurface {
                            Capsule().fill(.black.opacity(0.42))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
                        } else {
                            Capsule().fill(.ultraThinMaterial)
                                .overlay(Capsule().strokeBorder(Theme.viewerControl.opacity(0.16), lineWidth: 0.8))
                        }
                    }
            }

            Spacer()

            // 视频页不放幻灯片按钮：画面正中已经有一个播放键，
            // 右上角再来一个，谁也说不清点哪个是播这段视频
            if onDarkSurface {
                Color.clear.frame(width: 38, height: 38)
            } else {
                Button {
                    isPlaying.toggle()
                } label: {
                    topCircle(highlighted: isPlaying) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isPlaying ? Color.white : controlTint)
                    }
                }
                .disabled(total < 2)
                .opacity(total < 2 ? 0.35 : 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
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

    private func bottomBar(_ current: Asset?) -> some View {
        HStack(spacing: 26) {
            if let asset = current {
                // 不用 ShareLink：它在 fullScreenCover 里经常唤不起系统分享面板。
                // 直接用 UIKit 从最上层的 controller present，行为可控。
                Button {
                    ShareSheet.present(fileURL: LibraryStore.fileURL(for: asset))
                } label: {
                    viewerIcon("square.and.arrow.up")
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("\(asset.width) × \(asset.height)")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    Text(asset.isVideo
                         ? "\(asset.durationText) · \(byteText(asset.byteCount))"
                         : byteText(asset.byteCount))
                        .font(.system(size: 11))
                        .opacity(0.7)
                }
                .foregroundStyle(controlTint)

                Spacer()

                Button {
                    showDeleteConfirm = true
                } label: {
                    viewerIcon("trash")
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    /// 底栏的图标。底栏本身有毛玻璃背景，所以图标只要够粗就行。
    private func viewerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(controlTint)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())   // 让整个方框可点，而不是只有图标的不透明像素
    }

    /// 顶栏的圆形按钮。它悬在画面上，背后可能是任意颜色的照片或视频，
    /// 所以底色不能只有 10% ——那在浅色画面上几乎看不见。
    /// 深色画面（视频）上用半透明黑加白描边，浅色画面上用毛玻璃。
    private func topCircle<Content: View>(highlighted: Bool = false,
                                          @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 38, height: 38)
            .background {
                if highlighted {
                    Circle().fill(Theme.accent)
                } else if onDarkSurface {
                    Circle().fill(.black.opacity(0.42))
                        .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
                } else {
                    Circle().fill(.ultraThinMaterial)
                        .overlay(Circle().strokeBorder(Theme.viewerControl.opacity(0.16), lineWidth: 0.8))
                }
            }
            .contentShape(Circle())
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
