import Foundation
import Observation

/// 书在磁盘上怎么摆。
///
///     Documents/                 ← 访达里看得到的，只有人自己的东西
///       Books/
///         斗破苍穹.txt          ← 一本书就一个文件，UTF-8
///         三体.txt
///
///     Library/Application Support/   ← App 内部，访达里看不到
///       books.json              ← 书目 + 阅读进度 + 书签
///       Chapters/
///         <书的 id>.json        ← 这本书每章的标题 + 起始字节 + 长度
///
/// 分工是「这东西是谁的」：txt 是人的，索引和章节表是我们记账用的。
/// 索引摆在书旁边只会让人误以为该管它，手改坏了还连累阅读进度。
///
/// 一本书一个文件，不再按章拆成几百个小文件。
///
/// 拆成小文件的理由本来是「排版和内存要按章来」，但那只要求*读*的时候
/// 一章一章读，不要求*存*的时候一章一个文件。改成记字节范围之后，读一章
/// 就是 seek 到偏移读一段，一样按需，代价却小得多：一千本书从五十万个
/// 文件变成一千个。之前「导入解析很久」和那次启动看门狗闪退，大头就是
/// 这五十万次文件系统调用。
///
/// 编码在导入那一刻就统一成 UTF-8 了。GBK 也好、epub 也好，都只是文件
/// 从哪儿下载来的痕迹，不是想要的形态——收进来的时候一次收拾干净，
/// 后面所有偏移都指着同一种编码，不用再判断。
enum BookPaths {

