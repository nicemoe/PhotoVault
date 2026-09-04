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
    private let animationDuration: CFTimeInterval = 0.32
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

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isAnimating else { return }
        let point = gesture.location(in: self)

        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: self)
            // 往左拖 = 去下一页；往右拖 = 回上一页
            let goForward = translation.x <= 0
            guard prepare(forward: goForward, touchAt: point) else {
                gesture.state = .cancelled
                return
            }
        case .changed:
            flipView.update(touch: constrain(point))
        case .ended, .cancelled, .failed:
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
        let distance = hypot(bounds.width, bounds.height) * 2.4
        // 约 27° 的斜角，右下角就往左上走，右上角就往左下走
        let dx = -cos(CGFloat.pi * 27 / 180)
        let dy = (corner.y > bounds.midY ? -1 : 1) * sin(CGFloat.pi * 27 / 180)
        return CGPoint(x: corner.x + dx * distance, y: corner.y + dy * distance)
    }

    private func startFlip(forward goForward: Bool, animated: Bool) {
        guard !isAnimating else { return }
        // 点击翻页固定用右下角起翻，和真书一致
        let corner = CGPoint(x: bounds.width, y: bounds.height)
        guard prepare(forward: goForward, touchAt: corner) else { return }

        if goForward {
            animate(from: flipView.corner, to: foldedAwayPoint(), commit: true)
        } else {
            animate(from: foldedAwayPoint(), to: flipView.corner, commit: true)
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

    private func animate(from: CGPoint, to: CGPoint, commit: Bool) {
        animationFrom = from
        animationTo = to
        animationStart = CACurrentMediaTime()
        if !commit { pendingLocator = nil }

        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step() {
        let elapsed = CACurrentMediaTime() - animationStart
        let t = min(1, elapsed / animationDuration)
        // ease-out，末尾慢下来更像纸落下
        let eased = 1 - pow(1 - t, 3)

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
    @Binding var locator: PageLocator
    var onToggleChrome: () -> Void

    func makeUIView(context: Context) -> FlipContainerView {
        let view = FlipContainerView()
        configure(view)
        context.coordinator.appliedRevision = revision
        return view
    }

    func updateUIView(_ view: FlipContainerView, context: Context) {
        let styleChanged = context.coordinator.appliedRevision != revision
        let jumped = view.locator != locator

        configure(view)

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
    }
}
