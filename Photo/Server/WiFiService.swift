import Foundation
import UIKit
import Observation

/// WiFi 传输：启动本机 HTTP 服务，同局域网设备用浏览器上传小说、管理书架
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
    private let books: BookLibrary

    init(books: BookLibrary) {
        self.books = books
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
                return await self.handle(request)
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

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {

        case ("GET", "/"), ("GET", "/index.html"):
            return .html(WebUI.page)

        case ("GET", "/favicon.ico"):
            return HTTPResponse(status: 204, headers: [:], body: Data())

        case ("GET", "/api/state"):
            return .json(["device": UIDevice.current.name,
                          "totalBooks": books.books.count])

        // MARK: 书
        case ("GET", "/api/books"):
            return .json(["books": books.sortedBooks.map { book in
                [
                    "id": book.id.uuidString,
                    "title": book.title,
                    "author": book.author,
                    "format": book.format.label,
                    "chapters": book.chapterCount,
                    "progress": book.progressText
                ] as [String: Any]
            }])

        case ("POST", "/api/book/delete"):
            guard let id = request.uuid("id") else { return .error("参数不完整") }
            books.delete(bookID: id)
            note("网页删除了一本书")
            return .ok()

        case ("POST", "/api/book/upload"):
            guard let boundary = Multipart.boundary(from: request.contentType) else {
                return .error("请求格式不正确")
            }
            let body = request.body
            let parts = await Task.detached(priority: .userInitiated) {
                Multipart.parse(body: body, boundary: boundary)
            }.value

            var saved = 0
            var failure: String?
            for part in parts {
                guard let name = part.fileName, !part.data.isEmpty else { continue }
                do {
                    let book = try await books.importBook(data: part.data, fileName: name)
                    saved += 1
                    receivedCount += 1
                    note("收到《\(book.title)》，共 \(book.chapterCount) 章")
                } catch {
                    failure = error.localizedDescription
                }
            }
            if saved == 0 { return .error(failure ?? "没有可导入的文件") }
            return .ok(["saved": saved, "error": failure ?? ""])

        default:
            return .notFound
        }
    }

    private func note(_ text: String) {
        lastEvent = text
    }

}
