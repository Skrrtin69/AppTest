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
        case "webm": return "video/clip\(n % 20 == 0 ? 2 : 1).webm"
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
    var sampleFile: String { kind == "png" ? "sample/\(n).png" : mediaFile }
}

enum MockCatalog {
    static let count = 60
    static let pageSize = 20

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
        let day = 1 + (count - n) % 28
        return MockItem(n: n, kind: kind,
                        width: kind == "png" ? w : (kind == "gif" ? 200 : 320),
                        height: kind == "png" ? h : (kind == "gif" ? 200 : 240),
                        tags: tags.sorted(), rating: n % 6 == 0 ? "sensitive" : "general",
                        score: (n * 37) % 100, created: String(format: "2026-01-%02dT12:00:00Z", day))
    }

    /// Applies tag include/exclude, rating and sort.
    static func search(tagQuery: String, sort: String?, rating: String?) -> [MockItem] {
        let words = tagQuery.replacingOccurrences(of: "+", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).lowercased() }
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
