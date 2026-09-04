import SwiftUI

struct ReaderView: View {

    let bookID: UUID

    @Environment(BookLibrary.self) private var library
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
        .onChange(of: settings.mode) { _, _ in syncScrollText() }
        .onDisappear { saveProgress() }
        .sheet(isPresented: $showChapters) {
            if let book {
                ChapterListSheet(book: book, current: locator.chapter) { index in
                    jump(chapter: index, offset: 0)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
                .presentationDetents([.height(400)])
        }
        .sheet(isPresented: $showSearch) {
            if let book {
                BookSearchSheet(book: book) { hit in
                    jump(chapter: hit.chapterIndex, offset: hit.offset)
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
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.background.opacity(0.98))

            Spacer()

            HStack(spacing: 0) {
                toolButton("目录", "list.bullet") { showChapters = true }
                toolButton("搜索", "magnifyingglass") { showSearch = true }
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

    private func toolButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(theme.text)
            .contentShape(Rectangle())
        }
    }

    private func toggleChrome() {
        withAnimation(.easeOut(duration: 0.18)) { showChrome.toggle() }
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

    /// 跳章：目录、搜索、上下一章都走这里
    private func jump(chapter: Int, offset: Int) {
        guard let book, book.chapters.indices.contains(chapter) else { return }
        if let source = pageSource {
            locator = source.locator(chapter: chapter, offset: offset)
        } else {
            locator = PageLocator(chapter: chapter, page: 0)
        }
        syncScrollText()
        saveProgress()

        // 跳完就把工具栏收起来：用户打开目录/搜索的目的就是换个地方读，
        // 目的达成之后工具栏只会挡着正文
        if showChrome {
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
