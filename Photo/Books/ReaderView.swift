import SwiftUI

struct ReaderView: View {

    let bookID: UUID

    @Environment(BookLibrary.self) private var library
    @Environment(WiFiService.self) private var wifi
    @Environment(\.dismiss) private var dismiss

    /// 翻页模式的当前位置。分页交给 PageSource，这里只记「第几章第几页」。
    @State private var locator = PageLocator(chapter: 0, page: 0)
    @State private var pageSource: PageSource?
    /// 排版版本号。设置一变就 +1，靠它驱动翻页容器刷新当前页——
    /// 当前页是个已经创建好的控制器，背景色和属性串都是创建时烘焙的，
    /// 不主动重建的话要等翻页才会变。
    @State private var styleRevision = 0

    /// 滚动模式用。按段落切开渲染，整章塞进一个 Text 的话，
    /// 几千上万字一次性排版，切到滚动模式会明显卡住。
    @State private var chapterText = ""
    @State private var paragraphs: [ScrollParagraph] = []
    @State private var scrollOffset: Double = 0

    @State private var showChrome = false
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var showSearch = false

    /// 自动翻页
    @State private var isAutoFlipping = false
    /// 每 +1 让翻页容器往前翻一页。用计数器而不是布尔，
    /// 连续自动翻页时每次都是新值，容器才知道要再翻一次。
    @State private var autoAdvanceToken = 0

    /// 进入阅读器之前的系统亮度，退出时还回去，
    /// 免得把用户整台设备的亮度改了还不还
    @State private var systemBrightness: CGFloat?

    private var book: Book? { library.book(bookID) }
    private var settings: ReaderSettings { library.settings }
    private var theme: ReaderTheme { settings.theme }

    /// 顶部信息条高度，正文可用区域要扣掉它
    private let headerHeight: CGFloat = 26

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            if let book {
                // 不要 ignoresSafeArea：机身是圆角的，正文铺到物理边缘的话
                // 最后一行和页码会被圆角切掉。只让背景色铺满，文字待在安全区内。
                content(book)
            }

