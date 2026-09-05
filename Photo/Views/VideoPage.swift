import SwiftUI
import AVFoundation

/// 承载 AVPlayerLayer 的裸视图。
///
/// 不用 AVKit 的 VideoPlayer：它自带一整套控制条，会把点击全吃掉，
/// 工具栏没法跟着单击开合，双指缩放也做不了。
final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.player = player
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// 预览页里的一段视频：可双指缩放，单击开合工具栏，播放控件跟着工具栏一起显示。
struct VideoPage: View {

    let asset: Asset
    let isCurrent: Bool
    /// 工具栏是否可见。播放控件跟它同步，不再单独一套显隐规则。
    let chromeVisible: Bool
    var onSingleTap: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var current: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false
    @State private var observer: Any?

    // 缩放，和图片那边一套参数
    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.viewerBackground

                if player != nil {
                    PlayerLayerView(player: player)
                        .scaleEffect(scale)
                        .offset(offset)
                } else {
                    // 播放器还没建好时先摆封面，翻到这一页不至于是一片黑
                    AssetImage(asset: asset, maxPixel: 900)
                        .aspectRatio(contentMode: .fit)
                }

                if chromeVisible {
                    controls
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(magnifyGesture)
            .simultaneousGesture(panGesture, including: scale > 1.01 ? .all : .subviews)
            // 双击必须写在单击前面，否则单击会先把手势吃掉
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    if scale > 1.01 {
                        scale = 1; steadyScale = 1
                        offset = .zero; steadyOffset = .zero
                    } else {
                        scale = 2.2; steadyScale = 2.2
                    }
                }
            }
            .onTapGesture { onSingleTap() }
        }
        .onChange(of: isCurrent, initial: true) { _, current in
            if current { start() } else { stop() }
        }
        .onDisappear { stop() }
    }

    // MARK: 播放控件

    private var controls: some View {
        VStack {
            Spacer()

            Button {
                toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.black.opacity(0.35), in: Circle())
            }

            Spacer()

            HStack(spacing: 10) {
                Text(timeText(current))
                Slider(value: Binding(
                    get: { duration > 0 ? min(current / duration, 1) : 0 },
                    set: { ratio in
                        current = ratio * duration
                        seek(to: current)
                    }
                ), onEditingChanged: { editing in
                    scrubbing = editing
                    // 松手后再恢复播放，拖的过程中让画面跟着走
                    if !editing, isPlaying { player?.play() }
                })
                Text(timeText(duration))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.black.opacity(0.3), in: Capsule())
            .padding(.horizontal, 20)
            .padding(.bottom, 96)   // 让开底栏
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: 播放

    private func start() {
        guard player == nil else { return }
        // 静音键按下时也要出声——用户是主动点开看的，不是自动播放的广告
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: LibraryStore.fileURL(for: asset))
        let made = AVPlayer(playerItem: item)
        made.actionAtItemEnd = .pause
        player = made
        duration = asset.duration

        // 每 0.2 秒刷一次进度；拖动过程中不要被回调顶回去
        observer = made.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { time in
            guard !scrubbing else { return }
            current = time.seconds
            if duration <= 0, let d = made.currentItem?.duration.seconds, d.isFinite {
                duration = d
            }
        }

        made.play()
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
        }
        isPlaying.toggle()
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: 手势

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
            .onEnded { _ in steadyOffset = offset }
    }
}
