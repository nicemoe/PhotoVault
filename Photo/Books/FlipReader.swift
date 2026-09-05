import SwiftUI
import UIKit
import CoreText

/// 把一页正文渲染成图片。仿真翻页只跟图片打交道，
/// 折叠、镜像、阴影都在图片上做，比实时排版快得多。
enum PageRenderer {

    @MainActor
    static func image(for locator: PageLocator, source: PageSource,
                      size: CGSize, margin: CGFloat, background: UIColor) -> UIImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let attributed = source.attributed(at: locator)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            guard let attributed, attributed.length > 0 else { return }

            let textRect = CGRect(x: margin, y: 0,
                                  width: max(1, size.width - margin * 2),
                                  height: size.height)
            let ctx = context.cgContext
            ctx.saveGState()
            // CoreText 原点在左下，翻过来
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)

            let flipped = CGRect(x: textRect.minX, y: size.height - textRect.maxY,
                                 width: textRect.width, height: textRect.height)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: flipped, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }
    }
}

/// 仿真翻页容器：手势跟手、松手判定翻过还是回弹、点击左右三分之一翻页。
final class FlipContainerView: UIView {

    var source: PageSource?
    var margin: CGFloat = 22
    var paperColor: UIColor = .white {
        didSet { flipView.paperColor = paperColor; backgroundColor = paperColor }
    }
    var chromeVisible = false

    var locator = PageLocator(chapter: 0, page: 0)
    var onLocatorChange: ((PageLocator) -> Void)?
    var onToggleChrome: (() -> Void)?

    private let flipView = PageFlipView()
    private var displayLink: CADisplayLink?

