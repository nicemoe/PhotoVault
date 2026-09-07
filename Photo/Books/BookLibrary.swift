import Foundation
import Observation

/// 书在磁盘上怎么摆：`Books/<书名>/0001 第一章 风起.txt`。
///
/// 早先是 `Books/<书的 UUID>/0.txt`——目录是一串 UUID、章节是纯数字。
/// 开了文件共享之后从访达打开看到的就是这个，哪本书哪一章全看不出来，
/// 而且原始的 txt/epub 拆完就没了，连「拿回原文件」都做不到。
enum BookPaths {
    static let root: URL = {
        let url = Paths.documents.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let indexFile = root.appendingPathComponent("books.json")

    static func directory(named dirName: String) -> URL {
        root.appendingPathComponent(dirName, isDirectory: true)
    }

    /// 每章单独一个文件。整本读进内存的话，一部几百万字的长篇会直接把 App 撑爆。
    ///
    /// 名字是「四位序号 + 章节名」。序号是补零的，一来在访达里按名字排就是
    /// 正确的顺序，二来它天然唯一——一本书里叫「第一章」的可能不止一处，
    /// 光靠章节名会撞，加了序号就不用再存一份文件名进索引。
    static func chapterName(index: Int, title: String) -> String {
        let clean = FileNames.sanitize(title, limit: 60)
        return String(format: "%04d", index + 1) + " " + clean + ".txt"
    }

    static func chapterFile(dirName: String, index: Int, title: String) -> URL {
        directory(named: dirName).appendingPathComponent(chapterName(index: index, title: title))
    }
}

/// 文件名和目录名的清洗。
///
/// 不只是为了 iOS：这些文件迟早要从访达拖到 Windows 上去，所以按更严的
/// 那一套来——Windows 不认 \ / : * ? " < > |，也不许结尾是点或空格。
enum FileNames {

    static func sanitize(_ raw: String, limit: Int = 80) -> String {
        let banned = Set<Character>("\\/:*?\"<>|")
        var out = ""
        out.reserveCapacity(raw.count)
        for c in raw {
            if banned.contains(c) || c.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                out.append("_")
            } else {
                out.append(c)
            }
        }
        // 结尾的点和空格在 Windows 上会被悄悄吃掉，先去掉免得对不上
        while let last = out.last, last == "." || last == " " { out.removeLast() }
        if out.count > limit { out = String(out.prefix(limit)) }
        return out.isEmpty ? "未命名" : out
    }

