import Foundation
import Observation

/// 书相关的磁盘布局。和相册的 library.json 完全独立，互不影响。
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

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = try c.decodeIfPresent([Book].self, forKey: .books) ?? []
        settings = try c.decodeIfPresent(ReaderSettings.self, forKey: .settings) ?? ReaderSettings()
    }

    enum CodingKeys: String, CodingKey { case books, settings }
}

@MainActor
@Observable
final class BookLibrary {

    private(set) var books: [Book] = []
    var settings = ReaderSettings() {
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
    }

    private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = BookIndex.make(books: books, settings: settings)
        saveTask = Task { [snapshot] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let snapshot = BookIndex.make(books: books, settings: settings)
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

        // 落盘：每章一个文件
        let bookID = UUID()
        var metas: [ChapterMeta] = []
        var total = 0
        for (i, chapter) in parsed.chapters.enumerated() {
            let body = chapter.body
            let file = BookPaths.chapterFile(bookID: bookID, index: i)
            try? Data(body.utf8).write(to: file, options: .atomic)
            metas.append(ChapterMeta(index: i, title: chapter.title, characterCount: body.count))
            total += body.count
        }

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
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + fileName)
        try data.write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try await importBook(from: temp)
    }

    // MARK: 修改

    func updateProgress(bookID: UUID, chapterIndex: Int, characterOffset: Int) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].progress = ReadingProgress(chapterIndex: chapterIndex,
                                            characterOffset: characterOffset,
                                            updatedAt: Date())
        scheduleSave()
    }

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
    static func make(books: [Book], settings: ReaderSettings) -> BookIndex {
        var index = BookIndex()
        index.books = books
        index.settings = settings
        return index
    }
}
