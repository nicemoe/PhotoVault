import Foundation
import UIKit
import Observation

/// WiFi 传输：启动本机 HTTP 服务，同局域网设备用浏览器管理分组 / 目录 / 上传图片
@MainActor
@Observable
final class WiFiService {

    enum Status: Equatable {
        case stopped
        case starting
        case running(url: String)
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private(set) var receivedCount = 0
    private(set) var lastEvent: String?

    private let server = HTTPServer()
    /// 上一次有人来访的时间。空闲自动停服要用。
    private var lastActivity = Date()
    private var idleWatch: Task<Void, Never>?
    /// 没人来这么久就自己关掉。见 watchIdle。
    private static let idleLimit: TimeInterval = 20 * 60
    private let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var urlString: String? {
        if case .running(let url) = status { return url }
        return nil
    }

    // MARK: 开关

    func start() async {
        guard !isRunning else { return }
        status = .starting
        receivedCount = 0
        lastEvent = nil

        guard let ip = NetworkInfo.localIPAddress() else {
            status = .failed("未检测到 WiFi 连接，请先连接无线网络")
            return
        }

        do {
            let port = try await server.start { [weak self] request in
                guard let self else { return .notFound }
                return await self.route(request)
            }
            status = .running(url: "http://\(ip):\(port)")
            // 服务只能在前台活着——App 一被挂起 NWListener 就没了，所以传输
            // 期间必须拦着屏幕自动锁。代价是这段时间屏幕一直亮着，很费电，
            // 所以下面盯着，没人用就自己关掉。
            UIApplication.shared.isIdleTimerDisabled = true
            lastActivity = Date()
            watchIdle()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        idleWatch?.cancel()
        idleWatch = nil
        server.stop()
        status = .stopped
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// 没人用就把服务关掉。
    ///
    /// 开着传输的这段时间屏幕是被强制点亮的，这是整个 App 里最费电的状态——
    /// 传完了忘记关，一晚上就能把电耗光。所以盯一下：二十分钟没人来访就自己收。
    ///
    /// 两个条件都要满足才算「没人用」：
    ///
    /// - 二十分钟没有请求进来。网页那边每 10 秒会拉一次列表，所以只要还有人
    ///   开着页面，这个条件就不成立。
    /// - 手上没有连着的客户端。正在传一个 8GB 的片子时连接是在的，但那一个
    ///   请求要跑很久才完成——只看「最后一次请求什么时候」会把它掐断。
    ///
    /// 一分钟醒一次。这个频率本身的开销可以忽略，比屏幕多亮一分钟便宜得多。
    private func watchIdle() {
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                guard !self.server.hasActiveConnections,
                      Date().timeIntervalSince(self.lastActivity) > Self.idleLimit else { continue }
                self.stop()
                self.lastEvent = "闲置太久，已自动关闭传输"
                return
            }
        }
    }

    // MARK: 路由

    private nonisolated func route(_ request: HTTPRequest) async -> HTTPResponse {
        // 图片二进制：先在主线程拿到元信息，再到后台读盘，避免卡 UI
        if request.method == "GET", request.path == "/photo" || request.path == "/thumb" {
            guard let idString = request.query["id"], let id = UUID(uuidString: idString),
                  let asset = await self.lookupAsset(id) else {
                return .notFound
            }
            let wantsThumb = request.path == "/thumb"
            // 尺寸也来自网络。不夹上界的话 /thumb?s=99999999 会让缩略图退化成
            // 整图解码再重新编码，真机上足以触发内存回收。
            let size = min(max(Int(request.query["s"] ?? "") ?? 420, 32), 2048)
            let rangeHeader = request.header("range")

            if wantsThumb {
                // 视频封面是异步抽的，不能塞进下面的同步块里
                guard let data = await ThumbnailCache.shared.thumbnailData(for: asset, maxPixel: size) else {
                    return .notFound
                }
                return .binary(data, type: "image/jpeg")
            }

            return await Task.detached(priority: .userInitiated) { () -> HTTPResponse in
                let url = LibraryStore.fileURL(for: asset)
                let type = ImageProbe.mimeType(forExtension: url.pathExtension)
                // 视频要支持 Range：不支持的话浏览器拖不动进度条，
                // 而且会把几百 MB 整个塞进一个响应里发出去
                return HTTPResponse.file(url, type: type, range: rangeHeader)
            }.value
        }

        return await self.handle(request)
    }

