import SwiftUI

struct ReaderView: View {

    let bookID: UUID

    @Environment(BookLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var chapterIndex = 0
    @State private var chapterText = ""
    @State private var pageRanges: [NSRange] = []
    @State private var pageIndex = 0
    @State private var canvasSize: CGSize = .zero
    @State private var showChrome = false
    @State private var showChapters = false
    @State private var showSettings = false
    /// 滚动模式下的当前位置，用来存进度
    @State private var scrollOffsetRatio: Double = 0
    /// 翻页方向，决定过渡动画从哪边进
    @State private var turningForward = true
    @State private var showSearch = false

    private var book: Book? { library.book(bookID) }
    private var settings: ReaderSettings { library.settings }
    private var theme: ReaderTheme { settings.theme }

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
        // 字号、行距、字体、模式变了都要重排
        .onChange(of: settings) { _, _ in repaginate(keepingOffset: currentOffset()) }
        .onChange(of: canvasSize) { _, _ in repaginate(keepingOffset: currentOffset()) }
        .onDisappear { saveProgress() }
        .sheet(isPresented: $showChapters) {
            if let book {
                ChapterListSheet(book: book, current: chapterIndex) { index in
                    load(chapter: index, offset: 0)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
                .presentationDetents([.height(340)])
        }
        .sheet(isPresented: $showSearch) {
            if let book {
                BookSearchSheet(book: book) { hit in
                    load(chapter: hit.chapterIndex, offset: hit.offset)
                }
            }
        }
    }

    // MARK: 正文

    @ViewBuilder
    private func content(_ book: Book) -> some View {
        switch settings.mode {
        case .paged:  pagedContent
        case .scroll: scrollContent
        }
    }

    private var pagedContent: some View {
        GeometryReader { geo in
            let inset = settings.margin
            let size = CGSize(width: max(1, geo.size.width - inset * 2),
                              height: max(1, geo.size.height - inset * 2 - headerHeight))

            ZStack(alignment: .top) {
                if let attributed = pageAttributed() {
                    CoreTextPage(attributed: attributed)
                        .frame(width: size.width, height: size.height)
                        .position(x: geo.size.width / 2, y: inset + headerHeight + size.height / 2)
                        // 翻页动画：整页横向滑入 + 淡入，方向跟着翻页方向走
                        .id(pageKey)
                        .transition(pageTransition)
                }

                header
                    .padding(.horizontal, inset)
                    .padding(.top, 4)
            }
            .clipped()
            .animation(.easeInOut(duration: 0.24), value: pageKey)
            .contentShape(Rectangle())
            // 左三分之一上一页，右三分之一下一页，中间调出工具栏
            .onTapGesture { location in
                let third = geo.size.width / 3
                if location.x < third { turn(-1) }
                else if location.x > third * 2 { turn(1) }
                else { withAnimation(.easeOut(duration: 0.18)) { showChrome.toggle() } }
            }
            // 也支持横向滑动翻页
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        turn(value.translation.width < 0 ? 1 : -1)
                    }
            )
            .onAppear { canvasSize = size }
            .onChange(of: size) { _, new in canvasSize = new }
        }
    }

    private var scrollContent: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(currentChapterTitle)
                            .font(.system(size: settings.fontSize + 3, weight: .bold))
                            .foregroundStyle(theme.text)
                            .padding(.top, 52)
                            .id("top")

