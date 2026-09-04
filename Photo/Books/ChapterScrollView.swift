import SwiftUI
import UIKit
import CoreText

/// 一段连续文字的排版结果。
///
/// 和翻页模式共用 ReaderTypesetter 产出的属性串，所以两种模式的字距、
/// 两端对齐、段间距完全一致——「同一个字符」在两边落在同样的视觉位置，
/// 切换模式才不会跳。
@MainActor
final class ChapterScrollLayout {

    private(set) var totalHeight: CGFloat = 0

    private var lines: [CTLine] = []
    /// 每行顶部 y（自上而下）、基线到顶的距离、水平偏移、覆盖的字符范围
    private var lineTops: [CGFloat] = []
    private var lineAscents: [CGFloat] = []
    private var lineLefts: [CGFloat] = []
    private var lineRanges: [NSRange] = []

    init(attributed: NSAttributedString, width: CGFloat) {
        guard attributed.length > 0, width > 1 else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        // 不要用 greatestFiniteMagnitude，CoreText 对它的处理不稳定
        let constraint = CGSize(width: width, height: 1_000_000)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let height = ceil(suggested.height) + 4
        totalHeight = height

        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        guard let ctLines = CTFrameGetLines(frame) as? [CTLine], !ctLines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        lines = ctLines
        for (i, line) in ctLines.enumerated() {
            var ascent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, nil, nil)
            lineAscents.append(ascent)
            // CoreText 原点在左下、y 轴向上，换算成自上而下的坐标
            lineTops.append(height - origins[i].y - ascent)
            lineLefts.append(origins[i].x)
            let r = CTLineGetStringRange(line)
            lineRanges.append(NSRange(location: r.location, length: r.length))
        }
    }

    /// 只画和可见区域相交的行。
    ///
    /// 不能整块 CTFrameDraw 到一个和正文一样高的 UIView 上——一章几千行，
    /// 那个 UIView 的位图能到几百 MB。这里画布只有一屏大，每帧最多几十行。
    ///
    /// ctx 已经翻成 y 轴向上，canvasHeight 是画布高度，
    /// originY 是这段文字顶部在画布里的自上而下坐标。
    func draw(in ctx: CGContext, originY: CGFloat, canvasHeight: CGFloat, x: CGFloat) {
        for (i, line) in lines.enumerated() {
            let top = originY + lineTops[i]
            guard top + lineAscents[i] * 1.6 > -20, top < canvasHeight + 20 else { continue }
            let baseline = top + lineAscents[i]
            ctx.textPosition = CGPoint(x: x + lineLefts[i], y: canvasHeight - baseline)
            CTLineDraw(line, ctx)
        }
    }

    /// 顶部停在 y 时对应的字符位置
    func characterOffset(atY y: CGFloat) -> Int {
        guard !lineTops.isEmpty else { return 0 }
        var result = 0
        for (i, top) in lineTops.enumerated() {
            if top <= y + 1 { result = lineRanges[i].location } else { break }
        }
        return result
    }

    /// 某个字符应该滚到哪个 y
    func y(forCharacterOffset offset: Int) -> CGFloat {
        guard !lineTops.isEmpty else { return 0 }
        for (i, range) in lineRanges.enumerated() where offset < range.location + range.length {
            return lineTops[i]
        }
        return lineTops[lineTops.count - 1]
    }
}

/// 已经排好版、挂在滚动内容里的一章
@MainActor
private final class ChapterBlock {

    let index: Int
    let title: ChapterScrollLayout
    let body: ChapterScrollLayout
    /// 本章在滚动内容里的顶部。前面插入章节时会整体平移。
    var top: CGFloat = 0

    /// 标题上方留白、标题与正文的间距、章与章之间的间距
    static let titlePad: CGFloat = 46
    static let titleGap: CGFloat = 22
    static let chapterGap: CGFloat = 52

    init(index: Int, title: ChapterScrollLayout, body: ChapterScrollLayout) {
        self.index = index
        self.title = title
        self.body = body
    }

    var bodyTop: CGFloat { Self.titlePad + title.totalHeight + Self.titleGap }
    var height: CGFloat { bodyTop + body.totalHeight + Self.chapterGap }
}

/// 画可见部分的画布。只有一屏大，跟着滚动走。
private final class ScrollCanvas: UIView {
    var render: ((CGContext, CGRect) -> Void)?

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        render?(ctx, bounds)
    }
}

/// 跨章连续滚动阅读。读到章尾自动接上下一章，不用手动点。
final class ChapterScrollContainer: UIView, UIScrollViewDelegate {

    var source: PageSource?
    var chapterTitles: [String] = []
    var settings = ReaderSettings()
    var textColor: UIColor = .label
    var chromeVisible = false

