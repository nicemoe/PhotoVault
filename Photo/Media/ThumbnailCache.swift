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

    /// 抽不出封面的那些。
    ///
    /// 文件坏了、编码解不了，抽多少次都是抽不出来。而补封面那一趟每次切回
    /// 前台都要跑，不记着的话这些视频每次都要再开一遍解码器白试一次——
    /// 五十个坏文件就是每次切回前台十来秒的 CPU 和视频解码器空转。
    ///
    /// 只记在内存里，重启就忘。这样把坏文件换掉之后什么都不用做，
    /// 下次启动自然会再试一次。
    private var hopelessPosters = Set<UUID>()

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

        lock.lock()
        let hopeless = hopelessPosters.contains(asset.id)
        lock.unlock()
        guard !hopeless else { return nil }

        let posterURL = LibraryStore.posterURL(for: asset.id)
        guard let full = await VideoProbe.poster(for: LibraryStore.fileURL(for: asset),
                                                 maxPixel: Self.posterSide) else {
            // 记一笔，这轮别再来了
            lock.lock()
            hopelessPosters.insert(asset.id)
            lock.unlock()
            return nil
        }
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
        // 这个文件被换掉或删掉了，「抽不出来」那笔记录跟着作废
        hopelessPosters.remove(id)
        lock.unlock()
        for k in keys { cache.removeObject(forKey: k as NSString) }
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        keysByAsset.removeAll()
        hopelessPosters.removeAll()
        lock.unlock()
    }

    // MARK: 拼贴

    /// 把几张图拼成一张，拼好的整张进缓存。
    ///
    /// 四宫格卡在**渲染**上，不是解码上：图早就在内存里了，滑动还是顿。
    /// 一个格子四张图就是四套图层、四次裁剪，还套在外面那层圆角裁剪里；
    /// 而 LazyVGrid 每滑出一行要一次性把整行的格子全建出来，那一帧的活
    /// 就是四倍。换成单图就顺，差别全在这儿。
    ///
    /// 所以别让它在渲染时拼。后台画成一张位图，格子里就一张图，
    /// 和单图一样轻，四宫格的样子还留着。
    ///
    /// 缓存键带上这几张图的 id：目录里进了新东西、封面换人了，键就变了，
    /// 自然会重拼一张。
    func collage(of assets: [Asset], side: CGFloat, gap: CGFloat, scale: CGFloat) async -> UIImage? {
        guard !assets.isEmpty, side > 1 else { return nil }

        // 键按候选算，不按最后用上的那几张。这样某个坏文件今天抽不出、
        // 明天换好了能抽出来，键是同一个——真要它重拼，靠的是候选变了
        // （目录里进了新东西），那才是封面该换的时候。
        let key = "collage@\(Int(side)):" + assets.map(\.id.uuidString).joined(separator: ",")
        if let hit = cache.object(forKey: key as NSString) { return hit }

        // 每格实际占多大就要多大。四宫格一格只占一半，按整张卡的分辨率去解
        // 就是四倍的像素白解。
        let tilePixels = Int((assets.count > 1 ? side / 2 : side) * scale)

        // 凑四张能用的。
        //
        // 有的文件是坏的——视频抽不出帧、图片解不开。原来碰上一个就整张
        // 不画了，于是一个坏文件能让整个目录显示成空白封面。现在跳过它，
        // 接着往下取，候选是多备了的（PhotoGroup.coverCandidates）。
        var tiles: [UIImage] = []
        for asset in assets {
            guard !Task.isCancelled else { return nil }
            if let tile = await thumbnail(for: asset, maxPixel: tilePixels) { tiles.append(tile) }
            if tiles.count == 4 { break }
        }
        guard !tiles.isEmpty else { return nil }

        // 只凑出一张的话，那一张要独占整个封面，得按整张卡的分辨率重取，
        // 不然半格大小的图拉满一张卡是糊的
        if tiles.count == 1, assets.count > 1,
           let asset = assets.first(where: { cached($0, maxPixel: tilePixels) != nil }),
           let full = await thumbnail(for: asset, maxPixel: Int(side * scale)) {
            tiles = [full]
        }

        let made = Self.compose(tiles, side: side, gap: gap, scale: scale)
        let cost = Int(side * side * scale * scale * 4)
        cache.setObject(made, forKey: key as NSString, cost: cost)

        // 登记到候选的每一张名下。
        //
        // 删掉封面里的某个文件之后，界面本来就会自己纠正——候选换人了，
        // 键跟着变，重拼一张。但旧那张位图是拿不到也删不掉的死数据，
        // 只能等缓存自己淘汰。登记之后，删这个文件时 invalidate 会顺手
        // 把它带走。挂在所有候选名下，谁没了都算数——包括那些没被用上的，
        // 它们本来就是「万一前面的坏了顶上来」的备选。
        lock.lock()
        for asset in assets { keysByAsset[asset.id, default: []].insert(key) }
        lock.unlock()
        return made
    }

    private static func compose(_ tiles: [UIImage], side: CGFloat,
                                gap: CGFloat, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        // 不透明会把缝隙涂成黑的。留透明，缝隙交给底下的 SwiftUI 背景色，
        // 这样浅色深色都对——位图是当场画的，烘不进主题色。
        format.opaque = false

        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            for (tile, rect) in zip(tiles, Self.tileFrames(count: tiles.count, side: side, gap: gap)) {
                Self.drawFilling(tile, in: rect)
            }
        }
    }

    /// 每一格摆在哪儿。和原来那套 SwiftUI 布局一一对应。
    private static func tileFrames(count: Int, side: CGFloat, gap: CGFloat) -> [CGRect] {
        let half = (side - gap) / 2
        switch count {
        case 1:
            return [CGRect(x: 0, y: 0, width: side, height: side)]
        case 2:
            return [CGRect(x: 0, y: 0, width: half, height: side),
                    CGRect(x: half + gap, y: 0, width: half, height: side)]
        case 3:
            return [CGRect(x: 0, y: 0, width: half, height: side),
                    CGRect(x: half + gap, y: 0, width: half, height: half),
                    CGRect(x: half + gap, y: half + gap, width: half, height: half)]
        default:
            return [CGRect(x: 0, y: 0, width: half, height: half),
                    CGRect(x: half + gap, y: 0, width: half, height: half),
                    CGRect(x: 0, y: half + gap, width: half, height: half),
                    CGRect(x: half + gap, y: half + gap, width: half, height: half)]
        }
    }

    /// 按 aspect fill 画进这一格：铺满，多出来的裁掉。
    private static func drawFilling(_ image: UIImage, in rect: CGRect) {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0, let ctx = UIGraphicsGetCurrentContext() else { return }
        let ratio = max(rect.width / w, rect.height / h)
        let filled = CGSize(width: w * ratio, height: h * ratio)
        ctx.saveGState()
        ctx.clip(to: rect)
        image.draw(in: CGRect(x: rect.midX - filled.width / 2,
                              y: rect.midY - filled.height / 2,
                              width: filled.width, height: filled.height))
        ctx.restoreGState()
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
