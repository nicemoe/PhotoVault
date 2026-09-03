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
        let url = LibraryStore.fileURL(for: asset)
        let id = asset.id
        let image = await Task.detached(priority: .userInitiated) {
            Self.downsample(url: url, maxPixel: maxPixel)
        }.value
        guard let image else { return nil }
        store(image, id: id, maxPixel: maxPixel)
        return image
    }

    /// 服务端用：直接拿到 JPEG 数据
    func thumbnailData(for asset: Asset, maxPixel: Int, quality: CGFloat = 0.82) -> Data? {
        let image: UIImage
        if let hit = cached(asset, maxPixel: maxPixel) {
            image = hit
        } else {
            guard let made = Self.downsample(url: LibraryStore.fileURL(for: asset), maxPixel: maxPixel) else { return nil }
            store(made, id: asset.id, maxPixel: maxPixel)
            image = made
        }
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