    /// 位置变了（章号，章内字符偏移）
    var onPositionChange: ((Int, Int) -> Void)?
    var onToggleChrome: (() -> Void)?

    private let scrollView = UIScrollView()
    private let canvas = ScrollCanvas()
    private var blocks: [ChapterBlock] = []
    /// 程序改滚动位置时不要把它又当成用户滚动报回去
    private var isRestoring = false
    private var lastWidth: CGFloat = 0
    private var lastReported = (chapter: -1, offset: -1)
    /// 想停在哪。宽度还没下来、排不了版的时候也先记着，等能排了再落实。
    private var desired = (chapter: 0, offset: 0)

    /// 最多同时留几章，再多就把离得最远的那头丢掉
    private let maxBlocks = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        scrollView.addSubview(canvas)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.render = { [weak self] ctx, rect in self?.draw(in: ctx, canvasRect: rect) }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.width > 1, abs(bounds.width - lastWidth) > 0.5 else { return }
        lastWidth = bounds.width
        // 必须照 desired 排。这里不能问 currentPosition()——
        // 首次布局时 blocks 还是空的，它只会答「第 0 章第 0 字」，
        // 把外面要求跳转的位置吃掉。
        reflow()
    }

    // MARK: 排版

    private var textWidth: CGFloat { max(1, bounds.width - CGFloat(settings.margin) * 2) }

    /// 标题用同一套排版，只是大一号
    private var titleSettings: ReaderSettings {
        var s = settings
        s.fontSize += 3
        return s
    }

    private func makeBlock(_ index: Int) -> ChapterBlock? {
        guard let source, index >= 0, index < chapterTitles.count else { return nil }
        let titleText = ReaderTypesetter.attributedText(chapterTitles[index],
                                                       settings: titleSettings,
                                                       color: textColor)
        return ChapterBlock(index: index,
                            title: ChapterScrollLayout(attributed: titleText, width: textWidth),
                            body: ChapterScrollLayout(attributed: source.attributed(index),
                                                      width: textWidth))
    }

    /// 跳到某一章的某个字符。此刻排不了版也没关系，位置先记下。
    func rebuild(chapter: Int, offset: Int) {
        desired = (chapter, offset)
        reflow()
    }

    /// 照 desired 重新排版。宽度、字号、主题变了都走这里，位置不会丢。
    func reflow() {
        guard bounds.width > 1, source != nil, !chapterTitles.isEmpty else { return }
        blocks = makeBlock(desired.chapter).map { [$0] } ?? []
        restack()
        applyDesired()
    }

    private func applyDesired() {
        guard let block = blocks.first(where: { $0.index == desired.chapter }) else { return }
        isRestoring = true
        let y = block.top + block.bodyTop + block.body.y(forCharacterOffset: desired.offset)
        let maxY = max(0, scrollView.contentSize.height - bounds.height)
        scrollView.setContentOffset(CGPoint(x: 0, y: min(max(0, y), maxY)), animated: false)
        isRestoring = false
        positionCanvas()
        canvas.setNeedsDisplay()
        report()
    }

    /// 重新计算每章的 top 和内容高度
    private func restack() {
        var y: CGFloat = 0
        for block in blocks {
            block.top = y
            y += block.height
        }
        let isLast = blocks.last.map { $0.index == chapterTitles.count - 1 } ?? true
        // 读到全书结尾时底部留一点，不至于卡在最后一行
        scrollView.contentSize = CGSize(width: bounds.width,
                                        height: y + (isLast ? bounds.height * 0.4 : 0))
    }

    // MARK: 位置换算

    private func currentPosition() -> (chapter: Int, offset: Int) {
        let y = scrollView.contentOffset.y
        guard let block = blocks.last(where: { $0.top <= y }) ?? blocks.first else { return (0, 0) }
        let local = y - block.top - block.bodyTop
        return (block.index, block.body.characterOffset(atY: max(0, local)))
    }

    // MARK: 滚动

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        positionCanvas()
        guard !isRestoring else { return }
        extendIfNeeded()
        report()
    }

    private func positionCanvas() {
        let frame = CGRect(x: 0, y: max(0, scrollView.contentOffset.y),
                           width: bounds.width, height: bounds.height)
        guard frame != canvas.frame else { return }
        canvas.frame = frame
        canvas.setNeedsDisplay()
    }

    private func report() {
        guard !blocks.isEmpty else { return }
        let pos = currentPosition()
        guard pos.chapter != lastReported.chapter || pos.offset != lastReported.offset else { return }
        lastReported = pos
        desired = pos          // 用户滚到哪，重排时就回哪
        onPositionChange?(pos.chapter, pos.offset)
    }

    /// 快读到章尾就把下一章接上，往回滚就把上一章补上
    private func extendIfNeeded() {
        guard let first = blocks.first, let last = blocks.last else { return }
        let y = scrollView.contentOffset.y
        let lookahead = bounds.height * 1.2

        if y + bounds.height > scrollView.contentSize.height - lookahead,
           last.index + 1 < chapterTitles.count,
           let next = makeBlock(last.index + 1) {
            blocks.append(next)
            restack()
            trimFromTop()
            canvas.setNeedsDisplay()
            return
        }

        if y < lookahead, first.index > 0, let prev = makeBlock(first.index - 1) {
            blocks.insert(prev, at: 0)
            restack()
            // 前面插了一章，内容整体往下移了，得把滚动位置补回去，否则画面会跳
            isRestoring = true
            scrollView.setContentOffset(CGPoint(x: 0, y: y + prev.height), animated: false)
            isRestoring = false
            if blocks.count > maxBlocks {
                blocks.removeLast()
                restack()
            }
            positionCanvas()
            canvas.setNeedsDisplay()
        }
    }

    private func trimFromTop() {
        guard blocks.count > maxBlocks else { return }
        let removed = blocks.removeFirst()
        restack()
        isRestoring = true
        scrollView.setContentOffset(
            CGPoint(x: 0, y: max(0, scrollView.contentOffset.y - removed.height)), animated: false)
        isRestoring = false
        positionCanvas()
    }

    // MARK: 绘制

    private func draw(in ctx: CGContext, canvasRect: CGRect) {
        let canvasTop = canvas.frame.minY
        let x = CGFloat(settings.margin)
        for block in blocks {
            let blockTop = block.top - canvasTop
            guard blockTop < canvasRect.height + 40, blockTop + block.height > -40 else { continue }
            block.title.draw(in: ctx, originY: blockTop + ChapterBlock.titlePad,
                             canvasHeight: canvasRect.height, x: x)
            block.body.draw(in: ctx, originY: blockTop + block.bodyTop,
                            canvasHeight: canvasRect.height, x: x)
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // 工具栏亮着时点哪儿都只收起它，和翻页模式一致
        if chromeVisible { onToggleChrome?(); return }
        let x = gesture.location(in: self).x
        let third = bounds.width / 3
        if x > third && x < third * 2 { onToggleChrome?() }
    }
}