    static let root: URL = {
        let url = Paths.documents.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // 放一份说明。用 .md，不在收书的后缀里，不会把自己当成一本书收进去。
        let readme = url.appendingPathComponent("使用说明.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            let text = """
            # 书库

            一本书 = 一个 UTF-8 的 txt 文件。想加书就直接丢进这个文件夹，
            回到 App 就会自动收进书架；整个文件夹丢进来也行，里面的书会被
            拿出来平铺到这一层。

            收进来的时候会做两件事，之后这个文件就是最终形态：

            - **编码统一转成 UTF-8**。GBK 的会就地转掉，原来那份不留——
              那只是从别处下载时碰巧带的编码，不是你要的东西。
            - **EPUB 会被抽成 txt，原来的 .epub 删掉**。同理。

            这个文件夹里只有 txt，没有 App 自己记账的东西——书目、阅读进度、
            章节位置都收在 App 内部，不用也不该在这儿管。

            在这里删掉某本书的 txt，App 里那本也会跟着消失；
            在 App 里删书，这里的文件也会被删。
            """
            try? Data(text.utf8).write(to: readme, options: .atomic)
        }
        return url
    }()

    /// 书目、阅读进度、书签。一千本约 460 KB。
    ///
    /// 早先放在 Documents 里，还给它打过 BSD 的 immutable 标志让访达改不动。
    /// 那是在补一个不该存在的问题——搬进内部目录，它压根就不出现在那儿。
    static let indexFile: URL = {
        let url = AppStore.file("books.json")
        AppStore.migrateFromDocuments("books.json", to: url)
        return url
    }()

    static func file(named name: String) -> URL {
        root.appendingPathComponent(name)
    }

    /// 章节表放这儿，一本书一个文件。
    ///
    /// 不进 books.json，因为它太大又太不常变：一本 1600 章的书章节表就
    /// 270 KB，一千本 270 MB，而 books.json 每翻一页都要整个重写一遍——
    /// 一小时阅读能写掉几十 GB。分开之后 books.json 只剩书目和进度，
    /// 一千本约 460 KB，章节表只在打开那本书时读。
    ///
    /// 也不放 Documents：它是照着正文算出来的派生数据，不是人的东西，
    /// 访达里不该看见，丢了也能重拆。用 Application Support 而不是
    /// Caches——Caches 系统会挑时候清掉，清一次就是一千本书重拆一遍。
    static let chaptersRoot: URL = {
        let url = AppStore.root.appendingPathComponent("Chapters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // 章节表能从正文重拆，没必要让它把 iCloud 备份撑大。
        // 索引不排除——阅读进度和书签只此一份，换手机时正该跟过去。
        AppStore.excludeFromBackup(url)
        return url
    }()

    static func chapterFile(for bookID: UUID) -> URL {
        chaptersRoot.appendingPathComponent(bookID.uuidString + ".json")
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
    /// 书架布局是书架的偏好，不属于阅读设置，所以单独放一层。
    /// 默认列表：书多起来之后一屏能看到的书名多得多，封面本来就只是配色块。
    var shelfLayout: ShelfLayout = .list
    /// 全局外观。原来在相册那边的数据仓库里，拆成独立 App 后归到这儿。
    var appearance: AppTheme = .system

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = try c.decodeIfPresent([Book].self, forKey: .books) ?? []
        settings = try c.decodeIfPresent(ReaderSettings.self, forKey: .settings) ?? ReaderSettings()
        shelfLayout = try c.decodeIfPresent(ShelfLayout.self, forKey: .shelfLayout) ?? .list
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
    var shelfLayout: ShelfLayout = .list {
        didSet { scheduleSave() }
    }
    var appearance: AppTheme = .system {
        didSet { scheduleSave() }
    }

    /// 导入进度。总数是开工前就数好的——一次丢一千本进来，
    /// 只显示「正在解析《某某》」的话，人不知道还要等多久。
    struct ImportProgress {
        var done: Int
        var total: Int
        var title: String

        var ratio: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// nil 表示没有在导入
    private(set) var importing: ImportProgress?

    /// 正在扫书库。挡住重入，见 importLooseFiles。
    private var isScanning = false

    /// 手上摊开的那本书的章节表。一次只留一本——人不会同时读两本，
    /// 而每本几百 KB，全留着就等于把搬出去的东西又搬回内存里。
    private var openBook: (id: UUID, chapters: [ChapterMeta])?

    init() {
        load()
    }

    // MARK: 读写

    /// 读索引。读不到就当书架是空的，然后靠 Books 里的文件重建。
    ///
    /// 索引不是唯一的真相，书本身才是——每本书就是 Books 下的一个 txt。
    /// 所以 books.json 被删、被写坏、根本没建过，都不该是个死局：
    /// 空着起来，第一次对账时目录里的文件一个都对不上号，全当新书收一遍，
    /// 书架就长回来了。丢的只有阅读进度和书签，那两样确实只存在索引里。
    ///
    /// 「文件不存在」和「文件在但解不开」要分开对待。前者是正常的（第一次
    /// 启动就是这样），后者说明本来有东西、现在读不出来了——先把它挪到旁边
    /// 留个底再重建，不然第一次自动保存就把还能救的进度盖掉了。
    private func load() {
        guard let data = try? Data(contentsOf: BookPaths.indexFile) else { return }
        guard let index = try? Coders.makeDecoder().decode(BookIndex.self, from: data) else {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.moveItem(
                at: BookPaths.indexFile,
                to: AppStore.file("books.损坏-\(stamp).json"))
            return
        }
        books = index.books
        settings = index.settings
        shelfLayout = index.shelfLayout
        appearance = index.appearance
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

    /// 某本书的章节表。打开书时来一次，之后就在手上了。
    ///
    /// 三级：手上这本直接给；不是的话从 App 内部目录读那本的章节表；
    /// 再没有（第一次跑这个版本、内部目录被清过）就照着正文重拆一遍。
    /// 最后这条路让章节表变成纯粹的缓存——丢了不影响能不能读，只是慢一次。
    func chapters(of bookID: UUID) async -> [ChapterMeta] {
        if let openBook, openBook.id == bookID { return openBook.chapters }
        guard let book = book(bookID) else { return [] }

        let stored = await Task.detached(priority: .userInitiated) {
            Self.readChapters(bookID: bookID)
        }.value
        if !stored.isEmpty {
            openBook = (bookID, stored)
            return stored
        }

        guard let rebuilt = await rebuildChapters(for: book), !rebuilt.isEmpty else { return [] }
        openBook = (bookID, rebuilt)
        return rebuilt
    }

    /// 按需读某一章的正文。走手上那本的章节表，所以只在书打开着的时候有效——
    /// 而会问这个的（分页、书签摘录）本来就只在阅读页里。
    ///
    /// 真正干活的是下面那个 nonisolated 版本：全文搜索要在后台跑，
    /// 读不到 @MainActor 的 books，所以由调用方先把文件名和章节信息取出来。
    func chapterText(bookID: UUID, index: Int) -> String {
        guard let book = book(bookID), let openBook, openBook.id == bookID,
              openBook.chapters.indices.contains(index) else { return "" }
        return Self.chapterText(fileName: book.sourceName, chapter: openBook.chapters[index])
    }

    /// seek 到偏移，读这一章那几万字节，解成字符串。
    ///
    /// 整本书都在一个文件里，但读的时候只碰这一段——按需的粒度没变，
    /// 变的只是「一章一个文件」换成了「一个文件里的一段」。
    /// 偏移是导入时按 UTF-8 编码算出来的，天然落在字符边界上。
    nonisolated static func chapterText(fileName: String, chapter: ChapterMeta) -> String {
        guard !fileName.isEmpty, chapter.byteLength > 0 else { return "" }
        guard let handle = try? FileHandle(forReadingFrom: BookPaths.file(named: fileName)) else { return "" }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(chapter.byteOffset))
            guard let data = try handle.read(upToCount: chapter.byteLength) else { return "" }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
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
        // 批量导入时总数由调用方先数好；单本进来的自己开一个 1/1
        let standalone = (importing == nil)
        if standalone { importing = ImportProgress(done: 0, total: 1, title: fallbackTitle) }
        else { importing?.title = fallbackTitle }
        defer {
            importing?.done += 1
            if standalone { importing = nil }
        }

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

        // 落盘：整本拼成一个 UTF-8 文件，章节只在索引里记字节范围。
        //
        // 原来是每章一个文件，一本 500 章的书就是 500 次写盘、500 次建目录；
        // 一次导一千本，光文件系统调用就几十万次——之前「解析很久」和那次
        // 启动看门狗闪退，大头都在这儿。现在一本书一次写盘。
        let chapters = parsed.chapters
        let stem = FileNames.unique(
            FileNames.sanitize(parsed.title),
            taken: Set(books.map { ($0.sourceName as NSString).deletingPathExtension }))

        let bookID = UUID()
        let built = await Task.detached(priority: .userInitiated) {
            () -> (metas: [ChapterMeta], characters: Int, bytes: Int, name: String)? in
            guard let made = Self.writeText(chapters: chapters, stem: stem, replacing: url)
            else { return nil }
            // 章节表跟着一起落盘，不进 books.json
            Self.writeChapters(made.metas, for: bookID)
            return made
        }.value
        guard let built else { throw ImportError.empty }

        let book = Book(id: bookID,
                        title: parsed.title,
                        sourceName: built.name,
                        textBytes: built.bytes,
                        author: parsed.author,
                        format: ext == "epub" ? .epub : .txt,
                        chapterCount: built.metas.count,
                        totalCharacters: built.characters,
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

    /// 一次导一批。总数先摆出来，进度浮层才有「几分之几」可显示——
    /// 一次选一百本却只看到「正在解析《某某》」，人不知道还要等多久。
    @discardableResult
    func importBooks(from urls: [URL]) async -> (ok: Int, failures: [String]) {
        guard !urls.isEmpty else { return (0, []) }
        importing = ImportProgress(done: 0, total: urls.count, title: "")
        defer { importing = nil }

        var ok = 0
        var failures: [String] = []
        for url in urls {
            do {
                try await importBook(from: url)
                ok += 1
            } catch {
                // 带上文件名，一次选多本时才知道是哪本没进来
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return (ok, failures)
    }

    /// 收书库里还没收过的书。
    ///
    /// 「哪些是新的」是拿索引对出来的：每本书都记着自己的正文文件叫什么
    /// （sourceName），书库里对不上号的就是新拖进来的。不用比文件数——
    /// 比数不可靠，删一个加一个数字还一样。
    func importLooseFiles() async -> Int {
        // 两个触发点（视图首次出现、从后台切回前台）可能挨着来。不挡一下的话
        // 两次扫描会看到同一批新文件，各自导一遍，同一本书出现两条。
        guard !isScanning else { return 0 }
        isScanning = true
        defer { isScanning = false }

        let known = Set(books.map(\.sourceName).filter { !$0.isEmpty }.map { $0.lowercased() })
        // 扫盘甩到后台：一千个文件走一遍目录树也要点时间
        guard let all = await Task.detached(priority: .utility) { Self.scanLibrary() }.value
        else { return 0 }
        let fresh = all.filter { !known.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return 0 }

        // 先把总数摆出来再开工，不然一千本书就是干等着，不知道到哪了
        importing = ImportProgress(done: 0, total: fresh.count, title: "")
        defer { importing = nil }

        var saved = 0
        for name in fresh.sorted() {
            let url = BookPaths.file(named: name)
            guard (try? await importBook(from: url)) != nil else { continue }
            saved += 1
        }
        return saved
    }

    /// 在访达里改过的书，重新拆一遍。
    ///
    /// 章节记的是字节范围，而正文文件就摆在共享目录里，人随时能打开改两笔。
    /// 一改，后面每一章的偏移就整体错位，而且是静悄悄地错——点开某一章，
    /// 读出来是上一章的半句话。所以每次对账都拿文件大小校一下，对不上就重拆。
    ///
    /// 阅读进度和书签留着：那是人自己的东西，不是从文件生成的。章数变少了
    /// 就把进度夹回范围内，总比整本回到第一页强。
    @discardableResult
    func refreshEdited() async -> Int {
        // 和 importLooseFiles 共用一把锁：两个触发点挨着来的话，
        // 后一次会看到前一次还没写回 textBytes 的书，白重拆一遍。
        guard !isScanning else { return 0 }
        isScanning = true
        defer { isScanning = false }

        let sizes = await Task.detached(priority: .utility) { Self.fileSizes() }.value
        let stale: [(id: UUID, name: String)] = books.compactMap { book in
            guard !book.sourceName.isEmpty, book.textBytes > 0,
                  let size = sizes[book.sourceName.lowercased()],
                  size != book.textBytes else { return nil }
            return (book.id, book.sourceName)
        }
        guard !stale.isEmpty else { return 0 }

        importing = ImportProgress(done: 0, total: stale.count, title: "")
        defer { importing = nil }

        var done = 0
        for (id, name) in stale {
            // 每轮都重新找一遍：这中间 await 过，books 可能已经变了
            guard let book = book(id), book.sourceName == name else { continue }
            importing?.title = book.title
            let rebuilt = await rebuildChapters(for: book)
            importing?.done += 1

            guard let rebuilt, let j = books.firstIndex(where: { $0.id == id }) else { continue }
            // 章少了的话，进度可能指着一章已经不存在的地方，夹回范围内
            if books[j].progress.chapterIndex >= rebuilt.count {
                books[j].progress = ReadingProgress(
                    chapterIndex: max(0, rebuilt.count - 1), updatedAt: books[j].progress.updatedAt)
            }
            done += 1
        }
        if done > 0 { saveNow() }
        return done
    }

    /// 照着正文重拆一遍，章节表跟着更新。
    ///
    /// 三种情况会走到这儿：文件在访达里被改过、章节表丢了（内部目录被清、
    /// 从旧版本升上来）、以及第一次打开一本还没有章节表的书。
    /// 三种都是同一件事——正文才是真的，章节表照着它重算。
    @discardableResult
    private func rebuildChapters(for book: Book) async -> [ChapterMeta]? {
        let name = book.sourceName
        guard !name.isEmpty else { return nil }
        let bookID = book.id

        let built = await Task.detached(priority: .userInitiated) {
            () -> (metas: [ChapterMeta], characters: Int, bytes: Int, name: String)? in
            let url = BookPaths.file(named: name)
            guard let data = try? Data(contentsOf: url),
                  let text = TextDecoding.decode(data) else { return nil }
            let chapters = ChapterSplitter.split(text)
            guard !chapters.isEmpty else { return nil }
            guard let made = Self.writeText(chapters: chapters,
                                            stem: (name as NSString).deletingPathExtension,
                                            replacing: url) else { return nil }
            Self.writeChapters(made.metas, for: bookID)
            return made
        }.value
        guard let built else { return nil }

        if let i = books.firstIndex(where: { $0.id == bookID }) {
            books[i].sourceName = built.name
            books[i].textBytes = built.bytes
            books[i].chapterCount = built.metas.count
            books[i].totalCharacters = built.characters
            saveNow()
        }
        if openBook?.id == bookID { openBook = (bookID, built.metas) }
        return built.metas
    }

    /// 清掉认不出主人的章节表。
    ///
    /// 正常路径上删书会顺手删掉它——App 里删书、或者在访达里删了 txt 之后
    /// 对账清记录，两条路都删。但有几种情况漏得下：
    ///
    /// - books.json 被删或写坏之后，书全部重新收一遍，拿的是新的 id，
    ///   旧的那一批章节表就全成了孤儿，再没人会去删它们
    /// - 章节表写完了、索引还没落盘，App 就被杀掉
    ///
    /// 一本书的章节表几十上百 KB，一千本攒下来就是几十 MB 的死数据，
    /// 而且它在 App 内部目录里，人自己看不见也清不掉。所以每次对账兜一次底。
    nonisolated private static func sweepChapters(keeping live: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: BookPaths.chaptersRoot.path)
        else { return }
        for name in names where name.hasSuffix(".json") && !live.contains(name) {
            try? fm.removeItem(at: BookPaths.chaptersRoot.appendingPathComponent(name))
        }
    }

    /// 索引里这些书，各自的章节表文件该叫什么
    private var liveChapterFiles: Set<String> {
        Set(books.map { $0.id.uuidString + ".json" })
    }

    /// 对账的最后一步：把没人认领的章节表清掉。
    ///
    /// 单独一个方法而不是塞进 pruneMissingSources：那个是「原文件没了就删书」，
    /// 只看得到索引里还有的书；孤儿章节表的主人早就不在索引里了，
    /// 得反过来从磁盘那边数。
    func sweepOrphanChapters() async {
        // 书架空着的时候不扫。那可能是索引刚被删、书还没重收进来，
        // 这会儿把章节表全清掉，等于逼着一千本书重拆一遍。
        // 而真的一本书都没有的话，每本删的时候已经把自己那份带走了。
        guard !books.isEmpty else { return }
        let live = liveChapterFiles
        await Task.detached(priority: .utility) { Self.sweepChapters(keeping: live) }.value
    }

    // MARK: 章节表的读写

    nonisolated private static func writeChapters(_ list: [ChapterMeta], for bookID: UUID) {
        guard let data = try? Coders.makeEncoder().encode(list) else { return }
        try? data.write(to: BookPaths.chapterFile(for: bookID), options: .atomic)
    }

    nonisolated private static func readChapters(bookID: UUID) -> [ChapterMeta] {
        guard let data = try? Data(contentsOf: BookPaths.chapterFile(for: bookID)),
              let list = try? Coders.makeDecoder().decode([ChapterMeta].self, from: data)
        else { return [] }
        return list
    }

    /// 正文文件在书库里被删掉了，书也跟着走。
    ///
    /// 那个文件就是这本书本身，索引里存的偏移全指着它。文件没了，
    /// 剩下的章节目录只是一堆指向空气的字节范围，点开是白的。
    ///
    /// sourceName 是空串的跳过：那种书压根没记文件是哪个，
    /// 无从判断在不在，不能拿「找不到」当「被删了」。
    @discardableResult
    func pruneMissingSources() -> Int {
        // 扫不动就什么都别删。返回 nil 是「这次没看清」，不是「目录是空的」——
        // 把这两种当成一回事的话，一次扫描失败就能把整个书架清光。
        guard let names = Self.scanLibrary() else { return 0 }
        let onDisk = Set(names.map { $0.lowercased() })
        let doomed = books.filter { !$0.sourceName.isEmpty
            && !onDisk.contains($0.sourceName.lowercased()) }
        guard !doomed.isEmpty else { return 0 }

        let doomedIDs = Set(doomed.map(\.id))
        for id in doomedIDs {
            try? FileManager.default.removeItem(at: BookPaths.chapterFile(for: id))
        }
        if let openBook, doomedIDs.contains(openBook.id) { self.openBook = nil }
        books.removeAll { doomedIDs.contains($0.id) }
        saveNow()
        return doomed.count
    }

    /// 书库里所有能收的文件，返回相对书库根的路径。
    /// 子目录也翻——拖一整个文件夹进来是常事。收进来之后文件会被
    /// 归到根上（见 writeText），所以子目录只是个入口，不是长期形态。
    ///
    /// 返回 nil 表示这次根本没扫成（目录不在、打不开），和「扫完了，一个
    /// 文件都没有」是两回事：后者是删书的依据，前者不是。
    nonisolated private static func scanLibrary() -> [String]? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: BookPaths.root.path, isDirectory: &isDir), isDir.boolValue,
              let walker = fm.enumerator(at: BookPaths.root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return nil }
        let rootParts = BookPaths.root.standardizedFileURL.pathComponents
        var out: [String] = []
        for case let url as URL in walker {
            guard importableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let parts = url.standardizedFileURL.pathComponents
            guard parts.count > rootParts.count,
                  Array(parts.prefix(rootParts.count)) == rootParts else { continue }
            out.append(parts.dropFirst(rootParts.count).joined(separator: "/"))
        }
        return out
    }

    /// 书库根上每个文件多大。键是小写文件名——iOS 的文件系统不分大小写。
    nonisolated private static func fileSizes() -> [String: Int] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: BookPaths.root, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [:] }
        var out: [String: Int] = [:]
        for url in items {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            out[url.lastPathComponent.lowercased()] = size
        }
        return out
    }

    /// 把拆好的章节拼成一个 UTF-8 文件写进书库，顺便算出每章的字节范围。
    ///
    /// 文件长这样，和人直接打开看到的一样，没有额外格式：
    ///
    ///     第一章 陨落的天才\n\n<正文>\n\n第二章 斗气大陆\n\n<正文>\n\n
    ///
    /// 记的偏移只圈正文那一段，标题不算在内——读一章要的是正文，标题
    /// 索引里已经有了。
    ///
    /// 写完把源文件删掉（如果它是书库里另一个文件）：epub 抽完就没用了，
    /// GBK 的 txt 转完 UTF-8 也没必要留一份坏编码的。留着的下场是下次
    /// 扫描又把它当新书收一遍。源文件在书库外面（网页上传的临时文件、
    /// 从「文件」App 选的副本）就不动，那不是我们的东西。
    nonisolated private static func writeText(
        chapters: [ParsedChapter], stem: String, replacing source: URL
    ) -> (metas: [ChapterMeta], characters: Int, bytes: Int, name: String)? {

        var blob = Data()
        var metas: [ChapterMeta] = []
        var characters = 0
        let gap = Data("\n\n".utf8)

        for (i, chapter) in chapters.enumerated() {
            blob.append(Data(chapter.title.utf8))
            blob.append(gap)
            let body = Data(chapter.body.utf8)
            metas.append(ChapterMeta(index: i, title: chapter.title,
                                     characterCount: chapter.body.count,
                                     byteOffset: blob.count, byteLength: body.count))
            blob.append(body)
            blob.append(gap)
            characters += chapter.body.count
        }

        // 落点。源文件本来就叫这个名字（书库里的 UTF-8 txt）的话，
        // 就地覆盖回去——归一化过的内容替掉原来的，仍旧是同一个文件。
        let fm = FileManager.default
        var name = stem + ".txt"
        var target = BookPaths.file(named: name)
        if target.standardizedFileURL != source.standardizedFileURL,
           fm.fileExists(atPath: target.path) {
            // 撞上了书库里一个还没进索引的文件，让开
            var n = 2
            while fm.fileExists(atPath: BookPaths.file(named: "\(stem) (\(n)).txt").path) { n += 1 }
            name = "\(stem) (\(n)).txt"
            target = BookPaths.file(named: name)
        }

        do {
            try blob.write(to: target, options: .atomic)
        } catch {
            return nil
        }

        if target.standardizedFileURL != source.standardizedFileURL,
           source.standardizedFileURL.path.hasPrefix(BookPaths.root.standardizedFileURL.path + "/") {
            try? fm.removeItem(at: source)
            // 拖一整个文件夹进来的话，书被收到根上之后那个文件夹就空了。
            // 只删确实是因为我们才空掉的那一个，不递归、不碰还有东西的——
            // 人自己建的空文件夹轮不到我们做主。
            let parent = source.deletingLastPathComponent().standardizedFileURL
            if parent.path != BookPaths.root.standardizedFileURL.path,
               parent.path.hasPrefix(BookPaths.root.standardizedFileURL.path + "/"),
               (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try? fm.removeItem(at: parent)
            }
        }
        return (metas, characters, blob.count, name)
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
    nonisolated func search(fileName: String, chapters: [ChapterMeta],
                            keyword: String, limit: Int = 200) async -> [SearchHit] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 1 else { return [] }

        var hits: [SearchHit] = []
        for meta in chapters {
            if Task.isCancelled { return hits }

            let text = Self.chapterText(fileName: fileName, chapter: meta)
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
        // 书架上那个百分比要「这一章之前累计多少字」。章节表正好在手上，
        // 顺手加一遍存住，省得画书架时为了一个百分比去读全书的章节表。
        let before: Int
        if let openBook, openBook.id == bookID, chapterIndex <= openBook.chapters.count {
            before = openBook.chapters.prefix(chapterIndex).reduce(0) { $0 + $1.characterCount }
        } else {
            before = books[i].progress.charactersBefore
        }
        books[i].progress = ReadingProgress(chapterIndex: chapterIndex,
                                            characterOffset: characterOffset,
                                            charactersBefore: before,
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

        // 磁盘上的文件跟着改名，不然共享目录里还挂着旧书名
        let old = books[i].sourceName
        guard !old.isEmpty else { scheduleSave(); return }
        let taken = Set(books.enumerated().compactMap {
            $0.offset == i ? nil : ($0.element.sourceName as NSString).deletingPathExtension
        })
        let name = FileNames.unique(FileNames.sanitize(trimmed), taken: taken) + ".txt"
        if name != old {
            try? FileManager.default.moveItem(at: BookPaths.file(named: old),
                                              to: BookPaths.file(named: name))
            books[i].sourceName = name
        }
        scheduleSave()
    }

    func delete(bookID: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        let removed = books.remove(at: i)
        // 文件也一起删。留着的话下次扫书库又会把它收回来。
        if !removed.sourceName.isEmpty {
            try? FileManager.default.removeItem(at: BookPaths.file(named: removed.sourceName))
        }
        try? FileManager.default.removeItem(at: BookPaths.chapterFile(for: removed.id))
        if openBook?.id == removed.id { openBook = nil }
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
