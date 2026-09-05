import UIKit
import ImageIO

/// 缩略图生成 + 内存缓存。线程安全，App 与 WiFi 服务端共用。
final class ThumbnailCache: @unchecked Sendable {

    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 600
        c.totalCostLimit = 220 * 1024 * 1024   // 约 220MB 像素预算
        return c
    }()

    private let lock = NSLock()
    private var keysByAsset: [UUID: Set<String>] = [:]

    private init() {}

    private func key(_ id: UUID, _ maxPixel: Int) -> String { "\(id.uuidString)@\(maxPixel)" }

    // MARK: 读取

    /// 同步取内存缓存，命中即用（避免首帧闪烁）
    func cached(_ asset: Asset, maxPixel: Int) -> UIImage? {
        cache.object(forKey: key(asset.id, maxPixel) as NSString)
    }

    /// 异步生成缩略图
    func thumbnail(for asset: Asset, maxPixel: Int) async -> UIImage? {
        if let hit = cached(asset, maxPixel: maxPixel) { return hit }

        let id = asset.id
        let image: UIImage?
        if asset.isVideo {
            image = await videoPoster(for: asset, maxPixel: maxPixel)
        } else {
            let url = LibraryStore.fileURL(for: asset)
            image = await Task.detached(priority: .userInitiated) {
                Self.downsample(url: url, maxPixel: maxPixel)
            }.value
        }
        guard let image else { return nil }
        store(image, id: id, maxPixel: maxPixel)
        return image
    }

    /// 视频封面：先看磁盘上有没有抽好的，没有再抽一帧存下来。
    /// 抽帧要一两百毫秒，不落盘的话每次冷启动划列表都会卡。
    private func videoPoster(for asset: Asset, maxPixel: Int) async -> UIImage? {
        let posterURL = LibraryStore.posterURL(for: asset.id)

        if let data = try? Data(contentsOf: posterURL),
           let cached = UIImage(data: data) {
            // 存的那张比要的还小就不能用，宁可重抽一次
            if max(cached.size.width, cached.size.height) >= CGFloat(maxPixel) - 1 {
                return Self.downsample(data: data, maxPixel: maxPixel) ?? cached
            }
        }

        // 统一按一个较大的尺寸抽，各处再各自降采样，避免同一个视频抽好几遍
        let posterSide = 720
        guard let full = await VideoProbe.poster(for: LibraryStore.fileURL(for: asset),
                                                 maxPixel: posterSide) else { return nil }
        if let jpeg = full.jpegData(compressionQuality: 0.82) {
            try? jpeg.write(to: posterURL, options: .atomic)
            return Self.downsample(data: jpeg, maxPixel: maxPixel) ?? full
        }
        return full
    }

    /// 服务端用：直接拿到 JPEG 数据。
    ///
    /// 走的是和 App 里同一条路，视频没抽过封面就现抽一张。
    /// 只读磁盘上已有的话，刚从网页传上来的视频会一直是 404，
    /// 非得等你在 App 里划到它才有图。
    func thumbnailData(for asset: Asset, maxPixel: Int, quality: CGFloat = 0.82) async -> Data? {
        guard let image = await thumbnail(for: asset, maxPixel: maxPixel) else { return nil }
        return image.jpegData(compressionQuality: quality)
    }

    private func store(_ image: UIImage, id: UUID, maxPixel: Int) {
        let k = key(id, maxPixel)
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: k as NSString, cost: cost)
        lock.lock()
        keysByAsset[id, default: []].insert(k)
        lock.unlock()
    }

    func invalidate(_ id: UUID) {
        lock.lock()
        let keys = keysByAsset.removeValue(forKey: id) ?? []
        lock.unlock()
        for k in keys { cache.removeObject(forKey: k as NSString) }
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        keysByAsset.removeAll()
        lock.unlock()
    }

    // MARK: 降采样

    static func downsample(url: URL, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return downsample(source: source, maxPixel: maxPixel)
    }

    static func downsample(data: Data, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return downsample(source: source, maxPixel: maxPixel)
    }

    private static func downsample(source: CGImageSource, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
