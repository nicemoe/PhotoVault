import Foundation
import Observation

/// 书相关的磁盘布局。索引一个 json，正文按章拆成一堆小文件。
enum BookPaths {
    static let root: URL = {
        let url = Paths.documents.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let indexFile = root.appendingPathComponent("books.json")

    static func directory(for bookID: UUID) -> URL {
        let url = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 每章单独一个文件。整本读进内存的话，一部几百万字的长篇会直接把 App 撑爆。
    static func chapterFile(bookID: UUID, index: Int) -> URL {
        directory(for: bookID).appendingPathComponent("\(index).txt")
    }
}

private struct BookIndex: Codable {
    var books: [Book] = []
    var settings = ReaderSettings()
    /// 书架布局是书架的偏好，不属于阅读设置，所以单独放一层
    var shelfLayout: ShelfLayout = .grid
    /// 全局外观。原来在相册那边的数据仓库里，拆成独立 App 后归到这儿。
    var appearance: AppTheme = .system

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = try c.decodeIfPresent([Book].self, forKey: .books) ?? []
        settings = try c.decodeIfPresent(ReaderSettings.self, forKey: .settings) ?? ReaderSettings()
        shelfLayout = try c.decodeIfPresent(ShelfLayout.self, forKey: .shelfLayout) ?? .grid
        appearance = try c.decodeIfPresent(AppTheme.self, forKey: .appearance) ?? .system
    }

    enum CodingKeys: String, CodingKey { case books, settings, shelfLayout, appearance }
}

@MainActor
@Observable
final class BookLibrary {

    private(set) var books: [Book] = []
    var settings = ReaderSettings() {
        didSet { scheduleSave() }
    }
    var shelfLayout: ShelfLayout = .grid {
        didSet { scheduleSave() }
    }
    var appearance: AppTheme = .system {
        didSet { scheduleSave() }
    }

    /// 导入进度，nil 表示没有在导入
    private(set) var importingTitle: String?

    init() {
        load()
    }

    // MARK: 读写

    private func load() {
        guard let data = try? Data(contentsOf: BookPaths.indexFile),
              let index = try? Coders.makeDecoder().decode(BookIndex.self, from: data) else { return }
        books = index.books
        settings = index.settings
        shelfLayout = index.shelfLayout
        appearance = index.appearance
        repairTitles()
    }

    /// 把已经存坏的书名修回来。
    ///
    /// 网页上传那条路以前拿 UUID 当前缀拼临时文件名，而书名是从文件名取的，
    /// 于是那批书全叫「<一长串 UUID>-书名」。导入那边已经改了，但已经进来的
    /// 书还顶着这个名字，总不能让人一本本手动改。
    private func repairTitles() {
        var fixed = false
        for i in books.indices {
            let clean = Self.stripUUIDPrefix(books[i].title)
            guard clean != books[i].title, !clean.isEmpty else { continue }
            books[i].title = clean
            fixed = true
        }
        if fixed { scheduleSave() }
    }

    /// 开头是不是「8-4-4-4-12 个十六进制字符 + 短横」，是就剁掉
    private static func stripUUIDPrefix(_ title: String) -> String {
        let groups = [8, 4, 4, 4, 12]
        var index = title.startIndex
        for (n, count) in groups.enumerated() {
            for _ in 0..<count {
                guard index < title.endIndex, title[index].isHexDigit else { return title }
                index = title.index(after: index)
            }
            // 每组后面都跟一个短横，最后一组后面那个是和书名之间的分隔
            guard index < title.endIndex, title[index] == "-" else { return title }
            index = title.index(after: index)
            _ = n
        }
        return String(title[index...])
    }

    private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = BookIndex.make(books: books, settings: settings, shelfLayout: shelfLayout, appearance: appearance)
        saveTask = Task { [snapshot] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let snapshot = BookIndex.make(books: books, settings: settings, shelfLayout: shelfLayout, appearance: appearance)
        Task.detached(priority: .utility) { await Self.write(snapshot) }
    }

    private nonisolated static func write(_ snapshot: BookIndex) async {
        guard let data = try? Coders.makeEncoder().encode(snapshot) else { return }
        try? data.write(to: BookPaths.indexFile, options: .atomic)
    }

    // MARK: 查询

    var sortedBooks: [Book] {
        // 最近读过的排前面，没读过的按加入时间
        books.sorted { a, b in
            let ka = max(a.progress.updatedAt, a.addedAt)
            let kb = max(b.progress.updatedAt, b.addedAt)
            return ka > kb
        }
    }

    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }

