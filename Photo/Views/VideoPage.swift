import SwiftUI
import AVFoundation

/// 切换屏幕方向。
///
/// 只有视频播放页会用到横屏，别的页面一律竖屏——它们的网格列宽是量出来的
/// 固定值，横屏量到的宽度残留下来就会把卡片挤出屏幕。所以这里除了请求几何
/// 更新，还要同步改 AppDelegate 里的允许范围，并让当前控制器重新问一次。
enum ScreenOrientation {
    @MainActor
    static func request(landscape: Bool) {
        AppDelegate.allowedOrientations = landscape ? .landscape : .portrait

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }

        // 先让系统重新读一遍 supportedInterfaceOrientations，
        // 否则 requestGeometryUpdate 会因为「不在允许范围内」被直接驳回
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
    }
}

/// 单击、双击、拖动全部自己接管。
///
/// 两个原因不用 SwiftUI 的手势：
///
/// 一、同时写 .onTapGesture(count: 2) 和 .onTapGesture 时，SwiftUI 会自动给
/// 单击加一条「等双击失败」的依赖，单击要等约 300ms 才派发。UIKit 这边不设
/// require(toFail:)，单击立刻响应；双击时单击回调会各来一次，但单击只是开合
/// 工具栏，来两次正好抵消。
///
/// 二、拖动如果留给 SwiftUI 的 DragGesture，而触摸又落在这个 UIView 上，
/// 两边谁先拿到、是否每帧都派发都不好确定——快进不跟手就出在这儿。
/// 索性都用同一个识别器，onChanged 由 UIPanGestureRecognizer 直接给。
struct GestureCatcher: UIViewRepresentable {

    var enabled = true
    var onSingle: () -> Void
    var onDouble: (CGPoint) -> Void
    /// (状态, 起点, 位移)
    var onPan: (UIGestureRecognizer.State, CGPoint, CGSize) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleSingle(_:)))
        let double = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))

        for recognizer in [single, double, pan] as [UIGestureRecognizer] {
            recognizer.cancelsTouchesInView = false
            view.addGestureRecognizer(recognizer)
        }
        context.coordinator.update(self)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(self)
        view.isUserInteractionEnabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var onSingle: () -> Void = {}
        private var onDouble: (CGPoint) -> Void = { _ in }
        private var onPan: (UIGestureRecognizer.State, CGPoint, CGSize) -> Void = { _, _, _ in }
        /// 起点要在 began 时记下来：translation 是相对起点的，后面用得到
        private var start: CGPoint = .zero

        func update(_ view: GestureCatcher) {
            onSingle = view.onSingle
            onDouble = view.onDouble
            onPan = view.onPan
        }

        @objc func handleSingle(_ gesture: UITapGestureRecognizer) { onSingle() }

        @objc func handleDouble(_ gesture: UITapGestureRecognizer) {
            onDouble(gesture.location(in: gesture.view))
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { start = gesture.location(in: gesture.view) }
            let t = gesture.translation(in: gesture.view)
            onPan(gesture.state, start, CGSize(width: t.x, height: t.y))
        }
    }
}

/// 预览页里的一段视频。
///
/// 视频页不在 TabView 里，横向手势全归播放器：
/// 单击开合工具栏，双击左右两侧 ±10 秒，横拖快进快退，
/// 左半竖拖调亮度、右半竖拖调音量，双指缩放。
/// 换上一个/下一个用底部的传输键。
struct VideoPage: View {

    let asset: Asset
    let isCurrent: Bool
    /// 工具栏是否可见。播放控件跟它同步，不再单独一套显隐规则。
    let chromeVisible: Bool
    var onSingleTap: () -> Void
    /// 横屏时预览页的顶栏是收起的，关闭键得由这里出
    var onClose: () -> Void
    /// 上一个/下一个媒体。到头了传 nil，按钮变灰。
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    /// 标题。优先用导入时的原始文件名，没有就用目录名。
    var title: String = ""
    /// 从这个位置接着播。横竖屏切换时视图会重建，靠它接上进度。
    var startAt: Double = 0
    /// 这次的 startAt 是上次退出时存下来的，不是刚才翻走翻回来的。
    /// 差别只在要不要提示一句——横竖屏转一下就弹「从 xx:xx 继续」很吵，
    /// 而隔了一天再点开，不说一声人会以为播错地方了。
    var announceResume = false
    /// 视图要走了，把当前进度交出去
    var onLeave: ((Double) -> Void)?
    /// 人手动挑了解码器，记到这个文件上
    var onDecoderChange: ((DecoderChoice) -> Void)?
    /// 在播 / 没在播。外面拿它决定要不要拦着屏幕自动锁。
    var onPlaybackChange: ((Bool) -> Void)?

