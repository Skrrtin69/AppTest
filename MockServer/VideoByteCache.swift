import Foundation
import CryptoKit

/// Disk cache for the video bytes that pass through /proxy (VLCKit and the web player).
///
/// Each video is one sparse file plus a list of the byte ranges already on disk. A range
/// request that's already covered is answered from disk, so watching a video again, swiping
/// back to it, looping it or seeking back costs no data. A video that has been watched all
/// the way through is complete, and downloading it then copies the file instead of fetching
/// it again (see DownloadManager).
///
/// Everything runs on one serial queue. The cache holds up to `capBytes`; the videos used
/// longest ago are dropped first. Settings › Clear Cache empties it.
final class VideoByteCache: @unchecked Sendable {
    static let shared = VideoByteCache()

    struct Meta: Codable {
        var url: String
        var total: Int
        var type: String
        /// Sorted, non-overlapping [start, end) ranges on disk.
        var ranges: [[Int]]
        var used: Date
        /// New for every copy of the file, so a writer still holding a dropped copy can't mark
        /// bytes as cached in its replacement. (Missing in entries from before this existed.)
        var gen: String? = UUID().uuidString

        var covered: Int { ranges.reduce(0) { $0 + ($1[1] - $1[0]) } }
        var isComplete: Bool { ranges.count == 1 && ranges[0][0] == 0 && ranges[0][1] >= total }

        /// How many bytes from `offset` on are on disk without a gap.
        func run(from offset: Int) -> Int {
            for r in ranges where r[0] <= offset && offset < r[1] { return r[1] - offset }
            return 0
        }

        mutating func add(_ start: Int, _ end: Int) {
            guard end > start else { return }
            var list = ranges + [[start, end]]
            list.sort { $0[0] < $1[0] }
            var merged: [[Int]] = []
            for r in list {
                if let last = merged.last, r[0] <= last[1] {
                    merged[merged.count - 1][1] = max(last[1], r[1])
                } else {
                    merged.append(r)
                }
            }
            ranges = merged
        }
    }

    /// Most a single cached answer carries; the player asks for the next piece itself.
    static let maxPiece = 4 * 1024 * 1024
    let capBytes = 600 * 1024 * 1024
    private let queue = DispatchQueue(label: "mediadeck.videobytecache")
    private let directory: URL
    /// Only touched on `queue`.
    fileprivate var metas: [String: Meta] = [:]
    private var dirty = Set<String>()
    private var saveScheduled = false

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("VideoBytes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue.async { self.loadIndex() }
    }

    /// Error pages and JSON answers are never cached as video.
    static func isMediaType(_ type: String) -> Bool {
        let t = type.lowercased()
        return !(t.hasPrefix("text/") || t.contains("html") || t.contains("json") || t.contains("xml"))
    }

