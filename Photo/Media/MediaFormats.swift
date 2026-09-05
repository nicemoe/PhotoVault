import Foundation

/// 认识哪些媒体格式。
///
/// 图片不在这里列——ImageProbe 走的是 ImageIO，它支持什么就认什么
/// （JPEG/PNG/HEIC/GIF/WebP/TIFF/PSD/各家 RAW…），列白名单反而会漏。
/// 视频没有这种「拿来就能探测」的路子：文件动辄几百 MB，不能为了判断类型
/// 先读进内存，multipart 里的 Content-Type 又由浏览器给，从网上存下来的
/// 视频常常是 application/octet-stream，所以只能按扩展名认。
enum MediaFormats {

    /// 尽量列全。iOS 能不能解码是另一回事——认下来至少文件存住了，
    /// 解不了的会在列表里显示成占位图，播放时提示格式不支持。
    static let videoExtensions: Set<String> = [
        // iOS 原生能播的
        "mp4", "m4v", "mov", "qt", "3gp", "3g2", "m4p",
        // 广播/摄像机常见封装
        "mts", "m2ts", "ts", "mpg", "mpeg", "mpe", "m2v", "mxf", "dv",
        // 其他常见封装（多数要靠外部解码器，这里只负责存住）
        "avi", "mkv", "webm", "wmv", "asf", "flv", "f4v",
        "rm", "rmvb", "vob", "ogv", "ogm", "divx", "xvid", "amv", "m2p"
    ]

    static func isVideo(fileName: String) -> Bool {
        videoExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }
}
