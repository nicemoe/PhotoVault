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

    /// AVFoundation 靠得住的那几种封装。
    ///
    /// 「靠得住」和「打得开」是两回事，花屏的根子就在这儿：AVI、WMV、RMVB
    /// 这些 AVFoundation 多半解得开封装、报得出时长和尺寸，看着完全像能播，
    /// 但里面的视频编码（DivX、Xvid、WMV3、RV40）它并不会解，画面就是一片
    /// 彩色马赛克——它不报错，只是把解错的数据照样画出来。
    ///
    /// 所以判据不能是「探不探得出时长」。凡是不在这张表上的封装，
    /// 一律先上软解：慢一点、费点电，但至少画面是对的。
    static let hardwareContainers: Set<String> = [
        "mp4", "m4v", "mov", "qt", "m4p", "3gp", "3g2"
    ]

    /// 这个文件默认该不该走软解
    static func prefersSoftware(fileName: String) -> Bool {
        !hardwareContainers.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// 扫「导入」文件夹时用。
    ///
    /// 网页上传那条路不需要它：文件是用户一个个挑出来的，非图片交给
    /// ImageProbe 判就行。扫文件夹不一样，里面难免混着 .DS_Store、
    /// 说明文档、字幕文件，得先把明显不是媒体的挡在外面。
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp",
        "tif", "tiff", "bmp", "avif", "jfif",
        // 常见 RAW，ImageIO 大多能解
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"
    ]

    static func isImage(fileName: String) -> Bool {
        imageExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }
}
