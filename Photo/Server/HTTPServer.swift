import Foundation
import Network

/// 极简 HTTP/1.1 服务端（基于 Network.framework，无第三方依赖）
final class HTTPServer: @unchecked Sendable {

    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum ServerError: LocalizedError {
        case noAvailablePort
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noAvailablePort: return "没有可用端口，请稍后重试"
            case .timedOut:        return "服务启动超时。请在「设置 → 隐私与安全性 → 本地网络」里允许本 App 访问局域网。"
            case .failed(let m):   return m
            }
        }
    }

    private let queue = DispatchQueue(label: "photovault.http.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let lock = NSLock()

    private(set) var port: UInt16 = 0
    var onStateChange: (@Sendable (Bool) -> Void)?

    /// 依次尝试若干端口，返回实际监听端口
    @discardableResult
    func start(preferredPorts: [UInt16] = [8080, 8081, 8088, 9000, 9090], handler: @escaping Handler) async throws -> UInt16 {
        stop()

        var lastError: Error?
        for candidate in preferredPorts {
            do {
                try await startListening(on: candidate, handler: handler)
                return candidate
            } catch ServerError.timedOut {
                // 超时不是端口问题（多半是本地网络权限），换端口也没用
                throw ServerError.timedOut
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? ServerError.noAvailablePort
    }

    private func startListening(on port: UInt16, handler: @escaping Handler) async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.noAvailablePort
        }

        let listener = try NWListener(using: params, on: nwPort)
        // 广播 Bonjour，既方便发现，也能正确触发「本地网络」权限弹窗
        listener.service = NWListener.Service(name: UIDeviceName.current, type: "_http._tcp")

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let wrapper = HTTPConnection(connection: connection, queue: self.queue, handler: handler) { [weak self] id in
                self?.remove(id)
            }
            self.add(wrapper)
            wrapper.start()
        }

        let resumed = ResumeGuard()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // .waiting 不当作失败：首次开启时系统可能正在等用户回应「本地网络」授权，
                // 用超时兜底，避免卡死。
                let timeout = DispatchWorkItem {
                    if resumed.claim() { continuation.resume(throwing: ServerError.timedOut) }
                }
                queue.asyncAfter(deadline: .now() + 4, execute: timeout)

                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.onStateChange?(true)
                        if resumed.claim() { timeout.cancel(); continuation.resume() }
                    case .failed(let error):
                        if resumed.claim() {
                            timeout.cancel()
                            continuation.resume(throwing: ServerError.failed(error.localizedDescription))
                        }
                    case .waiting(let error):
                        // 端口被占用时 NWListener 是停在 .waiting 而不是 .failed，
                        // 必须在这里立刻失败，否则换端口重试的逻辑永远走不到。
                        // 其他 waiting（比如在等「本地网络」授权）交给超时兜底。
                        if case .posix(let code) = error, code == .EADDRINUSE || code == .EADDRNOTAVAIL {
                            if resumed.claim() {
                                timeout.cancel()
                                continuation.resume(throwing: ServerError.failed(error.localizedDescription))
                            }
                        }
                    case .cancelled:
                        self?.onStateChange?(false)
                        if resumed.claim() { timeout.cancel(); continuation.resume(throwing: ServerError.noAvailablePort) }
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        } catch {
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw error
        }

        lock.lock()
        self.listener = listener
        self.port = port
        lock.unlock()
    }

    func stop() {
        // listener/port 也要纳入锁：start() 跑在并发执行器上，stop() 来自主线程，
        // 快速反复开关时两边会同时写这两个字段。
        lock.lock()
        let old = listener
        listener = nil
        port = 0
        let all = Array(connections.values)
        connections.removeAll()
        lock.unlock()

        old?.cancel()
        all.forEach { $0.close() }
        onStateChange?(false)
    }

    private func add(_ c: HTTPConnection) {
        lock.lock(); connections[ObjectIdentifier(c)] = c; lock.unlock()
    }

    private func remove(_ id: ObjectIdentifier) {
        lock.lock(); connections.removeValue(forKey: id); lock.unlock()
    }
}

/// 保证 continuation 只被 resume 一次
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

// MARK: - 单条连接

private final class HTTPConnection {

    /// 单次请求体上限。视频上传要走这条路，所以放到 4GB。
    /// 大的请求体不进内存——超过 spillThreshold 就边收边写盘。
    private static let maxBodyBytes = 4 * 1024 * 1024 * 1024

    /// 超过这个大小的请求体落盘。小请求（JSON、几张图）还是走内存，省一次读写。
    private static let spillThreshold = 4 * 1024 * 1024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private let onClose: (ObjectIdentifier) -> Void

    /// 已读到 header、正在等 body 的请求
    private struct PendingRequest {
        var method: String
        var target: String
        var headers: [String: String]
        var contentLength: Int
        var keepAlive: Bool
    }

    private var buffer = Data()
    private var pending: PendingRequest?
    private var headerScanOffset = 0
    private var isHandling = false
    private var isClosed = false

    /// 请求体落盘时用：一边收一边往这里写，收满 contentLength 就交给上层
    private var spillFile: URL?
    private var spillHandle: FileHandle?
    private var spilled = 0

    init(connection: NWConnection,
         queue: DispatchQueue,
         handler: @escaping HTTPServer.Handler,
         onClose: @escaping (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 17) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                // 只有「没在落盘」的时候才用缓冲区大小卡上限。
                // 落盘模式下缓冲区每轮都会被搬空，涨不上去。
                if self.spillHandle == nil, self.buffer.count > Self.spillThreshold * 4 {
                    self.send(.text("413 Payload Too Large", status: 413), keepAlive: false)
                    return
                }
                self.drain()
            }