    private func lookupAsset(_ id: UUID) -> Asset? { store.asset(id) }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        lastActivity = Date()
        switch (request.method, request.path) {

        case ("GET", "/"), ("GET", "/index.html"):
            return .html(WebUI.page)

        case ("GET", "/favicon.ico"):
            return HTTPResponse(status: 204, headers: [:], body: Data())

        case ("GET", "/api/state"):
            return .json(stateJSON())

        case ("GET", "/api/folder"):
            guard let id = request.query["id"].flatMap(UUID.init(uuidString:)),
                  let folder = store.folder(id) else { return .error("目录不存在", status: 404) }
            return .json(folderJSON(folder, includeAssets: true))

        // MARK: 分组
        case ("POST", "/api/group/create"):
            guard let name = request.string("name") else { return .error("分组名不能为空") }
            let group = store.addGroup(name: name)
            note("网页创建了分组「\(group.name)」")
            return .ok(["id": group.id.uuidString])

        case ("POST", "/api/group/rename"):
            guard let id = request.uuid("id"), let name = request.string("name") else { return .error("参数不完整") }
            store.renameGroup(id, to: name)
            note("网页重命名了分组")
            return .ok()

        case ("POST", "/api/group/delete"):
            guard let id = request.uuid("id") else { return .error("参数不完整") }
            store.deleteGroup(id)
            note("网页删除了一个分组")
            return .ok()

        // MARK: 目录
        case ("POST", "/api/folder/create"):
            guard let groupID = request.uuid("groupId"), let name = request.string("name") else { return .error("参数不完整") }
            // parentId 可省略，省略就是建在分组根下
            let parentID = request.uuid("parentId")
            guard let folder = store.addFolder(to: groupID, name: name, parent: parentID) else {
                return .error("分组或父目录不存在", status: 404)
            }
            note("网页创建了目录「\(folder.name)」")
            return .ok(["id": folder.id.uuidString])

        case ("POST", "/api/folder/rename"):
            guard let id = request.uuid("id"), let name = request.string("name") else { return .error("参数不完整") }
            store.renameFolder(id, to: name)
            note("网页重命名了目录")
            return .ok()

        case ("POST", "/api/folder/delete"):
            guard let id = request.uuid("id") else { return .error("参数不完整") }
            store.deleteFolder(id)
            note("网页删除了一个目录")
            return .ok()

        case ("POST", "/api/folder/move"):
            guard let id = request.uuid("id"), let groupID = request.uuid("groupId") else { return .error("参数不完整") }
            guard store.folder(id) != nil else { return .error("目录不存在", status: 404) }
            guard store.group(groupID) != nil else { return .error("目标分组不存在", status: 404) }
            // parentId 省略就是挂到分组根下
            store.moveFolder(id, toGroup: groupID, parent: request.uuid("parentId"))
            note("网页移动了一个目录")
            return .ok()

        // MARK: 图片
        case ("POST", "/api/asset/delete"):
            guard let folderID = request.uuid("folderId"), let id = request.uuid("id") else { return .error("参数不完整") }
            store.deleteAssets([id], from: folderID)
            return .ok()

        // 单个文件直传：请求体本身就是文件，不套 multipart。
        //
        // 大视频走 multipart 的话，磁盘上会同时存在两份：落盘的请求体，
        // 和从里面拆出来的那一段。8GB 的片子要占 16GB。直传的话收到的
        // 那个文件就是成品，直接搬进媒体库，只占一份。
        case ("POST", "/api/upload-file"):
            guard let destination = destination(from: request) else {
                return .error("目标不存在", status: 404)
            }
            let rawName = request.query["name"] ?? ""
            guard let target = resolveFolder(for: rawName, at: destination) else {
                return .error("目标不存在", status: 404)
            }

            // 小文件不会落盘，body 还在内存里，先写成临时文件再走同一条路
            var source = request.bodyFile
            var temporary: URL?
            if source == nil, !request.body.isEmpty {
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                if (try? request.body.write(to: temp, options: .atomic)) != nil {
                    source = temp
                    temporary = temp
                }
            }
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

            guard let source else { return .error("没有收到文件") }

            let ok: Bool
            if isVideoName(rawName) {
                ok = await store.addVideo(from: source, to: target, name: rawName) != nil
            } else if let data = try? Data(contentsOf: source, options: .mappedIfSafe) {
                ok = await store.addImage(data: data, to: target, name: rawName) != nil
            } else {
                ok = false
            }

            if ok {
                receivedCount += 1
                note("收到「\((rawName as NSString).lastPathComponent)」")
                // 这条路是一个文件一个请求，网页那边挑一整个相册就是几千个请求
                // 挨着来。每来一个就整份索引写一遍的话，写入量是文件数的平方：
                // 一万个文件累计写盘约 13 GB。交给 400ms 的合并队列，
                // 连着来的那些会并成一次。
                //
                // 掉最后 400ms 的记录不要紧：文件已经落在 Media 里了，
                // 下次启动对账会把它收回来——磁盘才是真相，索引丢了能重建。
                store.scheduleSaveFromServer()
            }
            return .ok(["saved": ok ? 1 : 0, "skipped": ok ? 0 : 1])

        case ("POST", "/api/upload"):
            guard let destination = destination(from: request) else {
                return .error("目标不存在", status: 404)
            }
            guard let boundary = Multipart.boundary(from: request.contentType) else {
                return .error("请求格式不正确")
            }

            var saved = 0
            var skipped = 0

            if let bodyFile = request.bodyFile {
                // 大请求体：正文已经在磁盘上，逐段拆成独立文件，全程不进内存
                let workDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mp-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: workDir) }

