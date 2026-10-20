import UIKit
import ImageIO
import MobileCoreServices

/// Generates demo images and GIFs on demand (cached in memory) and serves the bundled clips.
enum MockMedia {
    private static let cache = NSCache<NSString, NSData>()
    private static let lock = NSLock()

    static func serve(_ path: String) -> HTTPResponse {
        let clean = path.split(separator: "?").first.map(String.init) ?? path
        if let cached = cache.object(forKey: clean as NSString) {
            return HTTPResponse(contentType: contentType(clean), body: cached as Data)
        }
        guard let data = generate(clean) else {
            return .json(["error": "no such media", "path": clean], status: 404)
        }
        cache.setObject(data as NSData, forKey: clean as NSString)
        return HTTPResponse(contentType: contentType(clean), body: data)
    }

    static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webm": return "video/webm"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func generate(_ path: String) -> Data? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let folder = parts[0]
        let file = parts[1]
        let name = (file as NSString).deletingPathExtension
        switch folder {
        case "video":
            guard let url = Bundle.main.url(forResource: name, withExtension: (file as NSString).pathExtension) else { return nil }
            return try? Data(contentsOf: url)
        case "gif":
            return makeGIF(variant: Int(name) ?? 1)
        case "page", "tall", "gthumb":
            return MockGallery.generate(folder: folder, name: name)
        case "img", "sample", "thumb", "vthumb":
            guard let n = Int(name), (1...MockCatalog.count).contains(n) else { return nil }
            let item = MockCatalog.items[n - 1]
            let full = CGSize(width: item.kind == "png" ? item.width : 320, height: item.kind == "png" ? item.height : 240)
            let scale: CGFloat
            switch folder {
            case "img": scale = 1
            case "sample": scale = 0.5
            default: scale = 280 / max(full.width, full.height)
            }
            let size = CGSize(width: (full.width * scale).rounded(), height: (full.height * scale).rounded())
            let png = drawPattern(item: item, size: size, videoBadge: folder == "vthumb")
            // Every third full-size picture carries made-up camera details (EXIF demo).
            if folder == "img", item.kind == "png", n % 3 == 0, let p = png { return withDemoEXIF(p, n: n) ?? png }
            return png
        default:
            return nil
        }
    }

    static func uiColor(_ name: String) -> UIColor {
        switch name {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "pink": return .systemPink
        default: return .systemGray
        }
    }

    /// Draws a colored pattern with a big label so each post is visually distinct.
    static func drawPattern(item: MockItem, size: CGSize, videoBadge: Bool) -> Data? {
        let color = uiColor(item.tags.first { MockCatalog.colors.contains($0) } ?? "gray")
        let pattern = item.tags.first { MockCatalog.patterns.contains($0) } ?? "grid"
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            color.withAlphaComponent(0.35).setFill()
            UIColor.black.setFill(); cg.fill(rect)
            color.withAlphaComponent(0.55).setFill(); cg.fill(rect)
            color.setFill(); color.setStroke()
            let unit = max(size.width, size.height) / 12
            cg.setLineWidth(unit / 4)
            switch pattern {
            case "circles":
                for i in 1...6 {
                    let r = CGFloat(i) * unit
                    cg.strokeEllipse(in: CGRect(x: size.width / 2 - r, y: size.height / 2 - r, width: r * 2, height: r * 2))
                }
            case "stripes":
                var x: CGFloat = -size.height
                while x < size.width {
                    cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    x += unit
                }
                cg.strokePath()
            case "waves":
                var y: CGFloat = unit / 2
                while y < size.height {
                    cg.move(to: CGPoint(x: 0, y: y))
                    var x: CGFloat = 0
                    while x <= size.width {
                        cg.addLine(to: CGPoint(x: x, y: y + sin(x / unit * .pi) * unit / 3))
                        x += 4
                    }
                    y += unit
                }
                cg.strokePath()
            case "dots":
                var y: CGFloat = unit / 2
                while y < size.height {
                    var x: CGFloat = unit / 2
                    while x < size.width {
                        cg.fillEllipse(in: CGRect(x: x - unit / 4, y: y - unit / 4, width: unit / 2, height: unit / 2))
                        x += unit
                    }
                    y += unit
                }
            case "gradient":
                let colors = [color.cgColor, UIColor.black.cgColor] as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                }
            default: // grid
                var x: CGFloat = 0
                while x < size.width { cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height)); x += unit }
                var y: CGFloat = 0
                while y < size.height { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y)); y += unit }
                cg.strokePath()
            }
            // Label
            let label = "#\(item.n)" as NSString
            let fontSize = min(size.width, size.height) / 4
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: -3.0,
            ]
            let ts = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2), withAttributes: attrs)
            if videoBadge {
                let r = min(size.width, size.height) / 5
                let c = CGPoint(x: size.width - r * 1.3, y: size.height - r * 1.3)
                UIColor.black.withAlphaComponent(0.6).setFill()
                cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                UIColor.white.setFill()
                cg.move(to: CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.5))
                cg.addLine(to: CGPoint(x: c.x + r * 0.55, y: c.y))
                cg.addLine(to: CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.5))
                cg.closePath(); cg.fillPath()
            }
        }
        return image.pngData()
    }

    /// Re-encodes a picture as JPEG with synthetic EXIF/TIFF data (and, for some, a made-up
    /// location) so the Info panel's photo details can be shown.
    static func withDemoEXIF(_ data: Data, n: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "MediaDeck",
                kCGImagePropertyTIFFModel: "Demo Camera \(n % 4 + 1)",
                kCGImagePropertyTIFFSoftware: "MediaDeck demo server",
                kCGImagePropertyTIFFArtist: "demo_uploader_\(n % 4)",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 1.0 / Double([60, 125, 250, 500][n % 4]),
                kCGImagePropertyExifFNumber: [1.8, 2.8, 4.0, 5.6][n % 4],
                kCGImagePropertyExifISOSpeedRatings: [[100, 200, 400, 800][n % 4]],
                kCGImagePropertyExifFocalLength: [24.0, 35.0, 50.0, 85.0][n % 4],
                kCGImagePropertyExifLensModel: "Demo Lens \([24, 35, 50, 85][n % 4]) mm",
                kCGImagePropertyExifDateTimeOriginal: String(format: "2026:0%d:1%d 12:%02d:00", n % 9 + 1, n % 10, n % 60),
            ],
        ]
        if n % 6 == 0 {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 12.3456, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 65.4321, kCGImagePropertyGPSLongitudeRef: "E",
            ]
        }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Looping animated GIF: variant 1 = orbiting dot, variant 2 = color-cycling bars.
    static func makeGIF(variant: Int) -> Data? {
        let frames = 16
        let size = CGSize(width: 200, height: 200)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, kUTTypeGIF, frames, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        for f in 0..<frames {
            let t = CGFloat(f) / CGFloat(frames)
            let img = renderer.image { ctx in
                let cg = ctx.cgContext
                UIColor(white: 0.1, alpha: 1).setFill(); cg.fill(CGRect(origin: .zero, size: size))
                if variant == 2 {
                    for i in 0..<5 {
                        let hue = (t + CGFloat(i) * 0.2).truncatingRemainder(dividingBy: 1)
                        UIColor(hue: hue, saturation: 0.8, brightness: 1, alpha: 1).setFill()
                        let h = 40 + 120 * abs(sin((t + CGFloat(i) * 0.15) * .pi * 2))
                        cg.fill(CGRect(x: 15 + CGFloat(i) * 36, y: 190 - h, width: 28, height: h))
                    }
                } else {
                    let a = t * .pi * 2
                    UIColor.systemTeal.setFill()
                    cg.fillEllipse(in: CGRect(x: 100 + cos(a) * 60 - 22, y: 100 + sin(a) * 60 - 22, width: 44, height: 44))
                    UIColor.white.setStroke(); cg.setLineWidth(3)
                    cg.strokeEllipse(in: CGRect(x: 40, y: 40, width: 120, height: 120))
                }
                let label = "GIF \(variant)" as NSString
                label.draw(at: CGPoint(x: 8, y: 6), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18), .foregroundColor: UIColor.white])
            }
            guard let cgImage = img.cgImage else { continue }
            CGImageDestinationAddImage(dest, cgImage, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
