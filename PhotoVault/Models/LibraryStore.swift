import Foundation
import ImageIO
import UniformTypeIdentifiers
import Observation

/// 磁盘路径。放在 actor 之外，服务端线程也能安全读取。
enum Paths {

    static let documents: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    /// 原图存放目录
    static let media: URL = {
        let url = documents.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let libraryFile = documents.appendingPathComponent("library.json")

    static func url(for asset: Asset) -> URL {
        media.appendingPathComponent(asset.fileName)
    }
}

/// 全局数据仓库：分组 / 目录 / 图片的增删改查 + 磁盘持久化。
/// 所有变更都在主线程进行（WiFi 服务端会 hop 到主线程调用）。
@MainActor
@Observable
final class LibraryStore {

    private(set) var library = Library()

    nonisolated static func fileURL(for asset: Asset) -> URL { Paths.url(for: asset) }

    // MARK: 生命周期

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.libraryFile),
              let decoded = try? Coders.makeDecoder().decode(Library.self, from: data) else {
            library = Library()
            return
        }
        library = decoded
    }

    private var saveTask: Task<Void, Never>?

    /// 合并 0.4s 内的多次写入，避免批量导入时反复落盘
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = library
        saveTask = Task { [snapshot] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let snapshot = library
        Task.detached(priority: .utility) { await Self.write(snapshot) }
    }

    private nonisolated static func write(_ snapshot: Library) async {
        guard let data = try? Coders.makeEncoder().encode(snapshot) else { return }
        try? data.write(to: Paths.libraryFile, options: .atomic)
    }

    // MARK: 查询

    var groups: [PhotoGroup] { library.groups }

    var sortedGroups: [PhotoGroup] { library.groups.sorted(by: library.groupSort) }

    var groupSort: SortMode {
        get { library.groupSort }
        set { library.groupSort = newValue; scheduleSave() }
    }

    var folderSort: SortMode {
        get { library.folderSort }
        set { library.folderSort = newValue; scheduleSave() }
    }

    var totalPhotoCount: Int { library.groups.reduce(0) { $0 + $1.photoCount } }

    func group(_ id: UUID) -> PhotoGroup? {
        library.groups.first { $0.id == id }
    }

    func folder(_ id: UUID) -> Folder? {
        for g in library.groups {
            if let f = g.folders.first(where: { $0.id == id }) { return f }
        }
        return nil
    }

    /// 返回 (分组下标, 目录下标)
    private func locate(folder id: UUID) -> (Int, Int)? {
        for (gi, g) in library.groups.enumerated() {
            if let fi = g.folders.firstIndex(where: { $0.id == id }) { return (gi, fi) }
        }
        return nil
    }

    func groupID(containing folderID: UUID) -> UUID? {
        guard let (gi, _) = locate(folder: folderID) else { return nil }
        return library.groups[gi].id
    }

    func asset(_ id: UUID) -> Asset? {
        for g in library.groups {
            for f in g.folders {
                if let a = f.assets.first(where: { $0.id == id }) { return a }
            }
        }
        return nil
    }

    // MARK: 分组

    @discardableResult
    func addGroup(name: String) -> PhotoGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = PhotoGroup(
            name: trimmed.isEmpty ? "新分组" : trimmed,
            colorIndex: library.groups.count % Theme.palette.count
        )
        library.groups.append(group)
        scheduleSave()
        return group
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        library.groups[i].name = trimmed
        scheduleSave()
    }

    func setGroupColor(_ id: UUID, index: Int) {
        guard let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        library.groups[i].colorIndex = index
        scheduleSave()
    }

    func deleteGroup(_ id: UUID) {
        guard let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        let removed = library.groups.remove(at: i)
        for folder in removed.folders {
            for asset in folder.assets { removeFile(asset) }
        }
        scheduleSave()
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        library.groups.move(fromOffsets: source, toOffset: destination)
        library.groupSort = .manual
        scheduleSave()
    }

    // MARK: 目录

    @discardableResult
    func addFolder(to groupID: UUID, name: String) -> Folder? {
        guard let gi = library.groups.firstIndex(where: { $0.id == groupID }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(name: trimmed.isEmpty ? "新目录" : trimmed)
        library.groups[gi].folders.append(folder)
        scheduleSave()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let (gi, fi) = locate(folder: id) else { return }
        library.groups[gi].folders[fi].name = trimmed
        scheduleSave()
    }

    func deleteFolder(_ id: UUID) {
        guard let (gi, fi) = locate(folder: id) else { return }
        let removed = library.groups[gi].folders.remove(at: fi)
        for asset in removed.assets { removeFile(asset) }
        scheduleSave()
    }

    /// 把目录移动到另一个分组
    func moveFolder(_ id: UUID, toGroup targetGroupID: UUID) {
        guard let (gi, fi) = locate(folder: id),
              let ti = library.groups.firstIndex(where: { $0.id == targetGroupID }),
              ti != gi else { return }
        let folder = library.groups[gi].folders.remove(at: fi)
        library.groups[ti].folders.append(folder)
        scheduleSave()
    }

    func moveFolders(in groupID: UUID, from source: IndexSet, to destination: Int) {
        guard let gi = library.groups.firstIndex(where: { $0.id == groupID }) else { return }
        library.groups[gi].folders.move(fromOffsets: source, toOffset: destination)
        library.folderSort = .manual
        scheduleSave()
    }

    // MARK: 图片

    /// 探测尺寸并落盘。不碰内存中的数据结构，所以可以在后台线程跑。
    nonisolated static func persist(_ data: Data) -> Asset? {
        guard let info = ImageProbe.inspect(data) else { return nil }

        let fileName = "\(UUID().uuidString).\(info.fileExtension)"
        let url = Paths.media.appendingPathComponent(fileName)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }

        return Asset(fileName: fileName,
                     width: info.width,
                     height: info.height,
                     byteCount: data.count)
    }

    /// 把已落盘的图片挂到目录下（只动内存结构，必须在主线程）
    @discardableResult
    func attach(_ asset: Asset, to folderID: UUID) -> Bool {
        guard let (gi, fi) = locate(folder: folderID) else {
            // 目录在落盘期间被删了，清掉这个孤儿文件
            try? FileManager.default.removeItem(at: Paths.url(for: asset))
            return false
        }
        library.groups[gi].folders[fi].assets.append(asset)
        scheduleSave()
        return true
    }

    /// 落盘 + 挂载一步到位。磁盘 IO 在后台线程，主线程只做数组插入。
    @discardableResult
    func addImage(data: Data, to folderID: UUID) async -> Asset? {
        guard folder(folderID) != nil else { return nil }

        // Task.detached 的尾随闭包不能直接写在 guard 条件里：
        // 编译器会把那个 { 当成 guard 的语句块开头。先把任务提出来。
        let work = Task.detached(priority: .userInitiated) {
            LibraryStore.persist(data)
        }
        guard let asset = await work.value else { return nil }

        return attach(asset, to: folderID) ? asset : nil
    }

    func deleteAssets(_ ids: Set<UUID>, from folderID: UUID) {
        guard !ids.isEmpty, let (gi, fi) = locate(folder: folderID) else { return }
        let removed = library.groups[gi].folders[fi].assets.filter { ids.contains($0.id) }
        library.groups[gi].folders[fi].assets.removeAll { ids.contains($0.id) }
        for asset in removed { removeFile(asset) }
        scheduleSave()
    }

    func moveAssets(_ ids: Set<UUID>, from folderID: UUID, to targetFolderID: UUID) {
        guard folderID != targetFolderID,
              let (gi, fi) = locate(folder: folderID),
              let (tgi, tfi) = locate(folder: targetFolderID) else { return }
        let moving = library.groups[gi].folders[fi].assets.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        library.groups[gi].folders[fi].assets.removeAll { ids.contains($0.id) }
        library.groups[tgi].folders[tfi].assets.append(contentsOf: moving)
        scheduleSave()
    }

    private func removeFile(_ asset: Asset) {
        try? FileManager.default.removeItem(at: Paths.url(for: asset))
        ThumbnailCache.shared.invalidate(asset.id)
    }

}

// MARK: - 编解码配置

/// JSONEncoder/Decoder 不是 Sendable，这里每次新建，避免跨线程共用同一个实例
enum Coders {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

// MARK: - 图片探测

enum ImageProbe {
    struct Info {
        var width: Int
        var height: Int
        var fileExtension: String
        var mimeType: String
    }

    /// 不解码整张图，只读元数据拿尺寸和类型
    static func inspect(_ data: Data) -> Info? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }

        var ext = "jpg"
        var mime = "image/jpeg"
        if let uti = CGImageSourceGetType(source) as String?,
           let type = UTType(uti) {
            ext = type.preferredFilenameExtension ?? "jpg"
            mime = type.preferredMIMEType ?? "image/jpeg"
        }
        return Info(width: width, height: height, fileExtension: ext, mimeType: mime)
    }

    static func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
