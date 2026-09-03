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
        _currentID = State(initialValue: assets.indices.contains(startIndex) ? assets[startIndex].id : assets.first?.id)
    }

    /// 过滤掉已经被删掉的。每次访问都要建一次 Set，所以在 body 里只算一次往下传。
    private var liveAssets: [Asset] {
        let existing = Set((store.folder(folderID)?.assets ?? []).map(\.id))
        return assets.filter { existing.contains($0.id) }
    }

    var body: some View {
        let live = liveAssets
        let current = live.first { $0.id == currentID } ?? live.first
        let position = live.firstIndex { $0.id == current?.id }

        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentID) {
                ForEach(live) { asset in
                    // 单击切换工具栏的手势挂在图片上，不能挂在外层 ZStack：
                    // 挂外层会盖住上下两条栏，把分享、删除这些按钮的点击吞掉。
                    ZoomableImage(asset: asset) {
                        withAnimation(.easeOut(duration: 0.2)) { showChrome.toggle() }
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
        .confirmationDialog("删除这张照片？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
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
    }

    // MARK: 顶栏

    private func topBar(total: Int, position: Int?) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.16), in: Circle())
            }

            Spacer()

            if total > 0 {
                Text("\((position ?? 0) + 1) / \(total)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }

            Spacer()

            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(isPlaying ? Theme.accent : Color.white.opacity(0.16))
                    )
            }
            .disabled(total < 2)
            .opacity(total < 2 ? 0.35 : 1)
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
                ShareLink(item: LibraryStore.fileURL(for: asset)) {
                    viewerIcon("square.and.arrow.up")
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("\(asset.width) × \(asset.height)")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    Text(byteText(asset.byteCount))
                        .font(.system(size: 11))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)

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
        .environment(\.colorScheme, .dark)
    }

    private func viewerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
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
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                } else {
                    ProgressView()
                        .tint(.white)
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
