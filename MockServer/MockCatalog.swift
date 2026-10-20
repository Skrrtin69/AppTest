import Foundation

/// Deterministic synthetic posts shared by both demo sites. Nothing here describes real content:
/// every item is a generated pattern, GIF or test-pattern clip.
struct MockItem {
    let n: Int
    let kind: String         // "png", "gif", "webm", "mp4"
    let width: Int
    let height: Int
    let tags: [String]
    let rating: String
    let score: Int
    let created: String

    var mediaFile: String {
        switch kind {
        case "gif": return "gif/\(n % 2 == 0 ? 2 : 1).gif"
        case "webm":
            // (n/10) % 3: 0 → a clip that also exists as MP4, 1 → VP8 WebM only, 2 → VP9 WebM only.
            switch (n / 10) % 3 {
            case 0: return "video/clip4.webm"
            case 1: return "video/clip1.webm"
            default: return "video/clip2.webm"
            }
        case "mp4": return "video/clip3.mp4"
        default: return "img/\(n).png"
        }
    }
    var thumbFile: String {
        switch kind {
        case "gif": return mediaFile          // animated thumbnails in the grid
        case "webm", "mp4": return "vthumb/\(n).png"
        default: return "thumb/\(n).png"
        }
    }
    /// MP4 version of the same video, when one exists (demo for "prefer MP4").
    var mp4Alternate: String? { kind == "webm" && (n / 10) % 3 == 0 ? "video/clip4.mp4" : nil }

    var sampleFile: String { kind == "png" ? "sample/\(n).png" : mediaFile }
}

enum MockCatalog {
    static let count = 60
    static let pageSize = 20
    static let uploaders = ["demo_uploader_ana", "demo_uploader_bo", "demo_uploader_cy", "demo_uploader_dee"]

    static let colors = ["red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"]
    static let patterns = ["circles", "stripes", "grid", "waves", "dots", "gradient"]

    static let items: [MockItem] = (1...count).map(make)

    static func make(_ n: Int) -> MockItem {
        let kind: String
        switch n % 10 {
        case 0: kind = "webm"
        case 5: kind = "mp4"
        case 3, 7: kind = "gif"
        default: kind = "png"
        }
        let (w, h): (Int, Int)
        switch n % 3 {
        case 0: (w, h) = (1600, 1000)
        case 1: (w, h) = (900, 1400)
        default: (w, h) = (1200, 1200)
        }
        let orientation = w > h ? "landscape" : (w < h ? "portrait" : "square")
        var tags = [colors[n % colors.count], patterns[(n / 2) % patterns.count], orientation]
        switch kind {
        case "gif": tags.append("animated")
        case "webm", "mp4": tags += ["video", kind]
        default: tags.append("still")
        }
        if n % 4 == 0 { tags.append("featured") }
        // A multi-word tag written with "_" (for the tagSpaceReplacement demo).
        if colors[n % colors.count] == "blue" { tags.append("deep_blue") }
        let day = 1 + (count - n) % 28
        return MockItem(n: n, kind: kind,
                        width: kind == "png" ? w : (kind == "gif" ? 200 : 320),
                        height: kind == "png" ? h : (kind == "gif" ? 200 : 240),
                        tags: tags.sorted(), rating: n % 6 == 0 ? "sensitive" : "general",
                        score: (n * 37) % 100, created: String(format: "2026-01-%02dT12:00:00Z", day))
    }

    /// Every distinct tag with its post count, for autocomplete.
    static let tagCounts: [(tag: String, count: Int)] = {
        var c: [String: Int] = [:]
        for i in items { for t in i.tags { c[t, default: 0] += 1 } }
        return c.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }()

    static func suggestions(_ prefix: String) -> [(tag: String, count: Int)] {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return [] }
        return tagCounts.filter { $0.tag.hasPrefix(p) || $0.tag.contains("_" + p) }.prefix(10).map { $0 }
    }

    /// Applies tag include/exclude, rating and sort.
    static func search(tagQuery: String, sort: String?, rating: String?) -> [MockItem] {
        let words = tagQuery.replacingOccurrences(of: "+", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).lowercased() }
        // "rotating": a demo search whose results change every minute (for testing
        // "Watch for new posts" on saved searches).
        if words == ["rotating"] {
            let minute = Calendar.current.component(.minute, from: Date())
            return items.filter { ($0.n + minute) % 5 == 0 }.sorted { $0.n > $1.n }
        }
        let include = words.filter { !$0.hasPrefix("-") }
        let exclude = words.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) }
        var result = items.filter { item in
            include.allSatisfy { item.tags.contains($0) } && !exclude.contains { item.tags.contains($0) }
        }
        if let r = rating?.nonEmpty, r != "any" {
            result = result.filter { $0.rating == r }
        }
        switch sort ?? "" {
        case "oldest": result.sort { $0.n < $1.n }
        case "score": result.sort { $0.score > $1.score }
        case "random":
            var rng = SeededRNG(seed: 42)
            result.shuffle(using: &rng)
        default: result.sort { $0.n > $1.n }     // newest first
        }
        return result
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
