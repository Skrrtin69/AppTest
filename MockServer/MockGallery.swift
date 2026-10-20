import UIKit

/// Demo site G: multi-page posts (albums / comics). Each result has a cover, its first page as
/// the file, and a `pages` list of objects with a `url` — some galleries are long vertical strips.
enum MockGallery {
    struct Gallery {
        let n: Int
        let pageCount: Int
        let tall: Bool
        let tags: [String]
    }

    static let galleries: [Gallery] = (1...14).map { n in
        let color = MockCatalog.colors[n % MockCatalog.colors.count]
        let tall = n % 4 == 0
        let count = n == 1 ? 24 : (n == 7 ? 1 : (tall ? 3 + n % 3 : 2 + (n * 5) % 11))
        return Gallery(n: n, pageCount: count, tall: tall,
                       tags: [color, tall ? "long_strip" : "album", n % 2 == 0 ? "comic" : "photos"])
    }

    static func pageURL(_ g: Gallery, _ p: Int, origin: String) -> String {
        g.tall ? "\(origin)/media/tall/\(g.n)-\(p).png" : "\(origin)/media/page/\(g.n)-\(p).png"
    }

    static func respond(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        switch sub {
        case "", "/":
            return .text("<!doctype html><html><head><title>Demo G</title><link rel=\"alternate\" type=\"application/json\" href=\"\(origin)/g/posts.json\"></head><body><h1>Demo G</h1></body></html>",
                         type: "text/html; charset=utf-8")
        case "/posts.json":
            let words = (req.query["tags"] ?? "").replacingOccurrences(of: "+", with: " ")
                .split(separator: " ").map { String($0).lowercased() }
            let all = galleries.filter { g in words.allSatisfy { g.tags.contains($0) } }
            let page = max(1, Int(req.query["page"] ?? "1") ?? 1)
            let size = 10
            let start = (page - 1) * size
            let slice = start < all.count ? Array(all[start..<min(all.count, start + size)]) : []
            return .json([
                "galleries": slice.map { g -> [String: Any] in
                    [
                        "id": "g\(g.n)",
                        "title": "Demo gallery \(g.n)",
                        "tags": g.tags,
                        "cover": "\(origin)/media/gthumb/\(g.n).png",
                        "file_url": pageURL(g, 1, origin: origin),
                        "pages": (1...g.pageCount).map { p in ["url": pageURL(g, p, origin: origin), "number": p] as [String: Any] },
                    ]
                },
                "total": all.count,
            ])
        default:
            return .json(["error": "not found"], status: 404)
        }
    }

    // MARK: Media

    /// "page/3-5.png" (720×1080 page), "tall/4-2.png" (720×6000 strip), "gthumb/3.png" (cover).
    static func generate(folder: String, name: String) -> Data? {
        let nums = name.split(separator: "-").compactMap { Int($0) }
        guard let n = nums.first, let g = galleries.first(where: { $0.n == n }) else { return nil }
        let color = MockMedia.uiColor(g.tags[0])
        switch folder {
        case "gthumb":
            return draw(size: CGSize(width: 200, height: 280), color: color, title: "G\(n)", subtitle: "\(g.pageCount) p", bands: 1)
        case "page":
            guard nums.count == 2, (1...g.pageCount).contains(nums[1]) else { return nil }
            return draw(size: CGSize(width: 720, height: 1080), color: color, title: "\(nums[1])", subtitle: "Gallery \(n) · page \(nums[1]) of \(g.pageCount)", bands: 1)
        case "tall":
            guard nums.count == 2, (1...g.pageCount).contains(nums[1]) else { return nil }
            return draw(size: CGSize(width: 720, height: 6000), color: color, title: "\(nums[1])", subtitle: "Strip \(n) · part \(nums[1]) of \(g.pageCount)", bands: 10)
        default:
            return nil
        }
    }

    /// Colored panels with a big number in each, so scrolling position is easy to see.
    static func draw(size: CGSize, color: UIColor, title: String, subtitle: String, bands: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let bandH = size.height / CGFloat(bands)
            for b in 0..<bands {
                let rect = CGRect(x: 0, y: CGFloat(b) * bandH, width: size.width, height: bandH)
                UIColor.black.setFill(); cg.fill(rect)
                color.withAlphaComponent(b % 2 == 0 ? 0.65 : 0.4).setFill()
                cg.fill(rect.insetBy(dx: size.width * 0.04, dy: bandH * 0.03))
                let label = (bands > 1 ? "\(title).\(b + 1)" : title) as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: min(size.width, bandH) / 3, weight: .heavy),
                    .foregroundColor: UIColor.white, .strokeColor: UIColor.black, .strokeWidth: -3.0,
                ]
                let ts = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: rect.midY - ts.height / 2), withAttributes: attrs)
                let sub = subtitle as NSString
                let sAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: min(size.width, bandH) / 16, weight: .semibold),
                                                             .foregroundColor: UIColor.white]
                let ss = sub.size(withAttributes: sAttrs)
                sub.draw(at: CGPoint(x: (size.width - ss.width) / 2, y: rect.maxY - ss.height - bandH * 0.08), withAttributes: sAttrs)
            }
        }
        return image.pngData()
    }
}