                        Text(chapterText)
                            .font(.system(size: settings.fontSize))
                            .foregroundStyle(theme.text)
                            .lineSpacing(settings.lineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        chapterNavigation
                            .padding(.top, 30)
                            .padding(.bottom, 60)
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
                .onPreferenceChange(ScrollOffsetKey.self) { offset in
                    let total = max(1, Double(chapterText.count))
                    _ = total
                    scrollOffsetRatio = max(0, Double(offset))
                }
                .onChange(of: chapterIndex) { _, _ in
                    proxy.scrollTo("top", anchor: .top)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    // 滚动模式下只有中间区域切工具栏，左右留给滚动手势
                    let third = geo.size.width / 3
                    if location.x > third && location.x < third * 2 {
                        withAnimation(.easeOut(duration: 0.18)) { showChrome.toggle() }
                    }
                }
            }
        }
    }

    private var chapterNavigation: some View {
        HStack(spacing: 12) {
            Button {
                load(chapter: chapterIndex - 1, offset: 0)
            } label: {
                Label("上一章", systemImage: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(theme.text.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(chapterIndex <= 0)
            .opacity(chapterIndex <= 0 ? 0.35 : 1)

            Button {
                load(chapter: chapterIndex + 1, offset: 0)
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(theme.text.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(chapterIndex >= (book?.chapterCount ?? 1) - 1)
            .opacity(chapterIndex >= (book?.chapterCount ?? 1) - 1 ? 0.35 : 1)
        }
        .foregroundStyle(theme.text)
    }

    /// 顶部信息条占的高度，正文可用区域要扣掉它
    private let headerHeight: CGFloat = 26

    private var header: some View {
        HStack {
            Text(currentChapterTitle)
                .lineLimit(1)
            Spacer()
            if !pageRanges.isEmpty {
                Text("\(pageIndex + 1)/\(pageRanges.count)")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.secondary)
        .frame(height: headerHeight, alignment: .top)
    }

    /// 翻页动画用：章节 + 页码唯一确定一页，值一变 SwiftUI 就做过渡
    private var pageKey: String { "\(chapterIndex)-\(pageIndex)" }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: turningForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: turningForward ? .leading : .trailing).combined(with: .opacity)
        )
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
                toolButton(settings.mode.title, settings.mode.icon) {
                    var s = library.settings
                    s.mode = s.mode == .paged ? .scroll : .paged
                    library.settings = s
                }
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

    // MARK: 数据

    private var currentChapterTitle: String {
        guard let book, book.chapters.indices.contains(chapterIndex) else { return "" }
        return book.chapters[chapterIndex].title
    }

    private func pageAttributed() -> NSAttributedString? {
        guard !chapterText.isEmpty, pageRanges.indices.contains(pageIndex) else { return nil }
        let full = ReaderTypesetter.attributedText(chapterText,
                                                   settings: settings,
                                                   color: UIColor(theme.text))
        let range = pageRanges[pageIndex]
        guard range.location + range.length <= full.length else { return full }
        return full.attributedSubstring(from: range)
    }

    private func restoreProgress() {
        guard let book else { return }
        load(chapter: book.progress.chapterIndex, offset: book.progress.characterOffset)
    }

    private func load(chapter index: Int, offset: Int) {
        guard let book, book.chapters.indices.contains(index) else { return }
        if index != chapterIndex { turningForward = index > chapterIndex }
        chapterIndex = index
        // 章节标题也放进正文顶部，翻页模式下才不会每章开头突兀
        chapterText = library.chapterText(bookID: bookID, index: index)
        repaginate(keepingOffset: offset)
        saveProgress()
    }

    private func repaginate(keepingOffset offset: Int) {
        guard settings.mode == .paged, canvasSize.width > 1, !chapterText.isEmpty else {
            pageRanges = []
            pageIndex = 0
            return
        }
        let attributed = ReaderTypesetter.attributedText(chapterText,
                                                         settings: settings,
                                                         color: UIColor(theme.text))
        pageRanges = Paginator.pageRanges(for: attributed, size: canvasSize)
        pageIndex = Paginator.pageIndex(containing: offset, in: pageRanges)
    }

    /// 当前位置对应的章内字符偏移
    private func currentOffset() -> Int {
        if settings.mode == .paged {
            guard pageRanges.indices.contains(pageIndex) else { return 0 }
            return pageRanges[pageIndex].location
        }
        return Int(scrollOffsetRatio)
    }

    private func turn(_ direction: Int) {
        guard !pageRanges.isEmpty else { return }
        turningForward = direction > 0
        let next = pageIndex + direction

        if next < 0 {
            // 翻到上一章的最后一页
            guard chapterIndex > 0 else { return }
            load(chapter: chapterIndex - 1, offset: Int.max)
            withAnimation(.none) { pageIndex = max(0, pageRanges.count - 1) }
            saveProgress()
            return
        }
        if next >= pageRanges.count {
            guard let book, chapterIndex < book.chapterCount - 1 else { return }
            load(chapter: chapterIndex + 1, offset: 0)
            return
        }

        pageIndex = next
        saveProgress()
    }

    private func saveProgress() {
        library.updateProgress(bookID: bookID,
                               chapterIndex: chapterIndex,
                               characterOffset: currentOffset())
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
