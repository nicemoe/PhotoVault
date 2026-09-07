import SwiftUI
import AVFoundation
import KSPlayer

/// 播放引擎。
///
/// 有两套实现：能硬解的走 AVFoundation，硬件解码、省电、seek 跟手；
/// AVFoundation 连解封装都做不到的（mkv、rmvb、wmv 这些）走 KSPlayer 的
/// 软解。播放页的控件和手势只认这层接口，两边完全通用。
@MainActor
protocol VideoEngine: AnyObject {

    /// 渲染画面的视图。引擎自己建、自己管，外面只负责摆位置。
    var renderView: UIView { get }

    var duration: Double { get }
    var currentTime: Double { get }
    var volume: Float { get set }

    func play()
    func pause()
    func setRate(_ rate: Float)

    /// precise=false：带容差，跳到最近的关键帧就行。
    /// 拖动过程中每帧都做精确 seek 会明显卡顿。
    func seek(to seconds: Double, precise: Bool)

    /// 适应（留黑边）还是填充（裁掉溢出的部分）
    func setFill(_ on: Bool)

    func shutdown()

    /// 进度回调，约 0.2 秒一次
    var onProgress: ((Double) -> Void)? { get set }
    /// 时长探测出来了。有些封装要解析一会儿才知道。
    var onDuration: ((Double) -> Void)? { get set }
    /// 播完了
    var onFinish: (() -> Void)? { get set }
    /// 起不来。
    ///
    /// 两个引擎都会报。硬解报了不代表这个文件放不了——上层会换软解再试一次，
    /// 软解也报才是真的解不开。
    var onFailure: (() -> Void)? { get set }
}

// MARK: - 引擎的画面层

/// 把引擎的 renderView 塞进 SwiftUI。
///
/// 引擎换了就整个换掉里面的视图——SwiftUI 靠 id 区分，不会复用错。
struct EngineView: UIViewRepresentable {
    let engine: any VideoEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        // 画面本身不需要接触摸。开着的话它会先把触摸吃掉，
        // 外层的单击/双击就不一定收得到。
        container.isUserInteractionEnabled = false
        attach(to: container)
        return container
    }

    /// SwiftUI 有可能把容器复用给另一个引擎，每次更新都核对一下里面装的是谁
    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: UIView) {
        let view = engine.renderView
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}

// MARK: - 硬解：AVFoundation

/// 承载 AVPlayerLayer 的裸视图。
///
/// 不用 AVKit 的 VideoPlayer：它自带一整套控制条，会把点击全吃掉，
/// 工具栏没法跟着单击开合，缩放和快进手势也做不了。
final class PlayerHostView: UIView {

    /// 标准做法：AVPlayerLayer 就是这个视图的背衬层，尺寸自动跟着视图走。
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var gravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class AVEngine: VideoEngine {

    private let player: AVPlayer
    private let host = PlayerHostView()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var rate: Float = 1

    /// 拖动时的 seek 泵。
    ///
    /// 手指每移动一帧就发一次 seek 的话，AVPlayer 处理不过来会把中间那些丢掉
    /// 或排队，画面卡在原处不动，直到松手才跳——看着就像「只有松手才生效」。
    /// 同一时刻只让一个 seek 在飞，期间来的新位置只留最新那个。
    private var seekInFlight = false
    private var pendingSeek: Double?

    var onProgress: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: (() -> Void)?

    var renderView: UIView { host }
    var duration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }
    var currentTime: Double { player.currentTime().seconds }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        host.player = player

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.onProgress?(time.seconds)
                let d = self.duration
                if d > 0 { self.onDuration?(d) }
            }
        }

        // 播完要把按钮切回「播放」。光靠进度回调判断不可靠：
        // 最后一帧的时间戳未必正好等于时长，会一直显示成暂停。
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onFinish?() }
        }

        // 解不开就报上去，上层会换软解再试。
        //
        // 注意这只兜得住「AVFoundation 自己知道自己不行」的那一半：真正难办的
        // 是它自以为行——把一个不会解的编码画成马赛克，status 一路 .readyToPlay，
        // 从代码里看和正常播放毫无区别。那一半只能靠封装名先避开，
        // 再不行就得人自己切一下。
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.onFailure?() }
        }
    }

    func play() {
        player.play()
        player.rate = rate
    }

    func pause() { player.pause() }

    func setRate(_ value: Float) {
        rate = value
        player.defaultRate = value
        if player.rate > 0 { player.rate = value }
    }

    func seek(to seconds: Double, precise: Bool) {
        let target = max(0, seconds)
        if precise {
            pendingSeek = nil
            seekInFlight = false
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        guard !seekInFlight else {
            pendingSeek = target
            return
        }
        seekInFlight = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: next, precise: false)
                }
            }
        }
    }

    func setFill(_ on: Bool) {
        host.gravity = on ? .resizeAspectFill : .resizeAspect
    }

    func shutdown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        host.player = nil
        statusObserver?.invalidate()
        statusObserver = nil
    }
}

