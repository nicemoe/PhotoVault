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
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        server.stop()
        status = .stopped
        UIApplication.shared.isIdleTimerDisabled = false
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
            return await Task.detached(priority: .userInitiated) { () -> HTTPResponse in
                if wantsThumb {
                    guard let data = ThumbnailCache.shared.thumbnailData(for: asset, maxPixel: size) else {
                        return HTTPResponse.notFound
                    }
                    return .binary(data, type: "image/jpeg")
                } else {
                    let url = LibraryStore.fileURL(for: asset)
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                        return HTTPResponse.notFound
                    }
                    let ext = url.pathExtension
                    return .binary(data, type: ImageProbe.mimeType(forExtension: ext))
                }
            }.value
        }

        return await self.handle(request)
    }

    private func lookupAsset(_ id: UUID) -> Asset? { store.asset(id) }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
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

        case ("POST", "/api/upload"):
            guard let folderID = request.query["folder"].flatMap(UUID.init(uuidString:)),
                  store.folder(folderID) != nil else {
                return .error("目标目录不存在", status: 404)
            }
            guard let boundary = Multipart.boundary(from: request.contentType) else {
                return .error("请求格式不正确")
            }

            let body = request.body
            let parts = await Task.detached(priority: .userInitiated) {
                Multipart.parse(body: body, boundary: boundary)
            }.value

            var saved = 0
            var skipped = 0
            for part in parts where part.fileName != nil && !part.data.isEmpty {
                // 网页拖整个文件夹上来时，文件名里带着相对路径（照片/原图/a.jpg），
                // 按它逐级建目录，把原来的层级原样搬过来，
                // 而不是把里面的文件全抖到当前目录
                let target = resolveFolder(for: part.fileName ?? "", under: folderID)
                // 落盘在后台，主线程只在 attach 时短暂持有
                if await store.addImage(data: part.data, to: target) != nil {
                    saved += 1
                } else {
                    skipped += 1
                }
            }
            if saved > 0 {
                receivedCount += saved
                let folderName = store.folder(folderID)?.name ?? "目录"
                note("收到 \(saved) 张图片 → \(folderName)")
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

    /// 按上传文件名里的相对路径找到（必要时创建）真正要落的目录。
    ///
    /// 浏览器不会把路径塞进 filename，是网页那边自己拼进去的，
    /// 所以这里要当成不可信输入处理：跳过 . 和 ..，砍掉过深的层级。
    private func resolveFolder(for fileName: String, under root: UUID) -> UUID {
        let parts = fileName.split(separator: "/").map(String.init)
        guard parts.count > 1, let groupID = store.groupID(containing: root) else { return root }

        var current = root
        // 最后一段是文件名本身，不建目录
        for raw in parts.dropLast().prefix(8) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            guard let next = store.folder(named: name, under: current, in: groupID) else { break }
            current = next.id
        }
        return current
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
            json["assets"] = folder.assets.reversed().map { asset in
                [
                    "id": asset.id.uuidString,
                    "width": asset.width,
                    "height": asset.height,
                    "bytes": asset.byteCount
                ] as [String: Any]
            }
        }
        return json
    }
}
