import Foundation

// MARK: - 请求

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]     // key 一律小写
    var body: Data
    /// 大请求体落在磁盘上时才有值，body 这时是空的。
    /// 视频动辄几百 MB，整份读进内存会被系统杀掉。
    var bodyFile: URL?

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var contentType: String { header("content-type") ?? "" }

    /// application/json 解出的字典
    var jsonObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    func string(_ key: String) -> String? {
        guard let v = jsonObject[key] as? String else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func uuid(_ key: String) -> UUID? {
        guard let v = jsonObject[key] as? String else { return nil }
        return UUID(uuidString: v)
    }
}

// MARK: - 响应

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func html(_ string: String) -> HTTPResponse {
        HTTPResponse(status: 200,
                     headers: ["Content-Type": "text/html; charset=utf-8",
                               "Cache-Control": "no-store"],
                     body: Data(string.utf8))
    }

    static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(string.utf8))
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            headers: ["Content-Type": "application/json; charset=utf-8",
                                      "Cache-Control": "no-store"],
                            body: data)
    }

    static func ok(_ extra: [String: Any] = [:]) -> HTTPResponse {
        var payload: [String: Any] = ["ok": true]
        payload.merge(extra) { _, new in new }
        return .json(payload)
    }

    static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        .json(["ok": false, "error": message], status: status)
    }

    static func binary(_ data: Data, type: String, cacheable: Bool = true) -> HTTPResponse {
        HTTPResponse(status: 200,
                     headers: ["Content-Type": type,
                               "Cache-Control": cacheable ? "public, max-age=31536000" : "no-store"],
                     body: data)
    }

    /// 发磁盘上的一个文件，支持 Range。
    ///
    /// 视频必须支持 Range：不支持的话浏览器拖不动进度条，而且会把几百 MB
    /// 整个塞进一个响应里发出去。每次最多回 chunkCap，剩下的等浏览器再来要。
    static func file(_ url: URL, type: String, range: String?) -> HTTPResponse {
        let chunkCap = 4 * 1024 * 1024

        guard let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil,
              total > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return .notFound
        }
        defer { try? handle.close() }

        var start = 0
        var end = total - 1
        var partial = false

        if let raw = range, let parsed = parseByteRange(raw, total: total) {
            start = parsed.lowerBound
            end = parsed.upperBound
            partial = true
        }
        end = min(end, start + chunkCap - 1)

        guard start <= end else {
            return HTTPResponse(status: 416,
                                headers: ["Content-Range": "bytes */\(total)"],
                                body: Data())
        }

        try? handle.seek(toOffset: UInt64(start))
        let data = (try? handle.read(upToCount: end - start + 1)) ?? Data()

        var headers = [
            "Content-Type": type,
            "Accept-Ranges": "bytes",
            "Cache-Control": "public, max-age=31536000"
        ]
        if partial || end < total - 1 {
            headers["Content-Range"] = "bytes \(start)-\(start + data.count - 1)/\(total)"
            return HTTPResponse(status: 206, headers: headers, body: data)
        }
        return HTTPResponse(status: 200, headers: headers, body: data)
    }

    /// 只认最常见的 "bytes=start-end" / "bytes=start-" / "bytes=-suffix"
    private static func parseByteRange(_ raw: String, total: Int) -> ClosedRange<Int>? {
        guard total > 0 else { return nil }
        let spec = raw.replacingOccurrences(of: "bytes=", with: "").trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }

        let headText = String(spec[spec.startIndex..<dash])
        let tailText = String(spec[spec.index(after: dash)...])

        if headText.isEmpty {
            // bytes=-N：最后 N 个字节
            guard let suffix = Int(tailText), suffix > 0 else { return nil }
            let start = max(0, total - suffix)
            return start...(total - 1)
        }
        guard let start = Int(headText), start >= 0, start < total else { return nil }
        let end = Int(tailText).map { min($0, total - 1) } ?? (total - 1)
        guard end >= start else { return nil }
        return start...end
    }

    static let notFound = HTTPResponse.text("404 Not Found", status: 404)

    var statusText: String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        for (k, v) in headers where k.lowercased() != "content-length" {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}

// MARK: - multipart/form-data 解析

struct MultipartPart {
    var name: String = ""
    var fileName: String?
    var contentType: String?
    var data: Data = Data()
}

enum Multipart {

    static func boundary(from contentType: String) -> String? {
        for piece in contentType.split(separator: ";") {
            let t = piece.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(t.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 直接在原始 body 上扫描，不做整份拷贝——上传几十 MB 时多一份副本就可能触发系统回收
    static func parse(body: Data, boundary: String) -> [MultipartPart] {
        let delimiter = Data("\r\n--\(boundary)".utf8)
        let firstDelimiter = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)
        let terminator = Data("--".utf8)

        // 第一个分隔符前面没有 CRLF，单独找
        guard let head = body.range(of: firstDelimiter) else { return [] }

        var parts: [MultipartPart] = []
        var segmentStart = head.upperBound

        while true {
            // 分隔符后紧跟 "--" 表示整体结束
            if segmentStart + 2 <= body.endIndex,
               body[segmentStart..<(segmentStart + 2)] == terminator {
                break
            }

            var contentStart = segmentStart
            if contentStart + 2 <= body.endIndex,
               body[contentStart..<(contentStart + 2)] == crlf {
                contentStart += 2
            }

            guard contentStart <= body.endIndex,
                  let next = body.range(of: delimiter, in: contentStart..<body.endIndex) else { break }

            if let part = parsePart(Data(body[contentStart..<next.lowerBound])) {
                parts.append(part)
            }

            segmentStart = next.upperBound
            if segmentStart >= body.endIndex { break }
        }

        return parts
    }

    private static func parsePart(_ segment: Data) -> MultipartPart? {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = segment.range(of: sep) else { return nil }
        let headerData = segment[segment.startIndex..<r.lowerBound]
        let payload = Data(segment[r.upperBound...])

        var part = MultipartPart()
        part.data = payload

        let headerText = String(decoding: headerData, as: UTF8.self)
        for line in headerText.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "content-disposition":
                for attr in value.split(separator: ";") {
                    let t = attr.trimmingCharacters(in: .whitespaces)
                    if t.lowercased().hasPrefix("name=") {
                        part.name = unquote(String(t.dropFirst(5)))
                    } else if t.lowercased().hasPrefix("filename=") {
                        part.fileName = unquote(String(t.dropFirst(9)))
                    }
                }
            case "content-type":
                part.contentType = value
            default:
                break
            }
        }
        return part
    }

    private static func unquote(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v.removingPercentEncoding ?? v
    }
}

// MARK: - 局域网地址

enum NetworkInfo {

    /// 取当前 WiFi 的 IPv4 地址
    static func localIPAddress() -> String? {
        var candidate: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        guard let first = ifaddr else { return nil }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  let addrPtr = ptr.pointee.ifa_addr else { continue }

            let family = addrPtr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            // en0 = WiFi，en1/bridge100 = 个人热点或有线
            guard name == "en0" || name == "en1" || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addrPtr,
                                     socklen_t(addrPtr.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty else { continue }

            if name == "en0" { return ip }   // 优先 WiFi
            if candidate == nil { candidate = ip }
        }
        return candidate
    }
}
