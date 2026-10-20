import Foundation
import Compression

/// Minimal in-memory ZIP reader (stored and deflate entries), enough for frame-by-frame
/// animation archives. Reads the central directory, so entry sizes are always known.
enum ZipReader {
    struct Entry {
        let name: String
        let data: Data
    }

    static func isZip(_ data: Data) -> Bool {
        data.count > 4 && data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    static func entries(_ data: Data, limit: Int = 2_000) throws -> [Entry] {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 1 < bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 3 < bytes.count ? u16(o) | u16(o + 2) << 16 : 0 }

        // End of central directory: signature 0x06054b50, searched from the end.
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 66_000) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw AppError.message("This archive is damaged (no table of contents).") }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [Entry] = []
        for _ in 0..<min(count, limit) {
            guard u32(p) == 0x02014b50 else { throw AppError.message("This archive is damaged.") }
            let method = u16(p + 10)
            let compressed = u32(p + 20)
            let size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: bytes[(p + 46)..<min(bytes.count, p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            // The local header has its own (possibly different) name/extra lengths.
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard !name.hasSuffix("/"), start >= 0, start + compressed <= bytes.count else { continue }
            let raw = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0: out.append(Entry(name: name, data: raw))
            case 8:
                if let d = inflate(raw, expected: size) { out.append(Entry(name: name, data: d)) }
            default: continue
            }
        }
        return out
    }

    /// Raw DEFLATE (what ZIP uses) via the Compression framework.
    static func inflate(_ data: Data, expected: Int) -> Data? {
        guard expected > 0, expected < 200_000_000 else { return expected == 0 ? Data() : nil }
        var out = Data(count: expected)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == expected ? out : nil
    }
}

/// Frame timings for ZIP animations, from the site's JSON (adapter zipFramesPath), registered
/// when results are mapped and read when the archive is decoded.
enum ZipFrames {
    private static var byURL: [String: [String: Double]] = [:]
    private static let lock = NSLock()

    static func register(_ url: URL, delays: [String: Double]) {
        lock.lock(); byURL[url.absoluteString] = delays; lock.unlock()
    }

    static func delays(for url: URL) -> [String: Double]? {
        lock.lock(); defer { lock.unlock() }
        return byURL[url.absoluteString]
    }

    /// file → delay (seconds) from a list like [{"file": "000.jpg", "delay": 80}] (delay in ms).
    static func parse(_ json: Any?) -> [String: Double] {
        var out: [String: Double] = [:]
        for f in json as? [[String: Any]] ?? [] {
            guard let file = (f["file"] ?? f["name"]) as? String else { continue }
            let ms = (f["delay"] ?? f["duration"] ?? f["ms"]).flatMap { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") }
            if let ms = ms { out[file] = ms / 1000 }
        }
        return out
    }
}