            if error != nil { self.close(); return }
            if isComplete { self.close(); return }
            if !self.isClosed { self.receive() }
        }
    }

    /// 从缓冲区里尽可能解析出完整请求。
    /// header 与 body 分两个阶段，body 阶段只比长度不再全量扫描，避免大文件上传时退化成 O(n²)。
    private func drain() {
        guard !isHandling, !isClosed else { return }

        if pending == nil {
            guard parseHeaders() else { return }
        }
        guard let request = pending else { return }

        // 大请求体：边收边写盘，内存里只过一遍缓冲区
        if request.contentLength > Self.spillThreshold {
            if spillHandle == nil { openSpill() }
            guard let handle = spillHandle else {
                send(.text("500 无法写入临时文件", status: 500), keepAlive: false)
                return
            }
            let need = request.contentLength - spilled
            if need > 0, !buffer.isEmpty {
                let take = min(need, buffer.count)
                // prefix / removeFirst 按元素个数算，与 startIndex 无关，这里是安全的
                try? handle.write(contentsOf: Data(buffer.prefix(take)))
                buffer.removeFirst(take)
                spilled += take
                if buffer.isEmpty { buffer = Data() }
            }
            guard spilled >= request.contentLength else { return }   // 还没收完，等下一批

            try? handle.close()
            spillHandle = nil
            let file = spillFile
            spillFile = nil
            spilled = 0
            pending = nil
            dispatch(request, body: Data(), bodyFile: file)
            return
        }

        guard buffer.count >= request.contentLength else { return }

        let body = Data(buffer.prefix(request.contentLength))
        buffer.removeFirst(request.contentLength)
        pending = nil

        // 一个请求处理完、缓冲区正好空了就重建一份，让 startIndex 回到 0，
        // 避免长连接上偏移量一路累加
        if buffer.isEmpty { buffer = Data() }

        dispatch(request, body: body, bodyFile: nil)
    }

    private func openSpill() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        spillHandle = try? FileHandle(forWritingTo: url)
        spillFile = spillHandle == nil ? nil : url
        spilled = 0
    }

    /// 解析出 header 后把它从缓冲区里摘掉，返回是否成功
    private func parseHeaders() -> Bool {
        let terminator = Data("\r\n\r\n".utf8)

        // 关键：Data.removeSubrange 不会把 startIndex 归零，只是往前推。
        // 所以 keep-alive 连接处理完第一个请求后 startIndex 就不是 0 了，
        // count 和 endIndex 属于两个坐标系，混用会让 range(of:in:) 越界
        // 抛 NSRangeException（Swift 接不住，直接 abort）。
        // headerScanOffset 一律当作相对 startIndex 的偏移量，用 index(_:offsetBy:) 换算。
        let skip = min(max(0, headerScanOffset - 3), buffer.count)
        let searchStart = buffer.index(buffer.startIndex, offsetBy: skip)

        guard let range = buffer.range(of: terminator, in: searchStart..<buffer.endIndex) else {
            headerScanOffset = buffer.count
            return false
        }

        let headText = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        headerScanOffset = 0

        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { close(); return false }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { close(); return false }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        // Content-Length 直接来自网络，负数是合法的 Int 字面量。
        // 负数会一路带到 buffer.prefix(_:) / removeFirst(_:)，这两个对负数是
        // _precondition，Release 构建也照样 trap，所以必须在这里夹住。
        // （溢出的超大值 Int(_:) 会返回 nil，被 ?? 0 兜住。）
        let length = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        guard length <= Self.maxBodyBytes else {
            send(.text("413 Payload Too Large", status: 413), keepAlive: false)
            return false
        }

        pending = PendingRequest(
            method: String(requestLine[0]).uppercased(),
            target: String(requestLine[1]),
            headers: headers,
            contentLength: length,
            keepAlive: headers["connection"]?.lowercased() != "close"
        )
        return true
    }

    private func dispatch(_ pending: PendingRequest, body: Data, bodyFile: URL?) {
        // 拆 path / query
        let target = pending.target
        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<mark])
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1
                    ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1]))
                    : ""
                query[key] = value
            }
        }
        path = path.removingPercentEncoding ?? path

        let request = HTTPRequest(method: pending.method,
                                  path: path,
                                  query: query,
                                  headers: pending.headers,
                                  body: body,
                                  bodyFile: bodyFile)
        let keepAlive = pending.keepAlive
        let handler = self.handler
        let queue = self.queue

        isHandling = true
        Task { [weak self] in
            let response = await handler(request)
            // 处理完就把落盘的请求体删掉，不然临时目录会一直涨
            if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) }
            queue.async { self?.send(response, keepAlive: keepAlive) }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        guard !isClosed else { return }
        let data = response.serialized(keepAlive: keepAlive)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.isHandling = false
            if keepAlive {
                self.drain()
            } else {
                self.close()
            }
        })
    }

    /// 可能从主线程（stop()）调用，所以统一回到连接自己的队列上执行，
    /// 避免和正在解析缓冲区的 receive/drain 抢同一份状态。
    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            buffer.removeAll()
            pending = nil
            // 连接中途断了：收了一半的请求体没人要了，别留在磁盘上
            try? spillHandle?.close()
            spillHandle = nil
            if let file = spillFile { try? FileManager.default.removeItem(at: file) }
            spillFile = nil
            connection.cancel()
            onClose(ObjectIdentifier(self))
        }
    }
}

// MARK: - 设备名（用于 Bonjour 广播）

enum UIDeviceName {
    static var current: String {
        let raw = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        return raw.isEmpty ? "Photo" : "Photo (\(raw))"
    }
}