    static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func dataFile(_ key: String) -> URL { directory.appendingPathComponent(key + ".bin") }
    private func metaFile(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    private func loadIndex() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            let key = f.deletingPathExtension().lastPathComponent
            if let data = try? Data(contentsOf: f), let m = try? JSONDecoder().decode(Meta.self, from: data),
               FileManager.default.fileExists(atPath: dataFile(key).path) {
                metas[key] = m
            } else {
                try? FileManager.default.removeItem(at: f)
                try? FileManager.default.removeItem(at: dataFile(key))
            }
        }
        // Data files whose list of ranges was never saved (the app was closed within two
        // seconds of starting them) can't be used or counted: remove them.
        for f in files where f.pathExtension == "bin" && metas[f.deletingPathExtension().lastPathComponent] == nil {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: Reading

    /// The answer for a /proxy request, when the bytes it asks for are already on disk.
    /// Open-ended ranges ("bytes=N-") get whatever is on disk from N on (up to `maxPiece`),
    /// as a 206 allows; closed ranges are answered only when they're fully covered.
    func response(for url: URL, rangeHeader: String?, typeOverride: String?) -> HTTPResponse? {
        queue.sync {
            let key = Self.key(url)
            guard var m = metas[key], m.total > 0 else { return nil }
            var start = 0, end = m.total - 1
            if let h = rangeHeader?.lowercased(), h.hasPrefix("bytes=") {
                let spec = h.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
                let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { return nil }
                if parts[0].isEmpty, let n = Int(parts[1]) {
                    start = max(0, m.total - n)
                } else if let s = Int(parts[0]) {
                    start = s
                    if let e = Int(parts[1]) {
                        end = min(e, m.total - 1)
                        // A big closed range would be read whole into memory (and copied again
                        // when sent); those still stream from the site.
                        guard end - start + 1 <= Self.maxPiece, m.run(from: start) >= end - start + 1 else { return nil }
                    } else {
                        let have = m.run(from: start)
                        guard have > 0 else { return nil }
                        end = start + min(have, Self.maxPiece) - 1
                    }
                } else { return nil }
            } else {
                // A plain GET wants the whole file: only small complete ones are answered here.
                guard m.isComplete, m.total <= Self.maxPiece else { return nil }
            }
            guard start <= end, start < m.total, m.run(from: start) >= end - start + 1,
                  let body = read(key, from: start, count: end - start + 1) else { return nil }
            m.used = Date()
            metas[key] = m
            markDirty(key)
            var r = HTTPResponse(status: rangeHeader == nil ? 200 : 206, contentType: typeOverride ?? m.type, body: body)
            if rangeHeader != nil { r.headers["Content-Range"] = "bytes \(start)-\(end)/\(m.total)" }
            return r
        }
    }

    private func read(_ key: String, from offset: Int, count: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: dataFile(key)) else { return nil }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: UInt64(offset))
            let d = try h.read(upToCount: count) ?? Data()
            return d.count == count ? d : nil
        } catch { return nil }
    }

    /// The whole video as a file, when every byte has been cached (for instant downloads).
    func completeFile(for url: URL) -> URL? {
        queue.sync {
            let key = Self.key(url)
            guard let m = metas[key], m.isComplete, Self.isMediaType(m.type) else { return nil }
            return dataFile(key)
        }
    }

    // MARK: Writing

    /// Starts recording an answer that begins at byte `start` of a `total`-byte file.
    func writer(for url: URL, start: Int, total: Int, type: String) -> Writer? {
        guard total > 0, total <= 2 * 1024 * 1024 * 1024, Self.isMediaType(type) else { return nil }
        return Writer(cache: self, url: url, key: Self.key(url), start: start, total: total, type: type)
    }

    /// A whole file that came back in one piece (site ignored Range).
    func storeWhole(_ data: Data, url: URL, type: String) {
        guard let w = writer(for: url, start: 0, total: data.count, type: type) else { return }
        w.append(data)
        w.finish()
    }

    final class Writer: @unchecked Sendable {
        let cache: VideoByteCache
        let url: URL
        let key: String
        let total: Int
        let type: String
        private var offset: Int
        private var handle: FileHandle?
        private var opened = false
        private var gen: String?

        init(cache: VideoByteCache, url: URL, key: String, start: Int, total: Int, type: String) {
            self.cache = cache; self.url = url; self.key = key
            self.offset = start; self.total = total; self.type = type
        }

        func append(_ data: Data) {
            cache.queue.async { [self] in
                guard !data.isEmpty else { return }
                if !opened { opened = true; (handle, gen) = cache.open(self) }
                // The entry was dropped (trimmed, cleared or replaced) since this writer opened it.
                guard let h = handle, offset + data.count <= total, cache.metas[key]?.gen == gen else {
                    try? handle?.close(); handle = nil
                    return
                }
                do {
                    try h.seek(toOffset: UInt64(offset))
                    try h.write(contentsOf: data)
                    cache.recorded(key, offset, offset + data.count)
                    offset += data.count
                } catch {
                    try? h.close(); handle = nil
                }
            }
        }

        func finish() {
            cache.queue.async { [self] in
                try? handle?.close()
                handle = nil
                if opened { cache.writerFinished(key) }
                cache.trimIfNeeded(keeping: key)
                cache.scheduleSave()
            }
        }
    }

    /// On the queue. Opens (or creates) the file for a writer; a different size means the
    /// site's file changed, so the old copy goes.
    private func open(_ w: Writer) -> (FileHandle?, String?) {
        if let m = metas[w.key], m.total != w.total { drop(w.key) }
        if metas[w.key] == nil {
            FileManager.default.createFile(atPath: dataFile(w.key).path, contents: nil)
            metas[w.key] = Meta(url: w.url.absoluteString, total: w.total, type: w.type, ranges: [], used: Date())
            markDirty(w.key)
        } else if metas[w.key]?.gen == nil {
            metas[w.key]?.gen = UUID().uuidString
        }
        activeWriters[w.key, default: 0] += 1
        return (try? FileHandle(forWritingTo: dataFile(w.key)), metas[w.key]?.gen)
    }

    /// Entries with a stream still writing into them aren't trimmed.
    private var activeWriters: [String: Int] = [:]

    private func writerFinished(_ key: String) {
        let n = (activeWriters[key] ?? 1) - 1
        activeWriters[key] = n > 0 ? n : nil
    }

    private func recorded(_ key: String, _ start: Int, _ end: Int) {
        guard var m = metas[key] else { return }
        m.add(start, end)
        m.used = Date()
        metas[key] = m
        markDirty(key)
    }

    // MARK: Housekeeping

    private func markDirty(_ key: String) {
        dirty.insert(key)
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            saveScheduled = false
            for key in dirty {
                if let m = metas[key], let data = try? JSONEncoder().encode(m) {
                    try? data.write(to: metaFile(key), options: .atomic)
                }
            }
            dirty = []
        }
    }

    private func drop(_ key: String) {
        metas[key] = nil
        dirty.remove(key)
        try? FileManager.default.removeItem(at: dataFile(key))
        try? FileManager.default.removeItem(at: metaFile(key))
    }

    private func trimIfNeeded(keeping current: String) {
        var total = metas.values.reduce(0) { $0 + $1.covered }
        guard total > capBytes else { return }
        for (key, m) in metas.sorted(by: { $0.value.used < $1.value.used }) where key != current && activeWriters[key] == nil {
            drop(key)
            total -= m.covered
            if total <= Int(Double(capBytes) * 0.85) { break }
        }
    }

    var sizeBytes: Int { queue.sync { metas.values.reduce(0) { $0 + $1.covered } } }

    func clear() {
        queue.sync {
            metas = [:]
            dirty = []
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
