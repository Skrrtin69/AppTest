import UIKit
import ImageIO

/// Loads media bytes through the two-tier cache (limited by the "max thumbnail loads" slider)
/// and decodes them into (possibly animated) UIImages.
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let semaphore: AsyncSemaphore
    private let decoded = NSCache<NSString, UIImage>()

    private init() {
        let initial = UserDefaults.standard.object(forKey: AppSettings.K.maxThumbLoads) as? Int ?? 6
        semaphore = AsyncSemaphore(limit: initial)
        decoded.totalCostLimit = 120 * 1024 * 1024
        decoded.countLimit = 400
        // Under memory pressure, drop every decoded image (bytes stay in the disk cache).
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.decoded.removeAllObjects()
        }
    }

    func isInMemory(_ url: URL, maxPixel: CGFloat, animate: Bool) -> Bool {
        decoded.object(forKey: "\(url.absoluteString)|\(Int(maxPixel))|\(animate)" as NSString) != nil
    }

    func setConcurrency(_ n: Int) {
        Task { await semaphore.setLimit(n) }
    }

    /// Raw bytes for a URL: memory → disk → network.
    func data(for url: URL, client: NetworkClient? = nil) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        // No client given: use the adapter that owns this host, so its headers still apply.
        let c = client ?? NetworkClient.forMedia(url)
        if let d = await ImageCache.shared.data(for: url, siteID: c.siteID) { return d }
        let data: Data = try await semaphore.run {
            // Media requests skip the adapter's API rate limit; the semaphore bounds them instead.
            try await c.mediaData(for: url)
        }
        await ImageCache.shared.store(data, for: url, siteID: c.siteID)
        return data
    }

    /// Decoded image, downsampled to `maxPixel` (0 = full size). GIFs come back animated.
    func image(for url: URL, maxPixel: CGFloat = 0, animate: Bool = true, client: NetworkClient? = nil) async throws -> UIImage {
        let key = "\(url.absoluteString)|\(Int(maxPixel))|\(animate)" as NSString
        if let img = decoded.object(forKey: key) { return img }
        let data = try await data(for: url, client: client)
        let image = try await Task.detached(priority: .userInitiated) {
            try Self.decode(data, maxPixel: maxPixel, animate: animate)
        }.value
        decoded.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    func prefetch(_ urls: [URL], client: NetworkClient? = nil) {
        for u in urls {
            Task.detached(priority: .utility) { _ = try? await self.data(for: u, client: client) }
        }
    }

    func clearMemory() { decoded.removeAllObjects() }

    static func cost(of image: UIImage) -> Int {
        let frames = max(1, image.images?.count ?? 1)
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4) * frames
    }

    static func isGIF(_ data: Data) -> Bool {
        data.count > 6 && data.prefix(4) == Data("GIF8".utf8)
    }

    static func decode(_ data: Data, maxPixel: CGFloat, animate: Bool) throws -> UIImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AppError.message("This file isn't an image the app can display.")
        }
        let count = CGImageSourceGetCount(src)
        let maxPixel = Self.effectiveMaxPixel(src, requested: maxPixel)
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if maxPixel > 0 { opts[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }

        func frame(_ i: Int) -> CGImage? {
            if maxPixel > 0 { return CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) }
            return CGImageSourceCreateImageAtIndex(src, i, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }

        if animate, count > 1, isGIF(data) {
            var images: [UIImage] = []
            var duration: Double = 0
            // Cap frames to keep memory reasonable.
            for i in 0..<min(count, 300) {
                guard let cg = frame(i) else { continue }
                images.append(UIImage(cgImage: cg))
                duration += frameDelay(src, i)
            }
            if let anim = UIImage.animatedImage(with: images, duration: max(duration, 0.1)) { return anim }
        }
        guard let cg = frame(0) else { throw AppError.message("The image data is damaged or in an unknown format.") }
        return UIImage(cgImage: cg)
    }

    /// Tall strips (webtoons) are limited by *width* instead of their long side, so they stay
    /// sharp; and no image is ever decoded above ~24 megapixels, to avoid memory crashes.
    static func effectiveMaxPixel(_ src: CGImageSource, requested: CGFloat) -> CGFloat {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return requested }
        let budget = 24_000_000.0
        var longSide = requested > 0 ? Double(requested) : max(w, h)
        if requested > 0 && h / w > 2.5 {
            // `requested` becomes the target width; the long side follows the aspect ratio.
            longSide = min(h, Double(requested) * h / w)
        }
        // Pixels at this size, capped to the budget.
        let scale = longSide / max(w, h)
        let pixels = w * h * scale * scale
        if pixels > budget { longSide *= (budget / pixels).squareRoot() }
        if requested == 0 && longSide >= max(w, h) { return 0 }   // full size fits the budget
        return CGFloat(longSide.rounded())
    }

    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return d < 0.02 ? 0.1 : d
    }
}
