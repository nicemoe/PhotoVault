import SwiftUI
import AVFoundation

/// 强制屏幕方向。
/// Info.plist 里已经允许竖屏和两个横屏方向，所以这里只是请求切换。
enum ScreenOrientation {
    @MainActor
    static func request(landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
    }
}

/// 承载 AVPlayerLayer 的裸视图。
///
/// 不用 AVKit 的 VideoPlayer：它自带一整套控制条，会把点击全吃掉，
/// 工具栏没法跟着单击开合，缩放和快进手势也做不了。
final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    /// 是否允许外层相册左右翻页。
    ///
    /// 横屏快进要横向拖，而 TabView 的翻页是它内部那个 UIScrollView 在做。
    /// SwiftUI 的手势优先级管不到祖先视图的 UIKit 手势——用
    /// simultaneousGesture 就是两个一起响应，画面会跟着横移；
    /// 用 highPriorityGesture 也只压得住子视图。只能直接把它关掉。
    var pagingEnabled = true {
        didSet { pager?.isScrollEnabled = pagingEnabled }
    }

    private weak var pager: UIScrollView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var view: UIView? = superview
        while let current = view {
            if let scroll = current as? UIScrollView { pager = scroll; break }
            view = current.superview
        }
        pager?.isScrollEnabled = pagingEnabled
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // 离场时一定要还回去，否则整个相册都翻不动了
        if newWindow == nil { pager?.isScrollEnabled = true }
    }

    deinit {
        // deinit 可能不在主线程；捕获引用后回主线程还原
        if let pager {
            Task { @MainActor in pager.isScrollEnabled = true }
        }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    /// false 表示这一页要独占横向手势（横屏快进）
    var pagingEnabled = true

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.player = player
        view.pagingEnabled = pagingEnabled
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.player !== player { view.player = player }
        if view.pagingEnabled != pagingEnabled { view.pagingEnabled = pagingEnabled }
    }
}

/// 预览页里的一段视频。
///
/// 手势分两套，因为竖屏时左右滑要留给相册翻页：
/// - 竖屏：单击开合工具栏，双击左右 ±10 秒，双指缩放
/// - 横屏：横向拖动快进快退，左半竖拖调亮度，右半竖拖调音量
struct VideoPage: View {

    let asset: Asset
    let isCurrent: Bool
    /// 工具栏是否可见。播放控件跟它同步，不再单独一套显隐规则。
    let chromeVisible: Bool
    var onSingleTap: () -> Void
    /// 横屏时预览页的顶栏是收起的，关闭键得由这里出
    var onClose: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var current: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false
    @State private var observer: Any?
    @State private var rate: Float = 1

    // 缩放，和图片那边一套参数
    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero

    // 拖动手势
    private enum DragMode { case seek, brightness, volume }
    @State private var dragMode: DragMode?
    @State private var dragAnchor: Double = 0
    @State private var hint: String?
    @State private var hintToken = 0
    /// 锁住后不响应任何手势，横躺着看不会被误触打断
    @State private var locked = false

    /// 进来前的系统亮度，退出时还回去
    @State private var systemBrightness: CGFloat?

    /// 导入时探测不出时长和尺寸，就是 AVFoundation 解不了这个封装
    private var unplayable: Bool { asset.duration <= 0 && asset.width == 0 }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height

