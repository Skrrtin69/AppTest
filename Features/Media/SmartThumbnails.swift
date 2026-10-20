import SwiftUI
import UIKit
import Vision

/// Square thumbnails cropped around what's interesting in the picture (Vision attention
/// saliency) instead of always the middle. Runs off the main thread with
/// preferBackgroundProcessing; each picture's focus point is cached in memory and on disk.
enum SmartCrop {
    private static let images = NSCache<NSString, UIImage>()
    private static let lock = NSLock()
    private static var focusPoints: [String: [Double]] = load()
    private static var saveWork: DispatchWorkItem?
    private static let visionQueue = DispatchQueue(label: "smartcrop.vision", qos: .utility)

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SmartCropFocus.json")
    }

    private static func load() -> [String: [Double]] {
        guard let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([String: [Double]].self, from: d) else { return [:] }
        return m
    }

    private static func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem {
            lock.lock(); let snapshot = focusPoints; lock.unlock()
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) }
        }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: w)
    }

    /// A square crop of `image` around its most eye-catching area.
    static func square(_ image: UIImage, key: String) async -> UIImage {
        if let c = images.object(forKey: key as NSString) { return c }
        guard image.images == nil, let cg = image.cgImage else { return image }
        let focus = await focusPoint(cg, key: key)
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let side = min(w, h)
        let x = min(max(0, focus.x * w - side / 2), w - side)
        let y = min(max(0, focus.y * h - side / 2), h - side)
        guard let cropped = cg.cropping(to: CGRect(x: x, y: y, width: side, height: side).integral) else { return image }
        let out = UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
        images.setObject(out, forKey: key as NSString, cost: Int(side * side * 4))
        return out
    }

    /// Unit point (0…1, origin top-left) at the center of the salient area; the middle if
    /// nothing stands out.
    static func focusPoint(_ cg: CGImage, key: String) async -> CGPoint {
        lock.lock(); let known = focusPoints[key]; lock.unlock()
        if let p = known, p.count == 2 { return CGPoint(x: p[0], y: p[1]) }
        // Vision runs on its own serial queue, outside Swift's shared task pool (a detached
        // task there never got a thread while the grid was loading).
        let result: CGPoint? = await withCheckedContinuation { cont in
            visionQueue.async {
                let request = VNGenerateAttentionBasedSaliencyImageRequest()
                request.preferBackgroundProcessing = true
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do { try handler.perform([request]) } catch {
                    NSLog("[SmartCrop] Vision failed: %@", error.localizedDescription)
                    cont.resume(returning: nil)
                    return
                }
                guard let obs = request.results?.first as? VNSaliencyImageObservation,
                      let boxes = obs.salientObjects, !boxes.isEmpty else {
                    cont.resume(returning: CGPoint(x: 0.5, y: 0.5))
                    return
                }
                // Union of the salient areas; Vision's origin is bottom-left.
                let u = boxes.map(\.boundingBox).reduce(boxes[0].boundingBox) { $0.union($1) }
                cont.resume(returning: CGPoint(x: u.midX, y: 1 - u.midY))
            }
        }
        guard let point = result else { return CGPoint(x: 0.5, y: 0.5) }
        lock.lock(); focusPoints[key] = [Double(point.x), Double(point.y)]; lock.unlock()
        scheduleSave()
        return point
    }

    static func clear() {
        images.removeAllObjects()
        lock.lock(); focusPoints = [:]; lock.unlock()
        try? FileManager.default.removeItem(at: file)
    }
}

/// A grid thumbnail cropped with SmartCrop.
struct SmartThumbnail: View {
    let url: URL
    var client: NetworkClient?
    @StateObject private var model = ImageLoadModel()
    @State private var cropped: UIImage?

    var body: some View {
        ZStack {
            // The plain (centered) thumbnail shows at once; the smart crop replaces it when ready.
            if let img = cropped ?? model.image {
                Image(uiImage: img).resizable().scaledToFill()
            } else if model.error != nil {
                Image(systemName: "exclamationmark.triangle").foregroundColor(.secondary)
            } else {
                Color.gray.opacity(0.15).overlay(ProgressView())
            }
        }
        .task(id: url) {
            await model.load(url, maxPixel: 420, animate: false, client: client, onLoad: nil)
            if let img = model.image { cropped = await SmartCrop.square(img, key: url.absoluteString) }
        }
        .onDisappear { model.release(); cropped = nil }
    }
}