    /// 翻页方向：true = 去下一页
    private var forward = true
    /// 动画起止触点
    private var animationFrom: CGPoint = .zero
    private var animationTo: CGPoint = .zero
    private var animationStart: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0.5
    /// 走完整段（页角 → 完全翻走）用的时间。实际时长按距离折算，
    /// 从半路松手时就不该还花满这么久。
    private let fullFlipDuration: CFTimeInterval = 0.5
    /// 点击翻页单独慢一档：拖动是手指已经把纸带到半路，补完剩下那点得快；
    /// 点击是整页从头翻到尾，走 0.5 秒像被弹过去的，看不清纸怎么卷的。
    private let tapFlipDuration: CFTimeInterval = 1.0
    /// 动画结束后要落到的位置
    private var pendingLocator: PageLocator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(flipView)
        flipView.paperColor = paperColor

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        flipView.frame = bounds
        refresh()
    }

    /// 排版或位置变了，重画当前页
    func refresh() {
        guard bounds.width > 1, let source else { return }
        flipView.isFolding = false
        flipView.frontImage = PageRenderer.image(for: locator, source: source,
                                                 size: bounds.size, margin: margin,
                                                 background: paperColor)
        flipView.nextImage = nil
        flipView.setNeedsDisplay()
    }

    // MARK: 手势

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // 工具栏亮着时，点哪儿都只是收起它
        if chromeVisible { onToggleChrome?(); return }

        let x = gesture.location(in: self).x
        let third = bounds.width / 3
        if x < third {
            startFlip(forward: false, animated: true)
        } else if x > third * 2 {
            startFlip(forward: true, animated: true)
        } else {
            onToggleChrome?()
        }
    }

    /// 手指按下的位置。方向要等真的动起来才能判断。
    private var dragStart: CGPoint = .zero
    /// 还没判出方向时为 true
    private var awaitingDirection = false

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isAnimating else { return }
        let point = gesture.location(in: self)

        switch gesture.state {
        case .began:
            // 不能在这里判方向：.began 时 translation 还是 (0,0)，
            // 用 translation.x <= 0 会把 0 也算成「往左」，
            // 结果永远判成往后翻，往前翻根本触发不了。
            dragStart = point
            awaitingDirection = true

        case .changed:
            if awaitingDirection {
                let translation = gesture.translation(in: self)
                // 等移动够一段距离，方向才可信
                guard abs(translation.x) > 6 else { return }
                awaitingDirection = false
                guard prepare(forward: translation.x < 0, touchAt: dragStart) else {
                    gesture.state = .cancelled
                    return
                }
            }
            flipView.update(touch: constrain(point))

        case .ended, .cancelled, .failed:
            guard !awaitingDirection else {
                awaitingDirection = false
                return
            }
            finishDrag(at: point, velocity: gesture.velocity(in: self))

        default:
            break
        }
    }

    /// 折线是「触点 → 页角」连线的垂直平分线。
    /// 触点如果和页角等高，折线就是竖直的，看起来就是整页从右往左扫——
    /// 不是从角掀起。所以要保证触点相对页角有足够的斜度。
    private static let minimumFoldSlope: CGFloat = 0.5

    private func constrain(_ point: CGPoint) -> CGPoint {
        let corner = flipView.corner
        // 横向允许拖到页外，那样才能把纸完全掀走
        var y = point.y
        let horizontal = max(0, corner.x - point.x)
        let lift = horizontal * Self.minimumFoldSlope

        if corner.y > bounds.midY {
            // 右下角：触点至少要抬到这个高度以上
            y = min(y, corner.y - lift)
        } else {
            // 右上角：往下压
            y = max(y, corner.y + lift)
        }
        return CGPoint(x: point.x, y: y)
    }

    // MARK: 翻页流程

    private var isAnimating: Bool { displayLink != nil }

    /// 准备好前后两页的图片。返回 false 表示没得翻了。
    @discardableResult
    private func prepare(forward goForward: Bool, touchAt point: CGPoint) -> Bool {
        guard let source, bounds.width > 1 else { return false }

        let target = goForward ? source.next(locator) : source.previous(locator)
        guard let target else { return false }

        forward = goForward
        pendingLocator = target

        let size = bounds.size
        // 页角固定在右侧：上半屏从右上角起翻，下半屏从右下角起翻，和真书一致
        let cornerY: CGFloat = point.y < size.height / 2 ? 0 : size.height
        flipView.corner = CGPoint(x: size.width, y: cornerY)

        if goForward {
            // 当前页被掀走，露出下一页
            flipView.frontImage = PageRenderer.image(for: locator, source: source, size: size,
                                                     margin: margin, background: paperColor)
            flipView.nextImage = PageRenderer.image(for: target, source: source, size: size,
                                                    margin: margin, background: paperColor)
        } else {
            // 上一页从左边合回来盖住当前页
            flipView.frontImage = PageRenderer.image(for: target, source: source, size: size,
                                                     margin: margin, background: paperColor)
            flipView.nextImage = PageRenderer.image(for: locator, source: source, size: size,
                                                    margin: margin, background: paperColor)
        }

        flipView.isFolding = true
        flipView.update(touch: goForward ? flipView.corner : foldedAwayPoint())
        return true
    }

    /// 纸被完全掀走时触点该在哪。
    ///
    /// 关键是要斜着走，不能水平：水平移动会让折线保持竖直，
    /// 出来的效果就是整页从右往左扫，而不是从角掀起。
    /// 距离取对角线的 2.4 倍，保证整页都落到折线的另一侧、彻底翻走。
    private func foldedAwayPoint() -> CGPoint {
        let corner = flipView.corner
        // 2.05 倍对角线刚好够整页翻走。再多的话，多出来那段纸已经看不见了，
        // 却还在占用动画时间，会让可见部分显得更快。
        let distance = hypot(bounds.width, bounds.height) * 2.05
        // 约 27° 的斜角，右下角就往左上走，右上角就往左下走
        let dx = -cos(CGFloat.pi * 27 / 180)
        let dy = (corner.y > bounds.midY ? -1 : 1) * sin(CGFloat.pi * 27 / 180)
        return CGPoint(x: corner.x + dx * distance, y: corner.y + dy * distance)
    }

    /// 自动翻页调这个，效果和用户点右侧一样
    func flipForward() {
        startFlip(forward: true, animated: true)
    }

    private func startFlip(forward goForward: Bool, animated: Bool) {
        guard !isAnimating else { return }
        // 点击翻页固定用右下角起翻，和真书一致
        let corner = CGPoint(x: bounds.width, y: bounds.height)
        guard prepare(forward: goForward, touchAt: corner) else { return }

        if goForward {
            animate(from: flipView.corner, to: foldedAwayPoint(), commit: true, base: tapFlipDuration)
        } else {
            animate(from: foldedAwayPoint(), to: flipView.corner, commit: true, base: tapFlipDuration)
        }
    }

    private func finishDrag(at point: CGPoint, velocity: CGPoint) {
        guard flipView.isFolding else { return }

        // 拖过半页，或者甩得够快，就算翻过去
        let dragged = flipView.corner.x - point.x
        let passedHalf = dragged > bounds.width / 2
        let flungForward = velocity.x < -600
        let flungBack = velocity.x > 600

        let commit: Bool
        if forward {
            commit = (passedHalf || flungForward) && !flungBack
        } else {
            // 回上一页时是「合回来」，拖得越靠右越算成功
            commit = (dragged < bounds.width / 2 || flungBack) && !flungForward
        }

        let current = constrain(point)
        if forward {
            animate(from: current, to: commit ? foldedAwayPoint() : flipView.corner, commit: commit)
        } else {
            animate(from: current, to: commit ? flipView.corner : foldedAwayPoint(), commit: commit)
        }
    }

    /// base 是走完整段要花的时间；不传就用拖动那档。
    private func animate(from: CGPoint, to: CGPoint, commit: Bool, base: CFTimeInterval? = nil) {
        animationFrom = from
        animationTo = to
        animationStart = CACurrentMediaTime()
        if !commit { pendingLocator = nil }

        // 时长按实际要走的距离折算：从半路松手只补剩下那段，
        // 否则短距离也花满时间，看着像卡住了
        let distance = hypot(to.x - from.x, to.y - from.y)
        let full = hypot(bounds.width, bounds.height) * 2.05
        let ratio = full > 0 ? min(1, distance / full) : 1
        animationDuration = max(0.18, (base ?? fullFlipDuration) * ratio)

        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step() {
        let elapsed = CACurrentMediaTime() - animationStart
        let t = min(1, elapsed / animationDuration)
        // ease-in-out：慢起、中间快、慢停。
        // 不能用 ease-out——它开头最快，cubic 在 30% 的时间里就走完 66% 的路程，
        // 整个翻页的主体动作全挤在头零点几秒，看起来就是闪一下。
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2

        let point = CGPoint(x: animationFrom.x + (animationTo.x - animationFrom.x) * eased,
                            y: animationFrom.y + (animationTo.y - animationFrom.y) * eased)
        flipView.update(touch: point)

        guard t >= 1 else { return }
        displayLink?.invalidate()
        displayLink = nil

        if let target = pendingLocator {
            locator = target
            pendingLocator = nil
            onLocatorChange?(target)
        }
        refresh()
    }
}