            ZStack {
                // 视频统一放在黑底上，和主流播放器一致，也让白色控件始终看得清
                Color.black

                if player != nil {
                    // 铺满整页，比例交给 AVPlayerLayer 自己按真实画面算。
                    //
                    // 别拿 asset.width/height 去算一个框套在外面：那个尺寸是导入时
                    // 探测的，和播放层实际显示的比例只要差一点（像素宽高比、旋转矩阵），
                    // 播放层就会在这个框里再 fit 一次——两层 fit 叠加，左右会多出一圈
                    // 永远消不掉的黑边。页面本来就是黑底，它自己留的黑边看不出来。
                    // 横屏（全屏播放）和放大后都由本页独占横向手势，
                    // 竖屏没放大时把左右滑还给相册翻页
                    PlayerLayerView(player: player,
                                    pagingEnabled: !(landscape || scale > 1.01))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                } else if !unplayable {
                    // 播放器还没建好时先摆封面，翻到这一页不至于是一片黑
                    AssetImage(asset: asset, maxPixel: 900)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                if unplayable {
                    unplayableNote
                } else if chromeVisible {
                    controls(landscape: landscape)
                        .transition(.opacity)
                }

                if let hint {
                    Text(hint)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.6), in: Capsule())
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(magnifyGesture, including: locked ? .subviews : .all)
            // 只在本页独占横向手势时才挂拖动，竖屏没放大时完全不接管，
            // 免得和相册翻页抢
            .gesture(dragGesture(size: geo.size, landscape: landscape),
                     including: locked ? .subviews : ((scale > 1.01 || landscape) ? .all : .subviews))
            // 双击必须写在单击前面，否则单击会先把手势吃掉
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                guard !locked else { return }
                handleDoubleTap(at: location, width: geo.size.width)
            }
            .onTapGesture {
                // 锁住时单击只负责把解锁键叫出来，不去开合整套工具栏
                guard !locked else { return }
                onSingleTap()
            }
        }
        // 必须在这一层再声明一次全屏铺满。
        //
        // TabView 的 .page 样式不会把外面那句 ignoresSafeArea 传给页面内容，
        // GeometryReader 拿到的是扣掉安全区之后的尺寸。容器一变矮，
        // 9:16 的视频就从「按宽度铺满」翻成「按高度铺满」，左右于是多出黑边。
        .ignoresSafeArea()
        .onChange(of: isCurrent, initial: true) { _, current in
            if current { start() } else { stop() }
        }
        .onDisappear {
            stop()
            restoreBrightness()
            // 不在这里转回竖屏：横屏下翻到下一个视频时这一页也会消失，
            // 转回去等于把用户刚摆好的方向掰回来。交给预览页整体退出时做。
        }
    }

    // MARK: 控件

    private var unplayableNote: some View {
        // 存住了但 iOS 解不了（mkv、rmvb 这些）。
        // 直接留一块黑屏 + 一个按不动的播放键，只会让人以为是坏了。
        VStack(spacing: 10) {
            Image(systemName: "film")
                .font(.system(size: 40))
            Text("这个格式 iOS 无法播放")
                .font(.system(size: 14, weight: .semibold))
            Text("文件已保存，可以用底栏分享导出")
                .font(.system(size: 12))
                .opacity(0.7)
        }
        .foregroundStyle(.white.opacity(0.75))
    }

    /// 控件贴着四边摆，中间留给画面。
    /// 竖屏时上面那条交给预览页的工具栏，这里只出下半部分。
    @ViewBuilder
    private func controls(landscape: Bool) -> some View {
        if locked {
            // 锁住后只剩一个解锁键，其余手势和控件全部让开，
            // 横躺着看的时候不会被误触打断
            VStack {
                Spacer()
                HStack {
                    lockButton
                    Spacer()
                }
                Spacer()
            }
            .padding(.leading, 20)
        } else {
            VStack(spacing: 0) {
                if landscape { topRow }
                Spacer(minLength: 0)
                bottomRows(landscape: landscape)
            }
        }
    }

    /// 横屏顶栏：关闭 + 画质信息 + 倍速
    private var topRow: some View {
        HStack(spacing: 14) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 38, height: 38)
            }

            Text(qualityText)
                .font(.system(size: 12.5, weight: .semibold))
                .opacity(0.75)

            Spacer()

            speedMenu
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func bottomRows(landscape: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text(timeText(current))
                progressBar
                Text(timeText(duration))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()

            ZStack {
                // 传输键固定在正中，两侧的按钮多一个少一个都不会把它挤歪
                HStack(spacing: 30) {
                    transportButton("gobackward.10") { skip(-10) }
                    transportButton(isPlaying ? "pause.fill" : "play.fill", size: 30) { toggle() }
                    transportButton("goforward.10") { skip(10) }
                }

                HStack {
                    if landscape { lockButton } else { speedMenu }
                    Spacer()
                    Button {
                        setLandscape(!landscape)
                    } label: {
                        Image(systemName: landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 38, height: 38)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.bottom, landscape ? 8 : 96)   // 竖屏要让开预览页的底栏
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func transportButton(_ icon: String, size: CGFloat = 22,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 48)
                .contentShape(Rectangle())
        }
    }

    private var lockButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { locked.toggle() }
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(locked ? AnyShapeStyle(.black.opacity(0.5)) : AnyShapeStyle(.clear),
                            in: Circle())
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                Button {
                    setRate(Float(value))
                } label: {
                    Label(value == 1 ? "正常" : "\(trimZero(value))×",
                          systemImage: rate == Float(value) ? "checkmark" : "")
                }
            }
        } label: {
            Text(rate == 1 ? "倍速" : "\(trimZero(Double(rate)))×")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(height: 38)
                .padding(.horizontal, 4)
        }
    }

    /// 画质一行：1080P · 8.2 Mbps。码率是文件大小除以时长算的，够用了。
    private var qualityText: String {
        var parts: [String] = []
        let shortSide = min(asset.width, asset.height)
        if shortSide > 0 {
            parts.append(shortSide >= 2160 ? "4K" : "\(shortSide)P")
        }
        if asset.duration > 0, asset.byteCount > 0 {
            let mbps = Double(asset.byteCount) * 8 / asset.duration / 1_000_000
            parts.append(String(format: "%.1f Mbps", mbps))
        }
        return parts.joined(separator: " · ")
    }

    /// 进度条：点哪儿跳哪儿，也能按住横拖。
    ///
    /// 不用 Slider——那个圆钮必须先精确按住才能拖，条本身点了没反应，
    /// 在视频上是最别扭的一种交互。
    private var progressBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let ratio = duration > 0 ? min(max(0, current / duration), 1) : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, width * ratio))
                // 播放头：拖的时候放大一点，让人知道抓住了
                Circle()
                    .fill(.white)
                    .frame(width: scrubbing ? 12 : 8, height: scrubbing ? 12 : 8)
                    .offset(x: max(0, width * ratio - (scrubbing ? 6 : 4)))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            // 条只有 4pt 高，手指够不着，靠这个把可点区域撑到 28pt
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 为 0，单击也会走 onChanged，点哪儿就跳哪儿
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrubbing = true
                        current = min(max(0, value.location.x / width), 1) * duration
                        seek(to: current, precise: false)   // 拖的过程要快，容差交给系统
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        current = min(max(0, value.location.x / width), 1) * duration
                        seek(to: current, precise: true)    // 松手落到准确位置
                        scrubbing = false
                        if isPlaying {
                            player?.play()
                            player?.rate = rate
                        }
                    }
            )
        }
        .frame(height: 28)
    }

    private func controlChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.16), in: Capsule())
    }

    private func trimZero(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2g", value)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: 播放

    private func start() {
        guard player == nil, !unplayable else { return }
        // 静音键按下时也要出声——用户是主动点开看的，不是自动播放的广告
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: LibraryStore.fileURL(for: asset))
        let made = AVPlayer(playerItem: item)
        made.actionAtItemEnd = .pause
        made.defaultRate = rate
        player = made
        duration = asset.duration

        // 每 0.2 秒刷一次进度；拖动过程中不要被回调顶回去
        observer = made.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { time in
            guard !scrubbing, dragMode != .seek else { return }
            current = time.seconds
            if duration <= 0, let d = made.currentItem?.duration.seconds, d.isFinite {
                duration = d
            }
        }

        made.play()
        made.rate = rate
        isPlaying = true
    }

    private func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        isPlaying = false
        current = 0
        scale = 1; steadyScale = 1
        offset = .zero; steadyOffset = .zero
        // 不停用音频会话：翻到下一个视频还要用，频繁开关扬声器会响
    }

    private func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            // 播完了再按就从头来
            if duration > 0, current >= duration - 0.15 { seek(to: 0) }
            player.play()
            player.rate = rate
        }
        isPlaying.toggle()
    }

    /// precise=false 时把容差交给系统，跳到最近的关键帧就行——
    /// 拖动过程中每帧都做精确 seek 会明显卡顿。
    private func seek(to seconds: Double, precise: Bool = true) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if precise {
            player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player?.seek(to: time)
        }
    }

    private func setRate(_ value: Float) {
        rate = value
        player?.defaultRate = value
        if isPlaying { player?.rate = value }
        show(hint: value == 1 ? "正常速度" : "\(trimZero(Double(value)))× 速度")
    }

    private func skip(_ delta: Double) {
        guard !unplayable, duration > 0 else { return }
        let target = min(max(0, current + delta), duration)
        current = target
        seek(to: target)
        show(hint: delta > 0 ? "快进 \(Int(delta)) 秒" : "后退 \(Int(-delta)) 秒")
    }

    private func setLandscape(_ on: Bool) { ScreenOrientation.request(landscape: on) }

    // MARK: 提示

    private func show(hint text: String) {
        hintToken &+= 1
        let token = hintToken
        withAnimation(.easeOut(duration: 0.12)) { hint = text }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            // 期间又有新提示的话就别把新的擦掉
            guard token == hintToken else { return }
            withAnimation(.easeOut(duration: 0.2)) { hint = nil }
        }
    }

    private func restoreBrightness() {
        if let systemBrightness {
            UIScreen.main.brightness = systemBrightness
            self.systemBrightness = nil
        }
    }

    // MARK: 手势

    private func handleDoubleTap(at location: CGPoint, width: CGFloat) {
        let third = width / 3
        if location.x < third {
            skip(-10)
        } else if location.x > third * 2 {
            skip(10)
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                if scale > 1.01 {
                    scale = 1; steadyScale = 1
                    offset = .zero; steadyOffset = .zero
                } else {
                    scale = 2.2; steadyScale = 2.2
                }
            }
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

    /// 放大后拖动是平移；否则横屏下横拖快进、竖拖调亮度/音量。
    ///
    /// 竖屏不接管横向拖动——那是相册左右翻页用的。竖屏想快进就双击左右两侧。
    private func dragGesture(size: CGSize, landscape: Bool) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if scale > 1.01 {
                    offset = CGSize(width: steadyOffset.width + value.translation.width,
                                    height: steadyOffset.height + value.translation.height)
                    return
                }
                guard landscape, !unplayable else { return }

                if dragMode == nil {
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    if horizontal {
                        dragMode = .seek
                        dragAnchor = current
                    } else {
                        dragMode = value.startLocation.x < size.width / 2 ? .brightness : .volume
                        dragAnchor = dragMode == .brightness
                            ? Double(UIScreen.main.brightness)
                            : Double(player?.volume ?? 1)
                        if dragMode == .brightness, systemBrightness == nil {
                            systemBrightness = UIScreen.main.brightness
                        }
                    }
                }

                switch dragMode {
                case .seek:
                    guard duration > 0 else { return }
                    // 整屏宽度对应本片长度的一半，短片也不会一划到底
                    let span = min(duration, max(60, duration / 2))
                    let delta = Double(value.translation.width / size.width) * span
                    current = min(max(0, dragAnchor + delta), duration)
                    show(hint: "\(timeText(current)) / \(timeText(duration))")
                case .brightness:
                    let delta = Double(-value.translation.height / size.height)
                    let level = min(max(0, dragAnchor + delta), 1)
                    UIScreen.main.brightness = CGFloat(level)
                    show(hint: "亮度 \(Int(level * 100))%")
                case .volume:
                    let delta = Double(-value.translation.height / size.height)
                    let level = min(max(0, dragAnchor + delta), 1)
                    player?.volume = Float(level)
                    show(hint: "音量 \(Int(level * 100))%")
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if dragMode == .seek { seek(to: current) }
                dragMode = nil
                steadyOffset = offset
            }
    }
}