    @Environment(\.scenePhase) private var scenePhase

    @State private var engine: (any VideoEngine)?
    @State private var isPlaying = false
    @State private var current: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false
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
    /// 填充：裁掉溢出的部分铺满整屏
    @State private var fill = false

    /// 进来前的系统亮度，退出时还回去
    @State private var systemBrightness: CGFloat?

    /// 这一次播放实际用的是哪个引擎。
    ///
    /// 起手按 asset.decoder 定：auto 就看封装（见下），手动选过就听人的。
    /// 硬解中途报错会就地换成 .software 再来一遍。
    @State private var running: DecoderChoice = .auto
    /// 软解也起不来才算真的放不了
    @State private var failed = false

    /// 这个文件起手该用哪个引擎。
    ///
    /// 原来的判据是「导入时探不出时长和尺寸」——那只兜得住 AVFoundation
    /// 自己知道自己不行的那一半。花屏恰恰是另一半：AVI、WMV、RMVB 这些它
    /// 解得开封装、报得出时长和尺寸，看着完全像能播，但里面的 DivX、Xvid、
    /// WMV3、RV40 它不会解，就把解错的数据照样画出来，一片彩色马赛克。
    /// 它不报错，所以那条判据永远轮不到它，全都走了硬解。
    ///
    /// 换成按封装分：不在 AVFoundation 那张短名单上的一律先软解。
    /// 慢一点、费点电，但画面是对的——这个取舍没什么好犹豫的。
    private var initialDecoder: DecoderChoice {
        switch asset.decoder {
        case .hardware: return .hardware
        case .software: return .software
        case .auto:
            return MediaFormats.prefersSoftware(fileName: asset.fileName) ? .software : .hardware
        }
    }


    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height

