import UIKit

/// 仿真翻页的几何。
///
/// 纸张从某个角被掀起时，折线是「触点 → 页角」连线的垂直平分线；
/// 折线靠页角那一侧的纸面翻了过来，沿折线做镜像就是我们看到的纸背。
/// 系统 UIPageViewController 的程序化翻页只能整页卷，做不到从角起翻，所以自己画。
enum PageFold {

    /// 用半平面裁剪凸多边形（Sutherland–Hodgman）。
    /// 页面本身是矩形，裁完还是凸多边形，直接连成路径即可。
    static func clip(polygon: [CGPoint], through point: CGPoint,
                     normal: CGVector, keepPositiveSide: Bool) -> [CGPoint] {
        guard polygon.count >= 3 else { return [] }

        func signedDistance(_ p: CGPoint) -> CGFloat {
            let d = (p.x - point.x) * normal.dx + (p.y - point.y) * normal.dy
            return keepPositiveSide ? d : -d
        }

        var output: [CGPoint] = []
        for i in 0..<polygon.count {
            let current = polygon[i]
            let previous = polygon[(i + polygon.count - 1) % polygon.count]
            let dCurrent = signedDistance(current)
            let dPrevious = signedDistance(previous)

            if dCurrent >= 0 {
                if dPrevious < 0, let cross = intersection(previous, current, dPrevious, dCurrent) {
                    output.append(cross)
                }
                output.append(current)
            } else if dPrevious >= 0, let cross = intersection(previous, current, dPrevious, dCurrent) {
                output.append(cross)
            }
        }
        return output
    }

    private static func intersection(_ a: CGPoint, _ b: CGPoint,
                                     _ da: CGFloat, _ db: CGFloat) -> CGPoint? {
        let denominator = da - db
        guard abs(denominator) > .ulpOfOne else { return nil }
        let t = da / denominator
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    static func path(_ points: [CGPoint]) -> CGPath? {
        guard points.count >= 3 else { return nil }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    /// 沿折线做镜像的仿射变换
    static func reflection(through point: CGPoint, normal n: CGVector) -> CGAffineTransform {
        let a = 1 - 2 * n.dx * n.dx
        let b = -2 * n.dx * n.dy
        let c = -2 * n.dx * n.dy
        let d = 1 - 2 * n.dy * n.dy
        // 先平移到折线过原点，镜像，再平移回去
        let tx = point.x - (a * point.x + c * point.y)
        let ty = point.y - (b * point.x + d * point.y)
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

/// 画一次折叠状态的视图。只认图片，不关心文字怎么来的。
final class PageFlipView: UIView {

    var frontImage: UIImage?     // 正在被掀起的那一页
    var nextImage: UIImage?      // 底下露出来的那一页
    var paperColor: UIColor = .white

    /// 页角。右下角翻页就是 (W, H)
    var corner: CGPoint = .zero
    /// 当前触点
    var touch: CGPoint = .zero
    var isFolding = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        backgroundColor = .white
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(touch point: CGPoint) {
        touch = point
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        paperColor.setFill()
        ctx.fill(bounds)

        guard let front = frontImage else { return }

        // 没在折叠、或者触点和页角重合（折线在页外），就只画当前页
        let dx = corner.x - touch.x
        let dy = corner.y - touch.y
        let distance = sqrt(dx * dx + dy * dy)
        guard isFolding, distance > 1, let next = nextImage else {
            front.draw(in: bounds)
            return
        }

        let normal = CGVector(dx: dx / distance, dy: dy / distance)
        let mid = CGPoint(x: (touch.x + corner.x) / 2, y: (touch.y + corner.y) / 2)

        let rectPoints = [CGPoint(x: bounds.minX, y: bounds.minY),
                          CGPoint(x: bounds.maxX, y: bounds.minY),
                          CGPoint(x: bounds.maxX, y: bounds.maxY),
                          CGPoint(x: bounds.minX, y: bounds.maxY)]

        // 1. 底下那一页
        next.draw(in: bounds)

        // 2. 当前页没被掀起的部分（折线背离页角的一侧）
        let flatPoints = PageFold.clip(polygon: rectPoints, through: mid,
                                       normal: normal, keepPositiveSide: false)
        if let flatPath = PageFold.path(flatPoints) {
            ctx.saveGState()
            ctx.addPath(flatPath)
            ctx.clip()
            front.draw(in: bounds)
            ctx.restoreGState()
        }

        // 3. 掀起的纸背：把页面沿折线镜像过去
        let reflect = PageFold.reflection(through: mid, normal: normal)
        let reflectedRect = rectPoints.map { $0.applying(reflect) }
        // 纸背落在「未掀起」那一侧，且必须还在页面范围内
        var backPoints = PageFold.clip(polygon: reflectedRect, through: mid,
                                       normal: normal, keepPositiveSide: false)
        for edge in edges(of: bounds) {
            backPoints = PageFold.clip(polygon: backPoints, through: edge.point,
                                       normal: edge.normal, keepPositiveSide: true)
            if backPoints.count < 3 { break }
        }

        if let backPath = PageFold.path(backPoints) {
            // 纸背的投影落在底下那页上
            ctx.saveGState()
            ctx.addPath(backPath)
            ctx.clip()
            drawShadow(ctx, along: normal, at: mid, spread: 26, alpha: 0.28, towardCorner: false)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(backPath)
            ctx.clip()

            // 纸背本身：纸色打底 + 很淡的镜像文字，模拟薄纸透字
            ctx.saveGState()
            ctx.concatenate(reflect)
            paperColor.setFill()
            ctx.fill(bounds)
            front.draw(in: bounds, blendMode: .normal, alpha: 0.10)
            ctx.restoreGState()

            // 折痕：靠折线一侧压深一点
            drawShadow(ctx, along: normal, at: mid, spread: 34, alpha: 0.16, towardCorner: false)
            ctx.restoreGState()
        }
    }

    private struct Edge {
        var point: CGPoint
        var normal: CGVector
    }

    /// 页面四条边，法线指向页面内部
    private func edges(of rect: CGRect) -> [Edge] {
        [
            Edge(point: CGPoint(x: rect.minX, y: rect.minY), normal: CGVector(dx: 1, dy: 0)),
            Edge(point: CGPoint(x: rect.maxX, y: rect.minY), normal: CGVector(dx: -1, dy: 0)),
            Edge(point: CGPoint(x: rect.minX, y: rect.minY), normal: CGVector(dx: 0, dy: 1)),
            Edge(point: CGPoint(x: rect.minX, y: rect.maxY), normal: CGVector(dx: 0, dy: -1))
        ]
    }

    /// 沿折线方向铺一条渐变阴影
    private func drawShadow(_ ctx: CGContext, along normal: CGVector, at point: CGPoint,
                           spread: CGFloat, alpha: CGFloat, towardCorner: Bool) {
        let colors = [UIColor.black.withAlphaComponent(alpha).cgColor,
                      UIColor.black.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 1]) else { return }
        let sign: CGFloat = towardCorner ? 1 : -1
        let end = CGPoint(x: point.x + normal.dx * spread * sign,
                          y: point.y + normal.dy * spread * sign)
        ctx.drawLinearGradient(gradient, start: point, end: end, options: [])
    }
}
