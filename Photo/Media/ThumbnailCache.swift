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

    /// 异步生成缩略图。排队做，别一拥而上。
    ///
    /// 原来是一人一个 Task.detached 全放出去，CPU 被塞满，主线程连排版都排
    /// 不上——点进分组、往下滑的那种一顿一顿就是这么来的。而且 detached 任务
    /// 不继承取消：格子划出屏幕时 SwiftUI 会把 .task 取消掉，里面那个照样跑完，
    /// 快速划过两百个目录就是八百次没人要的解码，把真正在屏幕上的堵在后面。
    ///
    /// 现在不开新任务、直接在这条任务链上做（nonisolated 的 async 本来就跑在
    /// 协作线程池里），外面套闸门。而且分两条队，因为这是两个量级的活：
    ///
    /// - 解一张图（含封面已经落盘的视频）：几十毫秒，三个名额
    /// - 给视频抽一帧：要开解码器解一帧出来，一百到三百毫秒，一个名额
    ///
    /// 目录里全是视频的时候，一屏十来张卡片就是四五十次抽帧。混在一条队里
    /// 会把 CPU 占满，主线程排版被挤到后面。分开之后抽帧慢慢来，封面一张张
    /// 冒出来，但滑动始终是顺的——这个取舍很明确：人能接受封面慢慢出现，
    /// 不能接受滑不动。
    func thumbnail(for asset: Asset, maxPixel: Int) async -> UIImage? {
        if let hit = cached(asset, maxPixel: maxPixel) { return hit }

        await Self.decodeGate.enter()
        var image = await decodeFromDisk(asset, maxPixel: maxPixel)
        await Self.decodeGate.leave()

        // 盘上还没有封面的视频，才需要真的去抽一帧
        if image == nil, asset.isVideo, !Task.isCancelled {
            await Self.posterGate.enter()
            image = await extractPoster(asset, maxPixel: maxPixel)
            await Self.posterGate.leave()
        }

        guard let image else { return nil }
        store(image, id: asset.id, maxPixel: maxPixel)
        return image
    }

    private static let decodeGate = DecodeGate(limit: 3)
    private static let posterGate = DecodeGate(limit: 1)

    /// 从盘上现成的东西解一张图出来。视频看封面文件，没有就返回 nil。
    private func decodeFromDisk(_ asset: Asset, maxPixel: Int) -> UIImage? {
        // 排队的这段时间里格子可能已经划走了，别做这份白工
        guard !Task.isCancelled else { return nil }
        // 也可能别人已经把同一张生成好了
        if let hit = cached(asset, maxPixel: maxPixel) { return hit }

        if asset.isVideo { return posterOnDisk(for: asset, maxPixel: maxPixel) }
        return Self.downsample(url: LibraryStore.fileURL(for: asset), maxPixel: maxPixel)
    }

    /// 趁没人看的时候，把还没有封面的视频一个个抽好。
    ///
    /// 目录封面是四宫格，一张卡片要四个视频的封面。等滑到哪儿才抽哪儿的话，
    /// 第一次进一个分组就是四五十次抽帧排着队，封面得一格一格慢慢冒出来。
    /// 提前抽好之后，那一屏就只剩四五十次 JPEG 解码——便宜一个数量级。
    ///
    /// 一个一个来，走的是和按需抽帧同一条只有一个名额的队：它不该和人正在
    /// 看的那一屏抢 CPU，人要的那张永远排在前面。
    func backfillPosters(for assets: [Asset]) async {
        for asset in assets {
            if Task.isCancelled { return }
            await ensurePoster(for: asset)
        }
    }

    /// 这个视频在盘上有封面吗？没有就抽一张。
    /// 不进内存缓存——补的多半是屏幕上还看不到的那些，占着缓存反而把
    /// 眼前要用的挤出去。
    private func ensurePoster(for asset: Asset) async {
        guard asset.isVideo else { return }
        guard !FileManager.default.fileExists(
            atPath: LibraryStore.posterURL(for: asset.id).path) else { return }

        await Self.posterGate.enter()
        _ = await extractPoster(asset, maxPixel: Self.posterSide)
        await Self.posterGate.leave()
    }

    /// 统一按这个尺寸抽封面，各处再各自降采样，避免同一个视频抽好几遍
    private static let posterSide = 720

    /// 盘上抽好的那张封面。没有就返回 nil，交给 extractPoster 去抽。
    ///
    /// 判断「够不够大」要看**能拿到的上限**，不是看要多大。封面一律按 720 抽，
    /// 而且 AVAssetImageGenerator 的 maximumSize 只缩不放——所以一个视频的封面
    /// 最大就是 min(720, 视频本身的长边)。到了这个数就已经是最好的了，
    /// 再抽一次拿到的还是同一张。
    ///
    /// 原来这里直接拿「要多大」去比，于是两种情况永远不达标、每次都重抽：
    ///
    /// - 预览页要 900，封面只有 720。每打开一次视频就重抽一帧，
    ///   抽完写下去还是 720，下次打开继续重抽。
    /// - 低分辨率的片子，比如 320p 的，封面永远是 320，而列表要 420。
    ///   每滑过它一次就重抽一次，永远进不了那条便宜路。
    private func posterOnDisk(for asset: Asset, maxPixel: Int) -> UIImage? {
        let posterURL = LibraryStore.posterURL(for: asset.id)
        // 这个视频的封面最大能有多大
        let sourceSide = max(asset.width, asset.height)
        let best = sourceSide > 0 ? min(Self.posterSide, sourceSide) : Self.posterSide
        let wanted = min(maxPixel, best)

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
           // 到不了这个数才是真的不能用，那种多半是老版本留下的小图
           max(width, height) >= wanted - 1,
           let image = Self.downsample(source: source, maxPixel: maxPixel) {
            return image
        }

        return nil
    }

    /// 真去开个解码器抽一帧，抽完落盘。
    ///
    /// 这是整条链上最贵的一步，所以单独排一条只有一个名额的队。
    /// 落盘之后下次就走 posterOnDisk 那条便宜路了。
    private func extractPoster(_ asset: Asset, maxPixel: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        // 排队等的这会儿，别人可能已经抽好落盘了
        if let ready = posterOnDisk(for: asset, maxPixel: maxPixel) { return ready }

        let posterURL = LibraryStore.posterURL(for: asset.id)
        guard let full = await VideoProbe.poster(for: LibraryStore.fileURL(for: asset),
                                                 maxPixel: Self.posterSide) else { return nil }
        guard let jpeg = full.jpegData(compressionQuality: 0.82) else { return full }
        try? jpeg.write(to: posterURL, options: .atomic)

        // 要的比抽出来的还大就直接给原图。再 downsample 一次是把刚编码的 JPEG
        // 解回来放大，白解一遍还更糊。
        guard maxPixel < Int(max(full.size.width, full.size.height)) else { return full }
        return Self.downsample(data: jpeg, maxPixel: maxPixel) ?? full
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
