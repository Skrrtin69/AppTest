import Foundation
import UIKit
import ImageIO
import Vision
import CoreImage

/// Work done on a file right after it's downloaded: strip camera data (EXIF/GPS/XMP) and
/// add hidden visual tags, both only when switched on in Settings.
enum DownloadPostProcess {
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff"]

    static func run(_ file: URL, itemID: String) {
        let ext = file.pathExtension.lowercased()
        guard imageExts.contains(ext) else { return }
        let settings = AppSettings.shared
        if settings.stripEXIF { stripMetadata(file) }
        if settings.autoTagDownloads {
            DispatchQueue.global(qos: .utility).async {
                let labels = AutoTags.classify(file)
                if !labels.isEmpty { DispatchQueue.main.async { AutoTags.shared.set(labels, for: itemID) } }
            }
        }
    }

    /// Rewrites the file without its metadata. JPEGs are copied without re-compression.
    @discardableResult
    static func stripMetadata(_ file: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(src) else { return false }
        let count = CGImageSourceGetCount(src)
        guard count == 1 else { return false }   // animations are left alone
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".strip-\(UUID().uuidString)")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
        let empty = CGImageMetadataCreateMutable()
        let opts: [CFString: Any] = [
            kCGImageDestinationMetadata: empty,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var err: Unmanaged<CFError>?
        var ok = CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err)
        if !ok, let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
           let dest2 = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) {
            // Fallback: write the pixels only (keeps orientation by drawing it in).
            CGImageDestinationAddImage(dest2, img, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            ok = CGImageDestinationFinalize(dest2)
        }
        guard ok else { try? FileManager.default.removeItem(at: tmp); return false }
        do {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
            DebugLog.log("EXIF", "stripped \(file.lastPathComponent)")
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}

/// Hidden visual tags for downloaded pictures (Vision image classification), stored next to
/// the downloads and searched by the Library's search field.
final class AutoTags: ObservableObject {
    static let shared = AutoTags()
    @Published private(set) var byItem: [String: [String]] = [:]

    private var file: URL { DownloadManager.root.appendingPathComponent(".autotags.json") }

    private init() {
        if let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([String: [String]].self, from: d) { byItem = m }
    }

    func set(_ labels: [String], for id: String) {
        byItem[id] = labels
        if let d = try? JSONEncoder().encode(byItem) { try? d.write(to: file, options: .atomic) }
    }

    func labels(_ id: String) -> [String] { byItem[id] ?? [] }

    static func classify(_ file: URL) -> [String] {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 600] as CFDictionary) else { return [] }
        let r = VNClassifyImageRequest()
        r.preferBackgroundProcessing = true
        guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([r])) != nil else { return [] }
        let labels = (r.results ?? []).filter { $0.confidence > 0.3 }.prefix(10).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        DebugLog.log("AutoTag", "\(file.lastPathComponent): \(labels.joined(separator: ", "))")
        return Array(labels)
    }
}

// MARK: - Library search with filters

/// "Advanced Search" in the Library: words plus filters such as size:>5MB, ratio:>2:1,
/// source:demo-a, type:video. Each filter becomes an NSPredicate; all must match.
enum LibraryQuery {
    struct Candidate {
        let item: DownloadItem
        let bytes: Int
        let pixelSize: CGSize?
        let words: String
    }