            ZStack {
                // 视频统一放在黑底上，和主流播放器一致，也让白色控件始终看得清
                Color.black

                if let engine {
                    // 尺寸取窗口和容器里大的那个，比例交给播放层自己算。
                    //
                    // aspect fit 在满屏容器里必定至少铺满一个方向，所以「四边都
                    // 有黑边」只可能是容器本身没满屏。别拿 asset.width/height 去
                    // 算一个框套在外面——那尺寸是导入时探测的，和播放层实际显示
                    // 的比例差一点，播放层就会在框里再 fit 一次，叠出永远消不掉
                    // 的黑边。
                    EngineView(engine: engine)
                        // 引擎换人时强制重建，别把上一个的画面层留在容器里
                        .id(ObjectIdentifier(engine))
                        .frame(width: max(geo.size.width, windowSize.width),
                               height: max(geo.size.height, windowSize.height))
                        .scaleEffect(scale)
                        .offset(offset)
                } else if !failed {
                    // 播放器还没建好时先摆封面，翻到这一页不至于是一片黑
                    AssetImage(asset: asset, maxPixel: 900)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                // 手势单独一层，压在控件下面。
                //
                // 挂在最外层容器上的话，控件就成了它的子视图：SwiftUI 得先等
                // 双击超时（约 300ms）确认你不会再点第二下，DragGesture 也要
                // 先判定失败，才敢把点击派发下去——按一下暂停要等半秒才动。
                // 分层之后，按钮的点击直接命中按钮，手势只管画面上的空白处。
                GestureCatcher(
                    // 放不了的时候单击就是退出。提示页盖在上面、自己也接点击，
                    // 但它未必铺满每一个角落（横屏时安全区那圈），这里兜住。
                    enabled: !locked,
                    onSingle: { failed ? onClose() : onSingleTap() },
                    onDouble: { point in handleDoubleTap(at: point, width: geo.size.width) },
                    onPan: { state, start, translation in
                        handlePan(state: state, start: start,
                                  translation: translation, size: geo.size)
                    }
                )
                    .contentShape(Rectangle())
                    .gesture(magnifyGesture, including: locked ? .subviews : .all)

                if failed {
                    unplayableNote
                } else if chromeVisible {
                    controls(landscape: landscape, size: geo.size)
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
        // 只有当前这一页才报。TabView 会把相邻的页面先建出来，
        // 那些页面一出生就报一次「没在播」，会把正在播的这一页的状态盖掉。
        .onChange(of: isPlaying, initial: true) { _, playing in
            guard isCurrent else { return }
            onPlaybackChange?(playing)
        }
        // 退到后台之后可能就再也回不来了——人上划一抹 App 就没了，
        // onDisappear 不会走。所以趁这一下先把进度交出去，播放本身不动，
        // 切回来还能接着放。
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, current > 0.5 else { return }
            onLeave?(current)
        }
        .onDisappear {
            stop()
            restoreBrightness()
            // 不在这里转回竖屏：横屏下翻到下一个视频时这一页也会消失，
            // 转回去等于把用户刚摆好的方向掰回来。交给预览页整体退出时做。
        }
    }

    // MARK: 控件

    /// 放不了的时候摆这一页。
    ///
    /// 它是**唯一**的出口，所以必须自己带着退路：播放控件在 failed 这条分支
    /// 里根本不画，而预览页那边看到当前是视频，也把自己的顶栏收了——两边
    /// 都没有关闭键，人只能强杀 App。
    ///
    /// 点哪儿都退出，右上角再给一个看得见的关闭键。两条都要：手势是最快的，
    /// 但看不见；按钮慢一步，却是人第一眼会找的东西。
    private var unplayableNote: some View {
        // 走到这儿说明硬解和软解都起不来了。
        // 直接留一块黑屏 + 一个按不动的播放键，只会让人以为是坏了。
        ZStack {
            VStack(spacing: 10) {
                Image(systemName: "film")
                    .font(.system(size: 40))
                Text("这个文件解不开")
                    .font(.system(size: 14, weight: .semibold))
                Text("硬解和软解都试过了。文件已保存，可以从「文件」App 里拷回电脑")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .opacity(0.7)
                Text("点一下退出")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.55)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 32)
            .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 整块都能点，不只是那几行字
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 20 + safeInsets.right)
            .padding(.top, 10 + safeInsets.top)
        }
    }

    /// 控件贴着四边摆，中间留给画面。
    /// 竖屏时上面那条交给预览页的工具栏，这里只出下半部分。
    @ViewBuilder
    private func controls(landscape: Bool, size: CGSize) -> some View {
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
            .padding(.leading, 20 + safeInsets.left)
        } else {
            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 0)
                bottomRows(landscape: landscape, size: size)
            }
        }
    }

    /// 顶栏：左边标题 + 画质，右边倍速和关闭
    private var topRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(qualityText)
                    .font(.system(size: 11.5, weight: .medium))
                    .opacity(0.7)
            }

            Spacer(minLength: 12)

            decoderButton
            speedMenu

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 38, height: 38)
            }
        }
        .foregroundStyle(.white)
        // 横屏时刘海/灵动岛在左边，画面是全屏铺的，控件必须自己让开安全区，
        // 否则左上角的关闭键会被压在灵动岛底下——看不见也点不到
        .padding(.leading, 20 + safeInsets.left)
        .padding(.trailing, 20 + safeInsets.right)
        .padding(.top, 10 + safeInsets.top)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    /// 窗口尺寸。容器可能被外层缩小，画面要按这个铺。
    private var windowSize: CGSize {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.size }
            .first ?? .zero
    }

    /// 画面是全屏铺的，控件得自己按窗口的安全区让位
    private var safeInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .first ?? .zero
    }

    /// 切成填充要裁掉画面的百分之多少。视频比例和屏幕比例差得越远裁得越狠。
    private func cropIfFilled(in size: CGSize) -> Double {
        guard asset.width > 0, asset.height > 0, size.width > 1, size.height > 1 else { return 1 }
        let video = Double(asset.width) / Double(asset.height)
        let screen = Double(size.width) / Double(size.height)
        return 1 - min(video, screen) / max(video, screen)
    }

    private func bottomRows(landscape: Bool, size: CGSize) -> some View {
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
                    transportButton("backward.end.fill", enabled: onPrevious != nil) {
                        onPrevious?()
                    }
                    transportButton(isPlaying ? "pause.fill" : "play.fill", size: 30) { toggle() }
                    transportButton("forward.end.fill", enabled: onNext != nil) {
                        onNext?()
                    }
                }

                HStack(spacing: 4) {
                    // 倍速只在顶栏出现。之前顶栏只在横屏显示，竖屏才在这儿
                    // 补一个；现在顶栏两种方向都有了，这里再放就是重复。
                    lockButton

                    // 只在裁得不多的时候给「铺满」这个选项。
                    // 竖拍视频在横屏下要裁掉 74% 才能铺满，那不叫铺满，
                    // 那是只给你看四分之一。
                    if cropIfFilled(in: CGSize(width: max(size.width, windowSize.width),
                                                height: max(size.height, windowSize.height))) <= 0.25 {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { fill.toggle() }
                            engine?.setFill(fill)
                        } label: {
                            Image(systemName: fill
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 38, height: 38)
                        }
                    }

                    Spacer()
                    // 一律给。竖拍视频转横屏确实会变小（占屏面积 82% -> 26%），
                    // 但手机架着看、躺着看都可能想转，这是用户自己的选择，
                    // 不该由我按「划不划算」替他决定。
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
        .padding(.leading, 20 + safeInsets.left)
        .padding(.trailing, 20 + safeInsets.right)
        // 预览页的底栏在视频上已经不显示了，两种方向都只让开 home 指示条
        .padding(.bottom, 10 + safeInsets.bottom)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func transportButton(_ icon: String, size: CGFloat = 22, enabled: Bool = true,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 48)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
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

    /// 切解码器。
    ///
    /// 摆在顶栏上而不是藏进设置里：花屏是当场看见的，人要的是当场换一下，
    /// 而不是退出去翻菜单。按钮上直接写着现在用的是哪个，因为「现在是硬解」
    /// 本身就是花屏时最需要看到的那条信息。
    private var decoderButton: some View {
        Button {
            switchTo(running == .software ? .hardware : .software, remember: true)
        } label: {
            Text(running == .software ? "软解" : "硬解")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(height: 38)
                .padding(.horizontal, 4)
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
                        if !scrubbing { engine?.pause() }   // 同上，拖之前先停
                        scrubbing = true
                        current = min(max(0, value.location.x / width), 1) * duration
                        seek(to: current, precise: false)   // 拖的过程要快，容差交给系统
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        current = min(max(0, value.location.x / width), 1) * duration
                        seek(to: current, precise: true)    // 松手落到准确位置
                        scrubbing = false
                        if isPlaying { engine?.play() }
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

    /// resumeAt 传 nil 就用 startAt（视图刚建出来的那次）；
    /// 换解码器重来时传当前位置，别退回开头。
    private func start(from resumeAt: Double? = nil) {
        // failed 只在这一次浏览里有效：翻走再翻回来会重建视图，也就会再试一次。
        // 文件可能已经被换成能放的了，没道理一直记着仇。
        guard engine == nil, !failed else { return }
        // 静音键按下时也要出声——用户是主动点开看的，不是自动播放的广告
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let url = LibraryStore.fileURL(for: asset)
        let choice = running == .auto ? initialDecoder : running
        running = choice
        var made: any VideoEngine = choice == .software
            ? SoftwareEngine(url: url)
            : AVEngine(url: url)

        made.onProgress = { time in
            // 拖动过程中不要被回调顶回去
            guard !scrubbing, dragMode != .seek else { return }
            current = time
        }
        made.onDuration = { value in
            if duration <= 0 { duration = value }
        }
        // 播完要把按钮切回「播放」。光靠进度回调判断不可靠：
        // 最后一帧的时间戳未必正好等于时长，会一直显示成暂停。
        made.onFinish = {
            isPlaying = false
            if duration > 0 { current = duration }
        }
        made.onFailure = {
            // 硬解起不来先换软解再试一次，别急着说放不了。
            // 软解也起不来，才是真的解不开。
            if choice == .hardware {
                switchTo(.software, remember: false, announce: false)
            } else {
                failed = true
                engine?.shutdown()
                engine = nil
            }
        }

        made.setRate(rate)
        made.setFill(fill)
        engine = made
        duration = asset.duration

        // 横竖屏切换会重建这个视图，换解码器也会重来，上次退出时存的位置
        // 也从这儿接——三种都要从原地接着播，别退回开头
        let from = resumeAt ?? startAt
        if from > 0.5 {
            current = from
            made.seek(to: from, precise: true)
            // 只有「上次退出时存的位置」才提示。横竖屏转一下、切个解码器
            // 都不该弹这句，那两种人心里有数。
            if announceResume, resumeAt == nil {
                show(hint: "从 \(timeText(from)) 继续")
            }
        }

        made.play()
        isPlaying = true
    }

    /// 退出预览时把音频会话让出去。
    ///
    /// 单个视频停下来时故意不做这件事——翻到下一个还要用，一开一关扬声器
    /// 会「啵」一声。但整个预览页关掉之后就该还回去了：`.playback` 这个
    /// 类别是排他的，一直占着，音响链路醒着耗电，更要紧的是你原来在听的
    /// 音乐、播客会一直哑着，直到你把整个 App 切走才恢复。
    ///
    /// notifyOthersOnDeactivation 就是那句「我用完了，你继续」。
    static func releaseAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stop() {
        // 交出进度必须赶在把 current 清零之前
        if current > 0.5 { onLeave?(current) }
        engine?.shutdown()
        engine = nil
        isPlaying = false
        current = 0
        scale = 1; steadyScale = 1
        offset = .zero; steadyOffset = .zero
        // 不停用音频会话：翻到下一个视频还要用，频繁开关扬声器会响
    }

    private func toggle() {
        guard let engine else { return }
        if isPlaying {
            engine.pause()
        } else {
            // 播完了再按就从头来
            if duration > 0, current >= duration - 0.15 { seek(to: 0) }
            engine.play()
        }
        isPlaying.toggle()
    }

    /// precise=false 时把容差交给引擎，跳到最近的关键帧就行——
    /// 拖动过程中每帧都做精确 seek 会明显卡顿。
    private func seek(to seconds: Double, precise: Bool = true) {
        engine?.seek(to: seconds, precise: precise)
    }

    private func setRate(_ value: Float) {
        rate = value
        engine?.setRate(value)
        show(hint: value == 1 ? "正常速度" : "\(trimZero(Double(value)))× 速度")
    }

    private func skip(_ delta: Double) {
        guard !failed, duration > 0 else { return }
        let target = min(max(0, current + delta), duration)
        current = target
        seek(to: target)
        show(hint: delta > 0 ? "快进 \(Int(delta)) 秒" : "后退 \(Int(-delta)) 秒")
    }

    private func setLandscape(_ on: Bool) { ScreenOrientation.request(landscape: on) }

    /// 换个解码器重来，从当前位置接着播。
    ///
    /// 为什么非要有这个手动开关：花屏时 AVFoundation 一切正常——status 是
    /// readyToPlay，时长对、进度在走，只有画面是坏的。程序没有办法知道
    /// 「画出来的东西不对」，只有眼睛知道。而封装名也只能猜个大概：被人强行
    /// 转过壳的 mp4 里塞着 Xvid，扩展名写着 mp4，照样花。
    ///
    /// remember=true 时把选择记在这个文件上，下次点开直接用对的那个。
    private func switchTo(_ choice: DecoderChoice, remember: Bool, announce: Bool = true) {
        let resumeAt = current
        let wasPlaying = isPlaying
        engine?.shutdown()
        engine = nil
        failed = false
        running = choice
        if remember { onDecoderChange?(choice) }

        start(from: resumeAt)
        if !wasPlaying {
            engine?.pause()
            isPlaying = false
        }
        if announce { show(hint: choice == .software ? "已切到软解" : "已切到硬解") }
    }

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

    /// 放大后拖动是平移；否则横拖快进、竖拖调亮度（左半）和音量（右半）。
    ///
    /// 由 UIPanGestureRecognizer 直接驱动，changed 一定是每帧都来的。
    private func handlePan(state: UIGestureRecognizer.State, start: CGPoint,
                           translation: CGSize, size: CGSize) {
        switch state {
        case .began:
            dragMode = nil

        case .changed:
            if scale > 1.01 {
                offset = CGSize(width: steadyOffset.width + translation.width,
                                height: steadyOffset.height + translation.height)
                return
            }
            guard !failed else { return }

            if dragMode == nil {
                // 位移太小时方向不可信，等它走出去一点再定
                guard abs(translation.width) > 6 || abs(translation.height) > 6 else { return }
                if abs(translation.width) > abs(translation.height) {
                    dragMode = .seek
                    dragAnchor = current
                    scrubbing = true
                    // 拖的时候必须先暂停。不停的话每次 seek 完播放器立刻
                    // 按原速继续往前跑，画面被一次次拽走，看着就是不跟手。
                    engine?.pause()
                } else {
                    dragMode = start.x < size.width / 2 ? .brightness : .volume
                    dragAnchor = dragMode == .brightness
                        ? Double(UIScreen.main.brightness)
                        : Double(engine?.volume ?? 1)
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
                let delta = Double(translation.width / size.width) * span
                current = min(max(0, dragAnchor + delta), duration)
                seek(to: current, precise: false)   // 带容差，要的是跟手
                show(hint: "\(timeText(current)) / \(timeText(duration))")
            case .brightness:
                let level = min(max(0, dragAnchor + Double(-translation.height / size.height)), 1)
                UIScreen.main.brightness = CGFloat(level)
                show(hint: "亮度 \(Int(level * 100))%")
            case .volume:
                let level = min(max(0, dragAnchor + Double(-translation.height / size.height)), 1)
                engine?.volume = Float(level)
                show(hint: "音量 \(Int(level * 100))%")
            case nil:
                break
            }

        case .ended, .cancelled, .failed:
            if dragMode == .seek {
                seek(to: current, precise: true)   // 松手落到准确位置
                scrubbing = false
                if isPlaying { engine?.play() }
            }
            dragMode = nil
            steadyOffset = offset

        default:
            break
        }
    }
}