                let parts = await Task.detached(priority: .userInitiated) {
                    MultipartStream.parse(fileURL: bodyFile, boundary: boundary, into: workDir)
                }.value

                for part in parts where part.fileName != nil && part.byteCount > 0 {
                    let name = part.fileName ?? ""
                    guard let target = resolveFolder(for: name, at: destination) else { skipped += 1; continue }
                    if isVideoName(name) {
                        if await store.addVideo(from: part.fileURL, to: target, name: name) != nil { saved += 1 }
                        else { skipped += 1 }
                    } else if let data = try? Data(contentsOf: part.fileURL),
                              await store.addImage(data: data, to: target, name: name) != nil {
                        saved += 1
                    } else {
                        skipped += 1
                    }
                }
            } else {
                let body = request.body
                let parts = await Task.detached(priority: .userInitiated) {
                    Multipart.parse(body: body, boundary: boundary)
                }.value

                for part in parts where part.fileName != nil && !part.data.isEmpty {
                    // 网页拖整个文件夹上来时，文件名里带着相对路径（照片/原图/a.jpg），
                    // 按它逐级建目录，把原来的层级原样搬过来，
                    // 而不是把里面的文件全抖到当前目录
                    let name = part.fileName ?? ""
                    guard let target = resolveFolder(for: name, at: destination) else { skipped += 1; continue }

                    // 这条路也要认视频。小于落盘阈值的请求体走内存解析，
                    // 之前这里一律当图片喂给 ImageProbe，于是几 MB 的短视频
                    // 全被当成「格式不支持」跳掉，大视频反而正常。
                    if isVideoName(name) {
                        let temp = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString + "-" + (name as NSString).lastPathComponent)
                        if (try? part.data.write(to: temp, options: .atomic)) != nil,
                           await store.addVideo(from: temp, to: target, name: name) != nil {
                            saved += 1
                        } else {
                            skipped += 1
                        }
                        try? FileManager.default.removeItem(at: temp)
                    } else if await store.addImage(data: part.data, to: target, name: name) != nil {
                        // 落盘在后台，主线程只在 attach 时短暂持有
                        saved += 1
                    } else {
                        skipped += 1
                    }
                }
            }
            if saved > 0 {
                receivedCount += saved
                // 一批里的文件可能被相对路径分到好几个目录，报最上面那个就够了
                let where_ = destination.parent.flatMap { store.folder($0)?.name }
                    ?? store.groups.first { $0.id == destination.group }?.name
                    ?? "目录"
                note("收到 \(saved) 个文件 → \(where_)")
                store.saveNow()
            }
            return .ok(["saved": saved, "skipped": skipped])

        default:
            return .notFound
        }
    }

    private func note(_ text: String) {
        lastEvent = text
    }

    private func isVideoName(_ name: String) -> Bool { MediaFormats.isVideo(fileName: name) }

    /// 上传落到哪儿。目录页给的是目录，分组页给的是分组。
    struct Destination {
        var group: UUID
        /// 从分组页拖进来时没有父目录，路径里的第一段就是要建的目录
        var parent: UUID?
    }

    /// 从请求参数里认出目标。folder 优先，没有就看 group。
    private func destination(from request: HTTPRequest) -> Destination? {
        if let folderID = request.query["folder"].flatMap(UUID.init(uuidString:)),
           store.folder(folderID) != nil,
           let groupID = store.groupID(containing: folderID) {
            return Destination(group: groupID, parent: folderID)
        }
        if let groupID = request.query["group"].flatMap(UUID.init(uuidString:)),
           store.groups.contains(where: { $0.id == groupID }) {
            return Destination(group: groupID, parent: nil)
        }
        return nil
    }

    /// 按上传文件名里的相对路径找到（必要时创建）真正要落的目录。
    ///
    /// 浏览器不会把路径塞进 filename，是网页那边自己拼进去的，
    /// 所以这里要当成不可信输入处理：跳过 . 和 ..，砍掉过深的层级。
    ///
    /// 从分组页拖一整个文件夹进来时没有父目录，路径里的第一段就是要建的目录。
    /// 这时候要是连一段路径都没有（散文件直接拖到分组上），得有个地方装，
    /// 收进「未分类」——和「导入」文件夹那条路的规矩一致。
    private func resolveFolder(for fileName: String, at destination: Destination) -> UUID? {
        let parts = fileName.split(separator: "/").map(String.init)
        var current = destination.parent

        // 最后一段是文件名本身，不建目录
        for raw in parts.dropLast().prefix(8) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            guard let next = store.folder(named: name, under: current, in: destination.group) else { break }
            current = next.id
        }
        if let current { return current }
        return store.folder(named: "未分类", under: nil, in: destination.group)?.id
    }

    // MARK: JSON

    private func stateJSON() -> [String: Any] {
        [
            "device": UIDevice.current.name,
            "totalPhotos": store.totalPhotoCount,
            "groups": store.sortedGroups.map { group in
                [
                    "id": group.id.uuidString,
                    "name": group.name,
                    "color": Theme.cssColor(at: group.colorIndex),
                    "folderCount": group.folderCount,
                    "photoCount": group.photoCount,
                    "cover": group.coverAssets.map { $0.id.uuidString },
                    "folders": group.folders.sorted(by: store.folderSort).map { folderJSON($0, includeAssets: false) }
                ] as [String: Any]
            }
        ]
    }

    private func folderJSON(_ folder: Folder, includeAssets: Bool) -> [String: Any] {
        var json: [String: Any] = [
            "id": folder.id.uuidString,
            "name": folder.name,
            "parentId": folder.parentID?.uuidString ?? "",
            "photoCount": folder.photoCount,
            // 含子目录的总数，网页上要和 App 里显示的一致
            "totalPhotoCount": store.totalPhotoCount(in: folder.id),
            "subfolderCount": store.totalFolderCount(in: folder.id),
            "cover": store.coverAssets(for: folder.id).map { $0.id.uuidString }
        ]
        if includeAssets {
            json["groupId"] = store.groupID(containing: folder.id)?.uuidString ?? ""
            // 子目录和从分组根到这里的路径，网页要靠它们画目录树和面包屑
            json["subfolders"] = store.children(of: folder.id)
                .sorted(by: store.folderSort)
                .map { folderJSON($0, includeAssets: false) }
            json["path"] = store.path(to: folder.id).dropLast().map {
                ["id": $0.id.uuidString, "name": $0.name]
            }
            json["assets"] = folder.assets.reversed().map { asset in
                [
                    "id": asset.id.uuidString,
                    "kind": asset.kind.rawValue,
                    "width": asset.width,
                    "height": asset.height,
                    "bytes": asset.byteCount,
                    "duration": asset.duration,
                    "durationText": asset.durationText
                ] as [String: Any]
            }
        }
        return json
    }
}