// MARK: - 软解：KSPlayer + FFmpeg

/// AVFoundation 只认 mp4/mov 那一小撮封装，mkv、rmvb、wmv 这些它连解封装
/// 都做不到。KSMEPlayer 自带一整套 FFmpeg，能解的范围大得多，代价是
/// 纯软件解码——费电、发热，高码率 4K 会掉帧。所以只在确实解不了的时候
/// 才切过来。
@MainActor
final class SoftwareEngine: NSObject, VideoEngine {

    private let player: KSMEPlayer
    private let container = UIView()
    private var ticker: Timer?
    private var rate: Float = 1
    private var wantsPlay = false
    private var ready = false
    private var fill = false

    var onProgress: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: (() -> Void)?

    var renderView: UIView { container }
    var duration: Double { player.duration }
    var currentTime: Double { player.currentPlaybackTime }
    var volume: Float {
        get { player.playbackVolume }
        set { player.playbackVolume = newValue }
    }

    init(url: URL) {
        // 不让它自己决定什么时候开播：我们有一整套自己的控件，
        // 播放状态得由 VideoPage 说了算
        KSOptions.isAutoPlay = false
        player = KSMEPlayer(url: url, options: KSOptions())
        super.init()
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        player.delegate = self
        player.prepareToPlay()

        // KSPlayer 没有 AVPlayer 那种周期回调，自己按 0.2 秒轮询一次。
        // 轮询一个内存里的数字，开销可以忽略。
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.onProgress?(self.player.currentPlaybackTime)
                let d = self.player.duration
                if d > 0 { self.onDuration?(d) }
            }
        }
    }

    /// 画面视图要等解码器把首帧准备好才有，建好之后再挂进容器
    private func attachRenderViewIfNeeded() {
        guard let view = player.view, view.superview !== container else { return }
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        container.addSubview(view)
    }

    func play() {
        wantsPlay = true
        guard ready else { return }
        player.play()
        player.playbackRate = rate
    }

    func pause() {
        wantsPlay = false
        player.pause()
    }

    func setRate(_ value: Float) {
        rate = value
        player.playbackRate = value
    }

    func seek(to seconds: Double, precise: Bool) {
        // 软解没有「带容差」这档，统一按精确处理。
        // 拖动时的合并交给 VideoPage 那边限流，这里只管落位。
        player.seek(time: max(0, seconds)) { _ in }
    }

    func setFill(_ on: Bool) {
        fill = on
        player.view?.contentMode = on ? .scaleAspectFill : .scaleAspectFit
    }

    func shutdown() {
        ticker?.invalidate()
        ticker = nil
        player.pause()
        player.shutdown()
    }
}

extension SoftwareEngine: MediaPlayerDelegate {

    func readyToPlay(player: some MediaPlayerProtocol) {
        ready = true
        attachRenderViewIfNeeded()
        if duration > 0 { onDuration?(duration) }
        if wantsPlay {
            player.play()
            self.player.playbackRate = rate
        }
    }

    func changeLoadState(player: some MediaPlayerProtocol) {
        attachRenderViewIfNeeded()
    }

    func changeBuffering(player: some MediaPlayerProtocol, progress: Int) {}

    func playBack(player: some MediaPlayerProtocol, loopCount: Int) {}

    func finish(player: some MediaPlayerProtocol, error: Error?) {
        // 从没就绪过就带着错误结束，说明连 FFmpeg 也解不了这个文件；
        // 已经在放了才出错，当成正常播完处理，别把画面换成报错页
        if error != nil, !ready {
            onFailure?()
        } else {
            onFinish?()
        }
    }
}
