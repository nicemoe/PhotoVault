import SwiftUI
import UniformTypeIdentifiers

struct BookshelfView: View {

    @Environment(BookLibrary.self) private var library
    @Environment(WiFiService.self) private var wifi

    @State private var showImporter = false
    @State private var openedBook: OpenedBook?
    @State private var renaming: Book?
    @State private var renameText = ""
    @State private var deleting: Book?
    @State private var showWiFi = false
    @State private var errorMessage: String?
    @State private var toastItem: Toast?
    @State private var screenWidth: CGFloat = 0
    @State private var keyword = ""

    private var layout: CardGridLayout {
        let width = screenWidth > 0 ? screenWidth : ScreenMetrics.fallbackWidth
        return CardGridLayout(contentWidth: max(1, width - Theme.Metric.margin * 2),
                              gap: Theme.Metric.cardGap,
                              preferredItemWidth: 160)
    }

    private var visibleBooks: [Book] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return library.sortedBooks }
        return library.sortedBooks.filter {
            $0.title.localizedCaseInsensitiveContains(key)
                || $0.author.localizedCaseInsensitiveContains(key)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if library.books.isEmpty {
                        EmptyState(
                            icon: "books.vertical",
                            title: "书架是空的",
                            message: "支持 TXT 和 EPUB。\n可以从「文件」导入，也可以用 WiFi 上传。",
                            actionTitle: "从文件导入"
                        ) {
                            showImporter = true
                        }
                        .padding(.top, 40)
                    } else if visibleBooks.isEmpty {
                        EmptyState(icon: "magnifyingglass",
                                   title: "没有匹配的书",
                                   message: "试试书名或作者的其他关键词")
                            .padding(.top, 40)
                    } else if library.shelfLayout == .grid {
                        LazyVGrid(columns: layout.columns, spacing: 22) {
                            ForEach(visibleBooks) { book in
                                Button {
                                    openedBook = OpenedBook(id: book.id)
                                } label: {
                                    BookCard(book: book, side: layout.side)
                                }
                                .buttonStyle(PressableCardStyle())
                                .contextMenu { menu(for: book) }
                            }
                        }
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(visibleBooks) { book in
                                Button {
                                    openedBook = OpenedBook(id: book.id)
                                } label: {
                                    BookRow(book: book)
                                }
                                .buttonStyle(PressableCardStyle())
                                .contextMenu { menu(for: book) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.bottom, 40)
            }
            .background(Theme.background)
            .scrollIndicators(.hidden)
            .readingWidth($screenWidth)
            .searchable(text: $keyword, prompt: "搜索书名或作者")
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                    layoutMenu
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("从文件导入", systemImage: "folder")
                        }
                        Divider()
                        Button {
                            showWiFi = true
                        } label: {
                            Label("WiFi 上传", systemImage: "wifi")
                        }
                    } label: {
                        Image(systemName: "plus").circleIcon()
                    }
                    }
                }
            }
        }
        // 阅读器用全屏覆盖，不走导航 push。
        //
        // push 的话要靠 .toolbar(.hidden, for: .tabBar) 藏标签栏，
        // 而 SwiftUI 要等退场动画整个走完才把它放回来——退出小说后
        // 底部会空一下才冒出来。盖上去就没这问题，标签栏根本没被藏过。
        // 顺带也不会和「从左边往右滑翻上一页」抢边缘返回手势。
        .fullScreenCover(item: $openedBook) { opened in
            ReaderView(bookID: opened.id)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.allowedTypes,
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showWiFi) { WiFiTransferView() }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("书名", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let book = renaming { library.rename(bookID: book.id, to: renameText) }
                renaming = nil
            }
        }
        .confirmationDialog(deleting.map { "删除《\($0.title)》" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let book = deleting { library.delete(bookID: book.id) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("书和阅读进度都会被移除。")
        }
        .alert("导入失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay {
            if let title = library.importingTitle {
                ImportingOverlay(title: title)
            }
        }
        .toast($toastItem)
    }

    /// 用菜单 + 对勾而不是单键切换：两种布局的图标谁代表「当前」谁代表
    /// 「点了会变成」很容易读反，菜单里打勾没有歧义。和相册页排序菜单同一个模式。
    private var layoutMenu: some View {
        Menu {
            Picker("", selection: Binding(
                get: { library.shelfLayout },
                set: { library.shelfLayout = $0 }
            )) {
                ForEach(ShelfLayout.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: library.shelfLayout.icon).circleIcon(glyph: 12.5)
        }
    }

    /// 不按类型过滤。
    ///
    /// 小说多半是从浏览器存下来的，很多文件没有声明类型，用
    /// .plainText / .epub 去过滤的话它们在选取器里是灰的——
    /// 看得见、点得到，就是打不开。这里全放行，格式由 importBook
    /// 按扩展名校验，选错了会明确说不支持哪种。
    private static var allowedTypes: [UTType] { [.item] }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            Task {
                var ok = 0
                var failures: [String] = []
                for url in urls {
                    do {
                        try await library.importBook(from: url)
                        ok += 1
                    } catch {
                        // 带上文件名，一次选多本时才知道是哪本没进来
                        failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
                if ok > 0 {
                    toastItem = Toast(icon: "books.vertical.fill", text: "已导入 \(ok) 本")
                }
                if !failures.isEmpty {
                    // 选取器刚关掉就弹 alert 有概率被丢掉，等它的退场动画走完
                    try? await Task.sleep(for: .milliseconds(400))
                    errorMessage = failures.joined(separator: "\n")
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for book: Book) -> some View {
        Button {
            renameText = book.title
            renaming = book
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            deleting = book
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}

// MARK: - 书卡片

struct BookCard: View {
    let book: Book
    let side: CGFloat

    private var tint: Color { Theme.color(at: book.colorIndex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 书封：纯色块 + 书名，扁平风格不做拟物
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                    .fill(tint.opacity(0.16))

                VStack(alignment: .leading, spacing: 8) {
                    Text(book.format.label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tint, in: Capsule())

                    Text(book.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    if book.progressRatio > 0 {
                        ProgressView(value: book.progressRatio)
                            .tint(tint)
                            .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    }
                }
                .padding(14)
            }
            .frame(width: side, height: side * 1.35)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.author.isEmpty ? "\(book.chapterCount) 章" : book.author)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text(book.progressText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
            .padding(.top, 9)
        }
        .frame(width: side)
    }
}

// MARK: - 书列表行

struct BookRow: View {
    let book: Book

    private var tint: Color { Theme.color(at: book.colorIndex) }

    var body: some View {
        HStack(spacing: 13) {
            // 缩小版书封，保持和卡片模式一致的视觉语言
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.18))
                Text(book.format.label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 42, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                Text(book.author.isEmpty ? "\(book.chapterCount) 章" : "\(book.author) · \(book.chapterCount) 章")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    ProgressView(value: book.progressRatio)
                        .tint(tint)
                        .scaleEffect(x: 1, y: 0.55, anchor: .center)
                        .frame(maxWidth: 110)
                    Text(book.progressText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryLabel)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.tertiaryLabel)
        }
        .padding(12)
        .flatCard(radius: 16)
        .tappableArea()
    }
}

// MARK: - 导入中

struct ImportingOverlay: View {
    let title: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(Theme.accent)
                Text("正在解析《\(title)》")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .padding(28)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// fullScreenCover(item:) 要 Identifiable，UUID 本身不是
private struct OpenedBook: Identifiable {
    let id: UUID
}