    static func predicate(_ text: String) -> NSPredicate {
        var parts: [NSPredicate] = []
        for token in text.split(separator: " ").map(String.init) where !token.isEmpty {
            parts.append(predicate(token: token))
        }
        return parts.isEmpty ? NSPredicate(value: true) : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    private static func predicate(token: String) -> NSPredicate {
        let lower = token.lowercased()
        func block(_ f: @escaping (Candidate) -> Bool) -> NSPredicate {
            NSPredicate { obj, _ in (obj as? CandidateBox).map { f($0.c) } ?? false }
        }
        if lower.hasPrefix("size:") {
            let (op, rest) = comparator(String(lower.dropFirst(5)))
            guard let limit = bytes(rest) else { return NSPredicate(value: true) }
            return block { op(Double($0.bytes), Double(limit)) }
        }
        if lower.hasPrefix("ratio:") {
            let (op, rest) = comparator(String(lower.dropFirst(6)))
            let nums = rest.split(separator: ":").compactMap { Double($0) }
            let r = nums.count == 2 && nums[1] > 0 ? nums[0] / nums[1] : (nums.first ?? 1)
            return block { c in c.pixelSize.map { op(Double($0.width / max($0.height, 1)), r) } ?? false }
        }
        if lower.hasPrefix("source:") || lower.hasPrefix("site:") {
            let s = String(lower.split(separator: ":", maxSplits: 1).last ?? "")
            return block { $0.item.post.siteID.lowercased() == s || AdapterRegistry.shared.displayName(for: $0.item.post.siteID).lowercased().contains(s) }
        }
        if lower.hasPrefix("type:") {
            let t = String(lower.dropFirst(5))
            return block { $0.item.post.mediaType.rawValue.lowercased() == t || ($0.item.fileURL?.pathExtension.lowercased() == t) }
        }
        let negate = lower.hasPrefix("-")
        let word = negate ? String(lower.dropFirst()) : lower
        return block { negate ? !$0.words.contains(word) : $0.words.contains(word) }
    }

    /// ">", ">=", "<", "<=", "=" (default ">=" when none is given... plain value means "at least").
    private static func comparator(_ s: String) -> ((Double, Double) -> Bool, String) {
        for (p, f) in [(">=", { (a: Double, b: Double) in a >= b }), ("<=", { $0 <= $1 }), (">", { $0 > $1 }), ("<", { $0 < $1 }), ("=", { abs($0 - $1) < 0.01 })] as [(String, (Double, Double) -> Bool)] {
            if s.hasPrefix(p) { return (f, String(s.dropFirst(p.count))) }
        }
        return ({ $0 >= $1 }, s)
    }

    /// "5mb", "500kb", "1.5gb", "1200" (bytes).
    static func bytes(_ s: String) -> Int? {
        let units: [(String, Double)] = [("gb", 1_073_741_824), ("mb", 1_048_576), ("kb", 1024), ("b", 1)]
        for (u, m) in units where s.hasSuffix(u) { return Double(s.dropLast(u.count)).map { Int($0 * m) } }
        return Double(s).map { Int($0) }
    }

    final class CandidateBox: NSObject { let c: Candidate; init(_ c: Candidate) { self.c = c } }

    private static var sizeCache: [String: CGSize] = [:]

    static func candidate(_ item: DownloadItem) -> Candidate {
        let file = item.fileURL
        let bytes = file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? Int(item.bytesTotal)
        var size = item.post.pixelSize
        if size == nil, let f = file {
            if let s = sizeCache[f.path] { size = s }
            else if let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                    let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                    let w = p[kCGImagePropertyPixelWidth] as? Double, let h = p[kCGImagePropertyPixelHeight] as? Double {
                size = CGSize(width: w, height: h); sizeCache[f.path] = size
            }
        }
        let words = ([item.filename, item.post.siteID, item.post.id] + item.post.tags + AutoTags.shared.labels(item.id)).joined(separator: " ").lowercased()
        return Candidate(item: item, bytes: bytes, pixelSize: size, words: words)
    }

    static func filter(_ items: [DownloadItem], _ text: String) -> [DownloadItem] {
        let p = predicate(text)
        return items.filter { p.evaluate(with: CandidateBox(candidate($0))) }
    }
}

// MARK: - Local duplicates (perceptual hash)

enum PerceptualHash {
    /// 64-bit difference hash: 9×8 grayscale, each bit = left pixel brighter than right.
    static func dHash(_ file: URL) -> UInt64? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return nil }
        var px = [UInt8](repeating: 0, count: 9 * 8)
        guard let ctx = CGContext(data: &px, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        var h: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { h <<= 1; if px[y * 9 + x] > px[y * 9 + x + 1] { h |= 1 } } }
        return h
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}
