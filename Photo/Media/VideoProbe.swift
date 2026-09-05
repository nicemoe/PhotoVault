import AVFoundation
import UIKit

/// 视频的元信息与首帧。
///
/// 尺寸、时长、封面都得从文件里现算，不像图片能从头部几百字节读出来，
/// 所以这里全部走异步，别在主线程上等。
enum VideoProbe {

    struct Info {
        var width = 0
        var height = 0
        var duration: Double = 0
    }

    static func inspect(_ url: URL) async -> Info {
        let asset = AVURLAsset(url: url)
        var info = Info()

        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
            info.duration = max(0, seconds)
        }

        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return info
        }

        // naturalSize 是解码后的尺寸，竖着拍的视频要靠 preferredTransform
        // 转过来才是观感上的宽高，否则列表里会全都躺着
        let oriented = size.applying(transform)
        info.width = Int(abs(oriented.width).rounded())
        info.height = Int(abs(oriented.height).rounded())
        return info
    }

    /// 取一帧当封面
    static func poster(for url: URL, maxPixel: Int) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true   // 竖屏视频不能躺着
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // 允许前后各挪一点，否则某些视频的关键帧不在 0 秒会直接失败
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        // 不取第 0 帧：不少视频开头是黑场或渐入，抽出来是一片黑
        let at = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: at).image else { return nil }
        return UIImage(cgImage: cg)
    }
}
