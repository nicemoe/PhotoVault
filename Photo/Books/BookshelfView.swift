import SwiftUI

/// 书架上会弹的两张卡片。用一个 .sheet(item:) 统一管，
/// 比在同一个视图上挂两个 .sheet(isPresented:) 稳。
private enum ShelfSheet: String, Identifiable {
    case wifi
    case importer
    var id: String { rawValue }
}

struct BookshelfView: View {

    @Environment(BookLibrary.self) private var library
    @Environment(WiFiService.self) private var wifi
    @Environment(\.scenePhase) private var scenePhase

    @State private var sheet: ShelfSheet?
    @State private var openedBook: OpenedBook?
    @State private var renaming: Book?
    @State private var renameText = ""
    @State private var deleting: Book?
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
                            title: "书架是空的",
                            message: "支持 TXT 和 EPUB。\n可以从「文件」导入，也可以用 WiFi 上传。",
                            actionTitle: "从文件导入"
                        ) {
                            sheet = .importer
                        }
                        .padding(.top, 40)
                    } else if visibleBooks.isEmpty {
                        EmptyState(title: "没有匹配的书",
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
                ToolbarItem(placement: .topBarLeading) {
                    if wifi.isRunning {
                        Button {
                            sheet = .wifi
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(Color(hex: 0x2FBF5B)).frame(width: 6, height: 6)
                                Text("传输中")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(Theme.secondaryLabel)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.fill, in: Capsule())
                        }
                    }
                }
                // 两个按钮放进同一个 ToolbarItem 里用 HStack 摆，间距才可控；
                // 交给 ToolbarItemGroup 排的话由系统决定，会偏大。
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                        addMenu
                        pageMenu
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
        .sheet(item: $sheet) { which in
            switch which {
            case .wifi:
                WiFiTransferView()
            case .importer:
                DocumentPicker { urls in
                    handleImport(urls)
                } onFinish: {
                    sheet = nil
                }
                .ignoresSafeArea()
            }
        }
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
            if let progress = library.importing {
                ImportingOverlay(progress: progress)
            }
        }
        .toast($toastItem)
        // 电脑上把书丢进 Books 文件夹后，回到 App 就收走。
        // 只在切回前台时扫一次——文件是在 App 不活跃的时候放进来的，
        // 常驻监听目录只会白耗电。
        .task { await collectLooseFiles() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await collectLooseFiles() }
        }
    }

    private func collectLooseFiles() async {
        let saved = await library.importLooseFiles()
        guard saved > 0 else { return }
        toastItem = Toast(icon: "tray.and.arrow.down.fill", text: "已收进 \(saved) 本")
    }

    private var addMenu: some View {
        Menu {
            Button {
                sheet = .importer
            } label: {
                Label("从文件导入", systemImage: "folder")
            }

            Divider()

            Button {
                sheet = .wifi
            } label: {
                Label("WiFi 上传", systemImage: "wifi")
            }
        } label: {
            // 加号比默认细一档：那一横一竖比旁边的三条杠粗，摆一起不齐
            Image(systemName: "plus").circleIcon(weight: .medium)
        }
    }

    /// 三条杠：书架布局 + 外观。
    ///
    /// 布局用菜单 + 对勾而不是单键切换：两种布局的图标谁代表「当前」谁代表
    /// 「点了会变成」很容易读反，菜单里打勾没有歧义。
    private var pageMenu: some View {
        @Bindable var library = library

        return Menu {
            Menu {
                Picker("", selection: $library.shelfLayout) {
                    ForEach(ShelfLayout.allCases) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(library.shelfLayout.title, systemImage: library.shelfLayout.icon)
            }

            Divider()

            // 外观作为一个条目收在这里，点开才是三个选项。
            // 一级条目直接显示当前选中的值（跟随系统 / 浅色 / 深色），
            // 不要再加「外观」前缀——展开后的对勾已经说明了它是什么。
            Menu {
                Picker("", selection: $library.appearance) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.title, systemImage: theme.icon).tag(theme)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(library.appearance.title, systemImage: library.appearance.icon)
            }
        } label: {
            // 三条杠是自己画的，宽度/线宽/行距各自独立可调，见 HamburgerIcon
            HamburgerIcon().circleIcon()
        }
    }

    private func handleImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let (ok, failures) = await library.importBooks(from: urls)
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
    let progress: BookLibrary.ImportProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                // 一本的时候没有「几分之几」可言，转圈就够了；
                // 一批的时候要能看出还剩多少
                if progress.total > 1 {
                    ProgressView(value: progress.ratio).tint(Theme.accent).frame(width: 190)
                    Text("正在解析 \(progress.done) / \(progress.total)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                } else {
                    ProgressView().tint(Theme.accent)
                }

                if !progress.title.isEmpty {
                    Text("《\(progress.title)》")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                }
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
