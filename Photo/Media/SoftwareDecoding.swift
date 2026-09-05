import Foundation
import KSPlayer

/// 软解播放（KSPlayer + FFmpeg）。
///
/// AVFoundation 只认 mp4/mov 那一小撮封装，mkv、rmvb、wmv 这些它连解封装
/// 都做不到。KSMEPlayer 自带一整套 FFmpeg，能解的范围大得多，代价是
/// 纯软件解码——费电、发热，高码率 4K 会掉帧。所以只在 AVFoundation
/// 确实解不了的时候才切过来，能硬解的照旧走 AVPlayer。
enum SoftwareDecoding {

    @MainActor
    static func makePlayer(url: URL) -> KSMEPlayer {
        KSMEPlayer(url: url, options: KSOptions())
    }
}
