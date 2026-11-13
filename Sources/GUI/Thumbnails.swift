// 缩略图：后台用 ImageIO 按需要的像素尺寸生成，带缓存，并发数有上限，滚出屏幕的取消。
//
// 生成只发生在 OperationQueue 上（render 开头有 dispatchPrecondition，主线程上调用会直接
// 停下）；主线程只查缓存。

import AppKit
import ImageIO

final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, CGImage>()
    private let queue: OperationQueue

    init(maxConcurrent: Int = 4) {
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrent
        queue.qualityOfService = .userInitiated
        cache.countLimit = 1500
    }

    /// 像素尺寸按 64 取整，缩放一点点时不必重新生成。
    static func bucket(_ pixels: CGFloat) -> Int { max(64, Int((pixels / 64).rounded(.up)) * 64) }

    private func key(_ item: PhotoItem, _ pixels: Int) -> NSString {
        "\(item.path)|\(item.modified.timeIntervalSince1970)|\(item.size)|\(pixels)" as NSString
    }

    /// 缓存里已有的缩略图（主线程可调，不碰磁盘）。
    func cached(_ item: PhotoItem, pixels: CGFloat) -> CGImage? {
        cache.object(forKey: key(item, ThumbnailLoader.bucket(pixels)))
    }

    /// 后台生成；完成后在主线程回调（被取消的不回调）。返回的操作可以取消。
    @discardableResult
    func load(_ item: PhotoItem, pixels: CGFloat, completion: @escaping (CGImage?) -> Void) -> Operation? {
        let size = ThumbnailLoader.bucket(pixels)
        let k = key(item, size)
        if let hit = cache.object(forKey: k) { completion(hit); return nil }
        let url = item.url
        let op = BlockOperation()
        op.addExecutionBlock { [weak op, cache] in
            guard let op, !op.isCancelled else { return }
            let image = ThumbnailLoader.render(url, maxPixels: size)
            if let image { cache.setObject(image, forKey: k) }
            DispatchQueue.main.async {
                guard !op.isCancelled else { return }
                completion(image)
            }
        }
        queue.addOperation(op)
        return op
    }

    /// 还在排队或正在生成的个数（测量用）。
    var pendingCount: Int { queue.operationCount }

    /// 生成一张缩略图：长边不超过 `maxPixels`，按 EXIF 方向转正。相机 RAW 先用内嵌的预览，不整幅
    /// 显影（取法见 makeThumbnail）。
    static func render(_ url: URL, maxPixels: Int) -> CGImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return makeThumbnail(src, maxPixels: maxPixels)
    }
}