    /// 按需读某一章的正文
    nonisolated func chapterText(bookID: UUID, index: Int) -> String {
        let url = BookPaths.chapterFile(bookID: bookID, index: index)
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 导入

    enum ImportError: LocalizedError {
        case unsupported(String)
        case decodeFailed
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "暂不支持 .\(ext) 格式，目前支持 TXT 和 EPUB"
            case .decodeFailed:         return "文件编码无法识别，可能已损坏"
            case .empty:                return "文件里没有可阅读的内容"
            }
        }
    }

    @discardableResult
    func importBook(from url: URL) async throws -> Book {
        let ext = url.pathExtension.lowercased()
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        importingTitle = fallbackTitle
        defer { importingTitle = nil }

        // 从「文件」App 拿到的是受保护的 URL，必须成对开关
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)

        // 解析放后台，长篇 TXT 的正则切分很吃 CPU
        let parsed: (title: String, author: String, chapters: [ParsedChapter])
        switch ext {
        case "txt":
            parsed = try await Task.detached(priority: .userInitiated) {
                guard let text = TextDecoding.decode(data) else { throw ImportError.decodeFailed }
                let chapters = ChapterSplitter.split(text)
                guard !chapters.isEmpty else { throw ImportError.empty }
                return (fallbackTitle, "", chapters)
            }.value
        case "epub":
            parsed = try await Task.detached(priority: .userInitiated) {
                let result = try EpubParser.parse(data, fallbackTitle: fallbackTitle)
                return (result.title, result.author, result.chapters)
            }.value
        default:
            throw ImportError.unsupported(ext)
        }

        guard !parsed.chapters.isEmpty else { throw ImportError.empty }

        // 落盘：每章一个文件。整批导入时这一步才是大头，不是正则分章，
        // 所以三件事都要注意：目录只建一次、不走 atomic、别占着主线程。
        let bookID = UUID()
        let chapters = parsed.chapters
        let (metas, total) = await Task.detached(priority: .userInitiated) {
            () -> ([ChapterMeta], Int) in
            // 目录建一次就够。原来每章都通过 chapterFile() 走一遍 directory()，
            // 而它里面有 createDirectory —— 一本 500 章的书就是 500 次多余的
            // 系统调用，一次导入上千本时这笔账很吓人。
            let dir = BookPaths.directory(for: bookID)
            var metas: [ChapterMeta] = []
            var total = 0
            for (i, chapter) in chapters.enumerated() {
                let body = chapter.body
                // 不用 .atomic。索引是在全部章节写完之后才写的，中途被杀只会
                // 留下一堆没人引用的孤儿文件，不会产生半本坏书；而 atomic 要
                // 先写临时文件再 rename，每章多一倍的文件系统操作。
                try? Data(body.utf8).write(to: dir.appendingPathComponent("\(i).txt"))
                metas.append(ChapterMeta(index: i, title: chapter.title,
                                         characterCount: body.count))
                total += body.count
            }
            return (metas, total)
        }.value

        let book = Book(id: bookID,
                        title: parsed.title,
                        author: parsed.author,
                        format: ext == "epub" ? .epub : .txt,
                        chapters: metas,
                        totalCharacters: total,
                        colorIndex: abs(parsed.title.hashValue) % Theme.paletteHex.count)

        books.append(book)
        saveNow()
        return book
    }

    /// 网页端上传用：直接给数据和文件名
    @discardableResult
    func importBook(data: Data, fileName: String) async throws -> Book {
        // 临时文件放进一个独有的子目录，文件名保持原样。
        //
        // 原来是拿 UUID 当前缀直接拼在文件名前面防重名，但书名正是从文件名
        // 取的，于是从网页传上来的书全都叫「<一长串 UUID>-书名」。
        // 换成用目录隔离，重名照样避得开，文件名不用动。
        let box = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: box) }

        let temp = box.appendingPathComponent((fileName as NSString).lastPathComponent)
        try data.write(to: temp, options: .atomic)
        return try await importBook(from: temp)
    }

    /// 收走「导入」文件夹里的书。App 一进前台就跑一次。
    ///
    /// 导进来之后删掉原文件：内容已经拆成章存到 App 自己的目录里了，
    /// 留着只会让人以为还没导，下次进前台又导一遍。
    /// 返回收进来的本数，为 0 表示文件夹是空的或者里面没有能认的格式。
    @discardableResult
    func importFromInbox() async -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: Paths.inbox,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return 0 }

        var files: [URL] = []
        for case let url as URL in walker {
            guard Self.importableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append(url)
        }
        guard !files.isEmpty else { return 0 }

        var saved = 0
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? await importBook(from: url)) != nil else { continue }
            try? fm.removeItem(at: url)
            saved += 1
        }

        // 收完之后把空掉的子文件夹一并清掉，文件夹里就只剩说明文件
        if let subdirs = try? fm.contentsOfDirectory(at: Paths.inbox,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) {
            for dir in subdirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if let left = try? fm.contentsOfDirectory(atPath: dir.path), left.isEmpty {
                    try? fm.removeItem(at: dir)
                }
            }
        }
        return saved
    }

    private static let importableExtensions: Set<String> = ["txt", "epub"]

    // MARK: 全文搜索

    struct SearchHit: Identifiable, Hashable {
        var id = UUID()
        var chapterIndex: Int
        var chapterTitle: String
        /// 命中位置在章内的字符偏移，跳转时直接用
        var offset: Int
        /// 命中处上下文，关键词用 【】 标出来
        var snippet: String
    }

    /// 逐章读文件搜索。整本几百万字，必须在后台跑，而且要能被取消——
    /// 用户还在打字时上一次搜索就该停下，否则会积压一堆任务。
    nonisolated func search(bookID: UUID, chapters: [ChapterMeta], keyword: String, limit: Int = 200) async -> [SearchHit] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 1 else { return [] }

        var hits: [SearchHit] = []
        for meta in chapters {
            if Task.isCancelled { return hits }

            let text = chapterText(bookID: bookID, index: meta.index)
            guard !text.isEmpty else { continue }

            var cursor = text.startIndex
            while let found = text.range(of: key, options: .caseInsensitive, range: cursor..<text.endIndex) {
                let offset = text.distance(from: text.startIndex, to: found.lowerBound)

                let lead = text.index(found.lowerBound, offsetBy: -18, limitedBy: text.startIndex) ?? text.startIndex
                let tail = text.index(found.upperBound, offsetBy: 18, limitedBy: text.endIndex) ?? text.endIndex
                let snippet = (String(text[lead..<found.lowerBound])
                               + "【" + String(text[found]) + "】"
                               + String(text[found.upperBound..<tail]))
                    .replacingOccurrences(of: "\n", with: " ")

                hits.append(SearchHit(chapterIndex: meta.index,
                                      chapterTitle: meta.title,
                                      offset: offset,
                                      snippet: snippet))
                if hits.count >= limit { return hits }

                cursor = found.upperBound
            }
        }
        return hits
    }

    // MARK: 修改

    func updateProgress(bookID: UUID, chapterIndex: Int, characterOffset: Int) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].progress = ReadingProgress(chapterIndex: chapterIndex,
                                            characterOffset: characterOffset,
                                            updatedAt: Date())
        scheduleSave()
    }

    // MARK: 书签

    /// 当前页是否已经有书签。按「同一章 + 偏移落在本页范围内」判断，
    /// 而不是要求偏移完全相等——排版一变，同一句话的偏移就不同了。
    func bookmark(bookID: UUID, chapter: Int, pageRange: Range<Int>) -> Bookmark? {
        book(bookID)?.bookmarks.first {
            $0.chapterIndex == chapter && pageRange.contains($0.characterOffset)
        }
    }

    @discardableResult
    func addBookmark(bookID: UUID, chapter: Int, offset: Int, title: String, snippet: String) -> Bookmark? {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return nil }
        let mark = Bookmark(chapterIndex: chapter,
                            characterOffset: offset,
                            chapterTitle: title,
                            snippet: snippet)
        books[i].bookmarks.append(mark)
        saveNow()
        return mark
    }

    func removeBookmark(bookID: UUID, markID: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].bookmarks.removeAll { $0.id == markID }
        saveNow()
    }

    /// 书签列表：新加的排前面
    func bookmarks(bookID: UUID) -> [Bookmark] {
        (book(bookID)?.bookmarks ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: 修改

    func rename(bookID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].title = trimmed
        scheduleSave()
    }

    func delete(bookID: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books.remove(at: i)
        try? FileManager.default.removeItem(at: BookPaths.directory(for: bookID))
        saveNow()
    }
}

private extension BookIndex {
    static func make(books: [Book], settings: ReaderSettings,
                     shelfLayout: ShelfLayout, appearance: AppTheme) -> BookIndex {
        var index = BookIndex()
        index.books = books
        index.settings = settings
        index.shelfLayout = shelfLayout
        index.appearance = appearance
        return index
    }
}
