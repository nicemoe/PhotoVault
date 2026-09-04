import SwiftUI
import UniformTypeIdentifiers

struct BookshelfView: View {

    @Environment(BookLibrary.self) private var library
    @Environment(WiFiService.self) private var wifi

    @State private var showImporter = false
    @State private var openedBook: UUID?
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
                    } else {
                        LazyVGrid(columns: layout.columns, spacing: 22) {
                            ForEach(visibleBooks) { book in
                                Button {
                                    openedBook = book.id
                                } label: {
                                    BookCard(book: book, side: layout.side)
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
            .navigationDestination(item: $openedBook) { id in
                ReaderView(bookID: id)
            }
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

    /// epub 系统没有内置 UTType，用文件扩展名兜底
    private static var allowedTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        if let epub = UTType(filenameExtension: "epub") { types.append(epub) }
        if let epubID = UTType("org.idpf.epub-container") { types.append(epubID) }
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            Task {
                var ok = 0
                var lastError: String?
                for url in urls {
                    do {
                        try await library.importBook(from: url)
                        ok += 1
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
                if ok > 0 {
                    toastItem = Toast(icon: "books.vertical.fill", text: "已导入 \(ok) 本")
                }
                if let lastError, ok < urls.count {
                    errorMessage = lastError
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