// MARK: - SwiftUI 包装

/// 外部要求跳到某个位置。token 保证「跳到同一处」也能再触发一次。
struct ScrollJump: Equatable {
    var chapter: Int
    var offset: Int
    var token: Int
}

struct ChapterScrollReader: UIViewRepresentable {

    let source: PageSource
    let chapterTitles: [String]
    let settings: ReaderSettings
    let textColor: UIColor
    let chromeVisible: Bool
    let revision: Int
    let jump: ScrollJump
    var onPositionChange: (Int, Int) -> Void
    var onToggleChrome: () -> Void

    func makeUIView(context: Context) -> ChapterScrollContainer {
        let view = ChapterScrollContainer()
        configure(view, context.coordinator)
        context.coordinator.appliedRevision = revision
        context.coordinator.appliedJump = jump
        context.coordinator.position = (jump.chapter, jump.offset)
        view.rebuild(chapter: jump.chapter, offset: jump.offset)
        return view
    }

    func updateUIView(_ view: ChapterScrollContainer, context: Context) {
        configure(view, context.coordinator)

        // 目录、搜索、书签、切模式过来的跳转
        if context.coordinator.appliedJump != jump {
            context.coordinator.appliedJump = jump
            context.coordinator.position = (jump.chapter, jump.offset)
            view.rebuild(chapter: jump.chapter, offset: jump.offset)
            return
        }

        // 排版变了（字号/行距/主题/字体）：原地重排，位置由容器自己守着
        if context.coordinator.appliedRevision != revision {
            context.coordinator.appliedRevision = revision
            view.reflow()
        }
    }

    private func configure(_ view: ChapterScrollContainer, _ coordinator: Coordinator) {
        view.source = source
        view.chapterTitles = chapterTitles
        view.settings = settings
        view.textColor = textColor
        view.chromeVisible = chromeVisible
        view.onToggleChrome = onToggleChrome
        view.onPositionChange = { chapter, offset in
            coordinator.position = (chapter, offset)
            onPositionChange(chapter, offset)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var appliedRevision = -1
        var appliedJump = ScrollJump(chapter: -1, offset: -1, token: -1)
        var position: (chapter: Int, offset: Int) = (0, 0)
    }
}
