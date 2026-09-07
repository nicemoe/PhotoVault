import UIKit
import ImageIO

/// 同时最多让几张图在解码。
///
/// 一个简单的异步信号量。拿不到名额的挂在 waiting 里，前面的人做完再放行。
actor DecodeGate {

    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func enter() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        // 有人在排队就直接把名额交给他，running 不用动
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

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

    /// 异步生成缩略图。
    ///
    /// 排队做，一次最多三张。
    ///
    /// 一屏目录卡片能同时挂起四五十张缩略图，每张都是一次全尺寸 JPEG 解码，
    /// 几十毫秒起步。原来是一人一个 Task.detached 全放出去，CPU 被塞满，
    /// 主线程连排版都排不上——点进分组、往下滑的那种一顿一顿就是这么来的。
    ///
    /// 更要命的是 detached 任务不继承取消。格子划出屏幕时 SwiftUI 会把
    /// .task 取消掉，但里面那个 detached 照样跑完。快速划过两百个目录，
    /// 就是八百次没人要的解码还在排着队，把后面真正在屏幕上的那些堵在后面。
    ///
    /// 改成不开新任务、直接在这条任务链上做：取消就传得下来，排到自己时
    /// 先看一眼还要不要，不要就跳过。三个名额是拍的——够喂饱屏幕，
    /// 又不至于把 CPU 占光。
    func thumbnail(for asset: Asset, maxPixel: Int) async -> UIImage? {
        if let hit = cached(asset, maxPixel: maxPixel) { return hit }

        await Self.gate.enter()
        let image = await generate(asset, maxPixel: maxPixel)
        await Self.gate.leave()

        guard let image else { return nil }
        store(image, id: asset.id, maxPixel: maxPixel)
        return image
    }

    private static let gate = DecodeGate(limit: 3)

    private func generate(_ asset: Asset, maxPixel: Int) async -> UIImage? {
        // 排队的这段时间里格子可能已经划走了，别做这份白工
        guard !Task.isCancelled else { return nil }
        // 也可能别人已经把同一张生成好了
        if let hit = cached(asset, maxPixel: maxPixel) { return hit }

        if asset.isVideo { return await videoPoster(for: asset, maxPixel: maxPixel) }
        // 这个方法本身就不在主线程上（nonisolated 的 async 一定跑在协作线程池里），
        // 不用再开一层任务——开了反而把取消断在这儿。
        return Self.downsample(url: LibraryStore.fileURL(for: asset), maxPixel: maxPixel)
    }

    /// 视频封面：先看磁盘上有没有抽好的，没有再抽一帧存下来。
    /// 抽帧要一两百毫秒，不落盘的话每次冷启动划列表都会卡。
    private func videoPoster(for asset: Asset, maxPixel: Int) async -> UIImage? {
        let posterURL = LibraryStore.posterURL(for: asset.id)

        // 先只问尺寸，别把整张解出来。
        //
        // 原来是 UIImage(data:) 先整张解一遍看它多大，够大再 downsample 解第二遍
        // ——同一张 720px 的 JPEG 白解了一次。一屏目录卡片有几十张封面，
        // 每张都多解一遍，滑动时就顶到主线程的排版上了。
        // CGImageSource 读属性只碰文件头，不碰像素。
        if let source = CGImageSourceCreateWithURL(
            posterURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int,
           // 存的那张比要的还小就不能用，宁可重抽一次
           max(width, height) >= maxPixel - 1,
           let image = Self.downsample(source: source, maxPixel: maxPixel) {
            return image
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