// MARK: - SwiftUI 包装

struct SimulatedFlipReader: UIViewRepresentable {

    let source: PageSource
    let margin: CGFloat
    let background: UIColor
    let chromeVisible: Bool
    let revision: Int
    /// 自动翻页的计数器，每 +1 往前翻一页
    let autoAdvance: Int
    @Binding var locator: PageLocator
    var onToggleChrome: () -> Void

    func makeUIView(context: Context) -> FlipContainerView {
        let view = FlipContainerView()
        configure(view)
        context.coordinator.appliedRevision = revision
        context.coordinator.appliedAutoAdvance = autoAdvance
        return view
    }

    func updateUIView(_ view: FlipContainerView, context: Context) {
        let styleChanged = context.coordinator.appliedRevision != revision
        let autoFired = context.coordinator.appliedAutoAdvance != autoAdvance
        let jumped = view.locator != locator

        configure(view)

        if autoFired {
            context.coordinator.appliedAutoAdvance = autoAdvance
            // 走正常的翻页动画，和用户点击的效果一致
            view.flipForward()
            return
        }
        if styleChanged {
            context.coordinator.appliedRevision = revision
            view.refresh()
        } else if jumped {
            view.refresh()
        }
    }

    private func configure(_ view: FlipContainerView) {
        view.source = source
        view.margin = margin
        view.paperColor = background
        view.chromeVisible = chromeVisible
        view.locator = locator
        view.onToggleChrome = onToggleChrome
        view.onLocatorChange = { locator = $0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var appliedRevision = -1
        var appliedAutoAdvance = 0
    }
}