    /// 在一堆已占用的名字里挑一个不重的：「斗破苍穹」「斗破苍穹 (2)」…
    /// 比较不分大小写——iOS 的文件系统不分，拷到 Windows 上也不分。
    static func unique(_ base: String, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(base.lowercased()) else { return base }
        var n = 2
        while true {
            let candidate = "\(base) (\(n))"
            if !lowered.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
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
        migrateToNamedLayout()
    }

    /// 老版本把书存成 `Books/<书的 UUID>/0.txt`——目录是一串 UUID、章节是
    /// 纯数字。开了文件共享之后从访达打开看到的就是这个，哪本书哪一章都
    /// 看不出来。这里把已经进来的书搬成 `Books/<书名>/0001 第一章 ….txt`。
    ///
    /// 只会跑一次：搬完 dirName 就有值了，下次启动直接跳过。
    private func migrateToNamedLayout() {
        var changed = false
        let fm = FileManager.default

        for i in books.indices where books[i].dirName.isEmpty {
            let taken = Set(books.enumerated().compactMap { $0.offset == i ? nil : $0.element.dirName })
            let dirName = FileNames.unique(FileNames.sanitize(books[i].title), taken: taken)

            let old = BookPaths.root.appendingPathComponent(books[i].id.uuidString, isDirectory: true)
            let new = BookPaths.directory(named: dirName)

            // 先把目录改名，再逐章把 0.txt 改成 0001 第一章 ….txt。
            // 目录不在（数据坏了或者手动删过）也要把 dirName 补上，
            // 否则每次启动都会重来一遍。
            if fm.fileExists(atPath: old.path) {
                try? fm.moveItem(at: old, to: new)
            }
            for chapter in books[i].chapters {
                let from = new.appendingPathComponent("\(chapter.index).txt")
                guard fm.fileExists(atPath: from.path) else { continue }
                let to = new.appendingPathComponent(
                    BookPaths.chapterName(index: chapter.index, title: chapter.title))
                if from != to { try? fm.moveItem(at: from, to: to) }
            }

            books[i].dirName = dirName
            changed = true
        }

        if changed { saveNow() }
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

    /// 按需读某一章的正文。
    ///
    /// 真正干活的是下面那个 nonisolated 版本：全文搜索要在后台跑，
    /// 读不到 @MainActor 的 books，所以由调用方先把目录名和章节信息取出来。
    func chapterText(bookID: UUID, index: Int) -> String {
        guard let book = book(bookID), book.chapters.indices.contains(index) else { return "" }
        return Self.chapterText(dirName: book.dirName, chapter: book.chapters[index])
    }

    nonisolated static func chapterText(dirName: String, chapter: ChapterMeta) -> String {
        let url = BookPaths.chapterFile(dirName: dirName, index: chapter.index, title: chapter.title)
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
        let dirName = FileNames.unique(FileNames.sanitize(parsed.title),
                                       taken: Set(books.map(\.dirName)))

        let (metas, total) = await Task.detached(priority: .userInitiated) {
            () -> ([ChapterMeta], Int) in
            // 目录建一次就够。原来每章都通过 chapterFile() 走一遍 directory()，
            // 而它里面有 createDirectory —— 一本 500 章的书就是 500 次多余的
            // 系统调用，一次导入上千本时这笔账很吓人。
            let dir = BookPaths.directory(named: dirName)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            var metas: [ChapterMeta] = []
            var total = 0
            for (i, chapter) in chapters.enumerated() {
                let body = chapter.body
                // 不用 .atomic。索引是在全部章节写完之后才写的，中途被杀只会
                // 留下一堆没人引用的孤儿文件，不会产生半本坏书；而 atomic 要
                // 先写临时文件再 rename，每章多一倍的文件系统操作。
                let name = BookPaths.chapterName(index: i, title: chapter.title)
                try? Data(body.utf8).write(to: dir.appendingPathComponent(name))
                metas.append(ChapterMeta(index: i, title: chapter.title,
                                         characterCount: body.count))
                total += body.count
            }
            return (metas, total)
        }.value

        let book = Book(id: bookID,
                        title: parsed.title,
                        dirName: dirName,
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
    nonisolated func search(dirName: String, chapters: [ChapterMeta],
                            keyword: String, limit: Int = 200) async -> [SearchHit] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 1 else { return [] }

        var hits: [SearchHit] = []
        for meta in chapters {
            if Task.isCancelled { return hits }

            let text = Self.chapterText(dirName: dirName, chapter: meta)
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

        // 磁盘上的目录跟着改名，不然共享目录里还挂着旧书名
        let taken = Set(books.enumerated().compactMap { $0.offset == i ? nil : $0.element.dirName })
        let newDir = FileNames.unique(FileNames.sanitize(trimmed), taken: taken)
        let oldDir = books[i].dirName
        if newDir != oldDir, !oldDir.isEmpty {
            try? FileManager.default.moveItem(at: BookPaths.directory(named: oldDir),
                                              to: BookPaths.directory(named: newDir))
            books[i].dirName = newDir
        }
        scheduleSave()
    }

    func delete(bookID: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        let removed = books.remove(at: i)
        if !removed.dirName.isEmpty {
            try? FileManager.default.removeItem(at: BookPaths.directory(named: removed.dirName))
        }
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