            if showChrome, let book {
                chrome(book)
            }
        }
        .statusBarHidden(!showChrome)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarHidden(true)
        .task(id: bookID) { restoreProgress() }
        .onChange(of: locator) { _, _ in saveProgress() }
        .onChange(of: settings.mode) { _, _ in
            syncScrollText()
            // 滚动模式下没有「页」可翻，自动翻页就停掉
            if settings.mode == .scroll { isAutoFlipping = false }
        }
        // 自动翻页：isAutoFlipping 变 false 时 task 自动取消
        .task(id: isAutoFlipping) {
            guard isAutoFlipping else { return }
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = wifi.isRunning }

            while !Task.isCancelled && isAutoFlipping {
                try? await Task.sleep(for: .seconds(settings.autoFlipInterval))
                guard !Task.isCancelled, isAutoFlipping else { return }
                guard let source = pageSource, source.next(locator) != nil else {
                    isAutoFlipping = false   // 到全书末尾了
                    return
                }
                autoAdvanceToken &+= 1
            }
        }
        .onAppear { applyBrightness() }
        .onChange(of: settings.brightness) { _, _ in applyBrightness() }
        .onDisappear {
            saveProgress()
            isAutoFlipping = false
            restoreBrightness()
        }
        .sheet(isPresented: $showChapters) {
            if let book {
                ChapterListSheet(book: book, current: locator.chapter) { index in
                    jump(chapter: index, offset: 0, dismissingChrome: true)
                } onPickBookmark: { mark in
                    jump(chapter: mark.chapterIndex, offset: mark.characterOffset, dismissingChrome: true)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSearch) {
            if let book {
                BookSearchSheet(book: book) { hit in
                    jump(chapter: hit.chapterIndex, offset: hit.offset, dismissingChrome: true)
                }
            }
        }
    }

    // MARK: 正文

    @ViewBuilder
    private func content(_ book: Book) -> some View {
        switch settings.mode {
        case .paged:  pagedContent(book)
        case .scroll: scrollContent
        }
    }

    private func pagedContent(_ book: Book) -> some View {
        GeometryReader { geo in
            let inset = settings.margin
            // 交给 PageSource 的是「正文可用区域」，页边距由每页控制器自己加
            let contentSize = CGSize(width: max(1, geo.size.width - inset * 2),
                                     height: max(1, geo.size.height - headerHeight))

            VStack(spacing: 0) {
                // 信息条留在翻页容器外面，翻页时它不跟着卷，和纸书的书眉一样
                header
                    .padding(.horizontal, inset)

                if let source = pageSource {
                    // transitionStyle 在 UIPageViewController 初始化之后就改不了了，
                    // 换翻页效果必须让 SwiftUI 把容器整个拆掉重建。
                    // 光靠 .id() 不够可靠（实测要切好几次才生效），改用 switch：
                    // 两个分支在 SwiftUI 里是不同的视图类型，切换必然重建。
                    switch settings.pageAnimation {
                    case .curl:
                        // 自己画的仿真翻页：从右上/右下角起翻，跟手
                        SimulatedFlipReader(source: source,
                                            margin: inset,
                                            background: UIColor(theme.background),
                                            chromeVisible: showChrome,
                                            revision: styleRevision,
                                            autoAdvance: autoAdvanceToken,
                                            locator: $locator,
                                            onToggleChrome: toggleChrome)
                    case .slide:
                        pageContainer(source: source, animation: .slide, inset: inset)
                    }
                } else {
                    Spacer()
                }
            }
            .onAppear { rebuildSource(book: book, contentSize: contentSize) }
            .onChange(of: contentSize) { _, size in rebuildSource(book: book, contentSize: size) }
            .onChange(of: settings) { _, _ in rebuildSource(book: book, contentSize: contentSize) }
        }
    }

    private func pageContainer(source: PageSource, animation: PageAnimation, inset: CGFloat) -> some View {
        PageCurlReader(source: source,
                       animation: animation,
                       margin: inset,
                       background: UIColor(theme.background),
                       chromeVisible: showChrome,
                       revision: styleRevision,
                       autoAdvance: autoAdvanceToken,
                       locator: $locator,
                       onToggleChrome: toggleChrome)
    }

    private var scrollContent: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(currentChapterTitle)
                            .font(.system(size: settings.fontSize + 3, weight: .bold))
                            .foregroundStyle(theme.text)
                            .padding(.top, 40)
                            .id("top")

                        // LazyVStack + 分段：只排版屏幕附近的段落
                        LazyVStack(alignment: .leading, spacing: settings.lineSpacing + 4) {
                            ForEach(paragraphs) { paragraph in
                                Text(paragraph.text)
                                    .font(.system(size: settings.fontSize))
                                    .foregroundStyle(theme.text)
                                    .lineSpacing(settings.lineSpacing)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        chapterNavigation
                            .padding(.top, 30)
                            .padding(.bottom, 40)
                    }
                    .padding(.horizontal, settings.margin)
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: ScrollOffsetKey.self,
                                                   value: -inner.frame(in: .named("reader")).minY)
                        }
                    )
                }
                .coordinateSpace(name: "reader")
                .onPreferenceChange(ScrollOffsetKey.self) { value in
                    scrollOffset = max(0, Double(value))
                }
                .onChange(of: locator.chapter) { _, _ in
                    syncScrollText()
                    proxy.scrollTo("top", anchor: .top)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    // 工具栏亮着时，点哪儿都只是收起它
                    if showChrome { toggleChrome(); return }
                    let third = geo.size.width / 3
                    if location.x > third && location.x < third * 2 { toggleChrome() }
                }
                .onAppear { syncScrollText() }
            }
        }
    }

    private var chapterNavigation: some View {
        HStack(spacing: 12) {
            Button {
                jump(chapter: locator.chapter - 1, offset: 0)
            } label: {
                Label("上一章", systemImage: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(theme.text.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(locator.chapter <= 0)
            .opacity(locator.chapter <= 0 ? 0.35 : 1)

            Button {
                jump(chapter: locator.chapter + 1, offset: 0)
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(theme.text.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(locator.chapter >= (book?.chapterCount ?? 1) - 1)
            .opacity(locator.chapter >= (book?.chapterCount ?? 1) - 1 ? 0.35 : 1)
        }
        .foregroundStyle(theme.text)
    }

    private var header: some View {
        HStack {
            Text(currentChapterTitle)
                .lineLimit(1)
            Spacer()
            if let source = pageSource {
                let total = source.pageCount(locator.chapter)
                if total > 0 {
                    Text("\(locator.page + 1)/\(total)")
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.secondary)
        .frame(height: headerHeight)
    }

    // MARK: 工具栏

    private func chrome(_ book: Book) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { saveProgress(); dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(currentChapterTitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
                Spacer()

                Button(action: toggleBookmark) {
                    Image(systemName: currentBookmark == nil ? "bookmark" : "bookmark.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(currentBookmark == nil ? theme.text : Theme.accent)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.background.opacity(0.98))

            Spacer()

            HStack(spacing: 0) {
                toolButton("目录", "list.bullet") { showChapters = true }
                toolButton("搜索", "magnifyingglass") { showSearch = true }
                toolButton(isAutoFlipping ? "停止" : "自动",
                           isAutoFlipping ? "pause.circle" : "play.circle",
                           highlighted: isAutoFlipping) {
                    // 滚动模式没有「页」的概念，自动翻页只在翻页模式下有意义
                    guard settings.mode == .paged else { return }
                    isAutoFlipping.toggle()
                }
                .opacity(settings.mode == .paged ? 1 : 0.35)
                // 翻页/滚动的切换放在「设置」里就够了。摆在工具栏上显示的是
                // 当前模式名，看着像个动作，容易读成「点它会翻页」。
                toolButton(theme.isDark ? "日间" : "夜间", theme.isDark ? "sun.max" : "moon") {
                    var s = library.settings
                    s.theme = s.theme == .night ? .paper : .night
                    library.settings = s
                }
                toolButton("设置", "textformat.size") { showSettings = true }
            }
            .padding(.top, 8)
            .padding(.bottom, 26)
            .background(theme.background.opacity(0.98))
        }
        .transition(.opacity)
    }

    private func toolButton(_ title: String, _ icon: String,
                           highlighted: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(highlighted ? Theme.accent : theme.text)
            .contentShape(Rectangle())
        }
    }

    private func toggleChrome() {
        withAnimation(.easeOut(duration: 0.18)) { showChrome.toggle() }
    }

    // MARK: 亮度

    /// 只在阅读器内接管亮度。进来先记下系统值，出去还回去——
    /// 看本书把整台设备的亮度改了不还，是很讨厌的行为。
    private func applyBrightness() {
        guard let value = settings.brightness else {
            restoreBrightness()
            return
        }
        if systemBrightness == nil { systemBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = CGFloat(value)
    }

    private func restoreBrightness() {
        if let original = systemBrightness {
            UIScreen.main.brightness = original
            systemBrightness = nil
        }
    }

    // MARK: 书签

    /// 当前页覆盖的字符范围，用来判断这一页是否已被收藏
    private var currentPageRange: Range<Int> {
        guard let source = pageSource else {
            return locator.chapter..<(locator.chapter + 1)
        }
        let start = source.characterOffset(of: locator)
        let ranges = source.pages(locator.chapter)
        let length = ranges.indices.contains(locator.page) ? ranges[locator.page].length : 1
        return start..<(start + max(1, length))
    }

    private var currentBookmark: Bookmark? {
        library.bookmark(bookID: bookID, chapter: locator.chapter, pageRange: currentPageRange)
    }

    private func toggleBookmark() {
        if let existing = currentBookmark {
            library.removeBookmark(bookID: bookID, markID: existing.id)
            return
        }
        let offset = pageSource?.characterOffset(of: locator) ?? 0
        let text = library.chapterText(bookID: bookID, index: locator.chapter)
        let start = text.index(text.startIndex, offsetBy: min(offset, text.count))
        let end = text.index(start, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        let snippet = String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        library.addBookmark(bookID: bookID,
                            chapter: locator.chapter,
                            offset: offset,
                            title: currentChapterTitle,
                            snippet: snippet)
    }

    // MARK: 数据

    private var currentChapterTitle: String {
        guard let book, book.chapters.indices.contains(locator.chapter) else { return "" }
        return book.chapters[locator.chapter].title
    }

    /// 建立/重建分页数据源。字号、行距、字体、页面尺寸变了都要重来，
    /// 重来之后按字符偏移把位置找回去，而不是保留页码。
    private func rebuildSource(book: Book, contentSize: CGSize) {
        guard contentSize.width > 1, contentSize.height > 1 else { return }

        let offset = pageSource?.characterOffset(of: locator) ?? book.progress.characterOffset
        let color = UIColor(theme.text)

        if let existing = pageSource {
            existing.invalidate(settings: settings, textColor: color, pageSize: contentSize)
        } else {
            pageSource = PageSource(bookID: bookID,
                                    chapters: book.chapters,
                                    library: library,
                                    settings: settings,
                                    textColor: color,
                                    pageSize: contentSize)
        }
        locator = pageSource?.locator(chapter: locator.chapter, offset: offset) ?? locator
        styleRevision &+= 1
    }

    private func restoreProgress() {
        guard let book else { return }
        locator = PageLocator(chapter: book.progress.chapterIndex, page: 0)
        syncScrollText()
    }

    /// 跳章。
    ///
    /// - Parameter dismissingChrome: 只有「明确指定了目的地」的跳转才收工具栏
    ///   （目录、搜索）。上一章/下一章是可重复的顺序浏览，用户可能连点好几次
    ///   找位置，替他收起来等于替他断定「你不会再点了」。
    private func jump(chapter: Int, offset: Int, dismissingChrome: Bool = false) {
        guard let book, book.chapters.indices.contains(chapter) else { return }
        if let source = pageSource {
            locator = source.locator(chapter: chapter, offset: offset)
        } else {
            locator = PageLocator(chapter: chapter, page: 0)
        }
        syncScrollText()
        saveProgress()

        if dismissingChrome, showChrome {
            withAnimation(.easeOut(duration: 0.18)) { showChrome = false }
        }
    }

    private func syncScrollText() {
        guard settings.mode == .scroll else { return }
        let text = library.chapterText(bookID: bookID, index: locator.chapter)
        guard text != chapterText || paragraphs.isEmpty else { return }
        chapterText = text
        paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { ScrollParagraph(id: $0.offset, text: $0.element) }
    }

    private func saveProgress() {
        let offset: Int
        if settings.mode == .paged {
            offset = pageSource?.characterOffset(of: locator) ?? 0
        } else {
            offset = Int(scrollOffset)
        }
        library.updateProgress(bookID: bookID, chapterIndex: locator.chapter, characterOffset: offset)
    }
}

/// 滚动模式的一个段落
struct ScrollParagraph: Identifiable, Hashable {
    let id: Int
    let text: String
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
