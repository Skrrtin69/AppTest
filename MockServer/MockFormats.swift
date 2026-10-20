import UIKit

/// Demo site U: one post per awkward format — frame-by-frame ZIP animations (timed by the
/// site's JSON, or by an animation.json inside), animated WebP and APNG, an HLS stream,
/// UPPERCASE file endings, an empty file and a web page where a picture should be.
enum MockFormats {
    struct Item {
        let id: String
        let title: String
        let file: String          // under /u/files/ unless it starts with "/"
        let ext: String
        let tags: [String]
        var frames: [[String: Any]]? = nil
    }

    static let ugoiraDelays = [80, 80, 80, 80, 400, 80, 80, 400]

    static let items: [Item] = [
        Item(id: "u1", title: "ZIP animation (timed by the site)", file: "ugoira1.zip", ext: "zip", tags: ["zip", "animated"],
             frames: ugoiraDelays.enumerated().map { ["file": String(format: "%06d.png", $0.offset), "delay": $0.element] }),
        Item(id: "u2", title: "ZIP animation (animation.json inside)", file: "UGOIRA2.ZIP", ext: "ZIP", tags: ["zip", "animated", "uppercase"]),
        Item(id: "u3", title: "Animated WebP", file: "anim1.webp", ext: "webp", tags: ["webp", "animated"]),
        Item(id: "u4", title: "Animated PNG", file: "anim2.png", ext: "png", tags: ["apng", "animated"]),
        Item(id: "u5", title: "HLS stream", file: "/player/hls/demo.m3u8", ext: "m3u8", tags: ["stream", "video"]),
        Item(id: "u6", title: "Video with an UPPERCASE ending", file: "CLIP.MP4", ext: "MP4", tags: ["video", "uppercase"]),
        Item(id: "u7", title: "Picture with an UPPERCASE ending", file: "PHOTO.PNG", ext: "PNG", tags: ["still", "uppercase"]),
        Item(id: "u8", title: "Empty file", file: "empty.png", ext: "png", tags: ["broken", "empty"]),
        Item(id: "u9", title: "Web page instead of a picture", file: "blocked.png", ext: "png", tags: ["broken", "html"]),
    ]

    private static var cache: [String: Data] = [:]
    private static let lock = NSLock()

    static func respond(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        if sub == "/posts.json" {
            let want = (req.query["tags"] ?? "").replacingOccurrences(of: "+", with: " ")
                .split(separator: " ").map { $0.lowercased() }
            let page = Int(req.query["page"] ?? "1") ?? 1
            let list = page > 1 ? [] : items.filter { i in want.allSatisfy { i.tags.contains($0) } }
            return .json(["posts": list.map { i -> [String: Any] in
                var d: [String: Any] = [
                    "id": i.id, "title": i.title, "tags": i.tags, "file_ext": i.ext,
                    "preview_url": "\(origin)/u/files/prev-\(i.id).png",
                    "file_url": i.file.hasPrefix("/") ? origin + i.file : "\(origin)/u/files/\(i.file)",
                ]
                // Always present (empty when there are none), like real APIs that keep the shape.
                d["frames"] = i.frames ?? []
                return d
            }])
        }
        if sub.hasPrefix("/files/") {
            let name = String(sub.dropFirst("/files/".count))
            switch name {
            case "empty.png":
                return HTTPResponse(contentType: "image/png", body: Data())
            case "blocked.png":
                return .text("<!doctype html><html><head><title>Please log in</title></head><body><h1>Log in to see this picture</h1></body></html>",
                             type: "text/html; charset=utf-8")
            default:
                guard let d = file(name) else { return .json(["error": "no such file"], status: 404) }
                return HTTPResponse(contentType: contentType(name), body: d)
            }
        }
        return .json(["error": "not found"], status: 404)
    }

    static func contentType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "zip": return "application/zip"
        case "webp": return "image/webp"
        case "png": return "image/png"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func file(_ name: String) -> Data? {
        lock.lock(); if let d = cache[name] { lock.unlock(); return d }; lock.unlock()
        var data: Data?
        switch name {
        case "ugoira1.zip": data = zip(frames: ugoiraDelays.count, json: nil, color: .systemPink)
        case "UGOIRA2.ZIP":
            let json: [String: Any] = ["frames": (0..<6).map { ["file": String(format: "%06d.png", $0), "delay": 150] }]
            data = zip(frames: 6, json: json, color: .systemTeal)
        case "anim1.webp": data = bundle("anim1", "webp")
        case "anim2.png": data = bundle("anim2", "png")
        case "CLIP.MP4": data = bundle("clip3", "mp4")
        case "PHOTO.PNG":
            data = MockGallery.draw(size: CGSize(width: 900, height: 600), color: .systemIndigo, title: "PNG", subtitle: "File ending in capitals: .PNG", bands: 1)
        default:
            if name.hasPrefix("prev-"), let item = items.first(where: { "prev-\($0.id).png" == name }) {
                data = MockGallery.draw(size: CGSize(width: 300, height: 300), color: .systemGray, title: item.id.uppercased(),
                                        subtitle: item.tags.first ?? "", bands: 1)
            }
        }
        if let d = data { lock.lock(); cache[name] = d; lock.unlock() }
        return data
    }

    private static func bundle(_ name: String, _ ext: String) -> Data? {
        Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? Data(contentsOf: $0) }
    }

    /// A stored ZIP of numbered PNG frames (a dot moving across), optionally with animation.json.
    private static func zip(frames: Int, json: [String: Any]?, color: UIColor) -> Data? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mock-zip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var entries: [ZipWriter.Entry] = []
        let size = CGSize(width: 320, height: 240)
        for i in 0..<frames {
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
            let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                color.setFill()
                let x = 20 + CGFloat(i) * (size.width - 80) / CGFloat(max(frames - 1, 1))
                ctx.cgContext.fillEllipse(in: CGRect(x: x, y: 90, width: 60, height: 60))
                ("\(i + 1)/\(frames)" as NSString).draw(at: CGPoint(x: 12, y: 10), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 28), .foregroundColor: UIColor.white])
            }
            let url = dir.appendingPathComponent(String(format: "%06d.png", i))
            try? img.pngData()?.write(to: url)
            entries.append(ZipWriter.Entry(name: url.lastPathComponent, url: url))
        }
        if let j = json, let d = try? JSONSerialization.data(withJSONObject: j) {
            let url = dir.appendingPathComponent("animation.json")
            try? d.write(to: url)
            entries.append(ZipWriter.Entry(name: "animation.json", url: url))
        }
        let out = dir.appendingPathComponent("out.zip")
        guard (try? ZipWriter.write(entries, to: out)) != nil else { return nil }
        return try? Data(contentsOf: out)
    }
}
