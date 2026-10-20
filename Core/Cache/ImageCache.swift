import Foundation
import CryptoKit

/// Two-tier byte cache for remote media: NSCache in memory, files on disk.
/// Disk entries are touched on read so eviction removes the least-recently-used files first.
/// A small index remembers which site each file came from, so one site's cache can be cleared.
actor ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, NSData>()
    private let directory: URL
    private let indexFile: URL
    private var writesSinceTrim = 0
    /// Cache key → site ID.
    private var siteIndex: [String: String] = [:]
    private var indexDirty = false

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("MediaCache", isDirectory: true)
        indexFile = caches.appendingPathComponent("MediaCacheIndex.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.totalCostLimit = 80 * 1024 * 1024
        if let data = try? Data(contentsOf: indexFile),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            siteIndex = decoded
        }
    }

    nonisolated static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent(key) }

    /// `siteID` also tags older entries (cached before sites were tracked) as they're used.
    func data(for url: URL, siteID: String? = nil) -> Data? {
        let key = Self.key(for: url)
        if let s = siteID, siteIndex[key] == nil, FileManager.default.fileExists(atPath: fileURL(key).path) {
            siteIndex[key] = s
            indexDirty = true
        }
        if let d = memory.object(forKey: key as NSString) { return d as Data }
        let file = fileURL(key)
        guard let d = try? Data(contentsOf: file) else { return nil }
        // Touch for LRU.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        memory.setObject(d as NSData, forKey: key as NSString, cost: d.count)
        return d
    }

    func store(_ data: Data, for url: URL, siteID: String? = nil) {
        let key = Self.key(for: url)
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        try? data.write(to: fileURL(key), options: .atomic)
        if let s = siteID, siteIndex[key] != s {
            siteIndex[key] = s
            indexDirty = true
        }
        writesSinceTrim += 1
        if writesSinceTrim >= 25 {
            writesSinceTrim = 0
            trim()
            saveIndex()
        }
    }

    private func saveIndex() {
        guard indexDirty, let data = try? JSONEncoder().encode(siteIndex) else { return }
        try? data.write(to: indexFile, options: .atomic)
        indexDirty = false
    }

    /// File URL of a cached entry (used to hand cached media to AVPlayer/WebKit).
    func cachedFileURL(for url: URL) -> URL? {
        let f = fileURL(Self.key(for: url))
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// Bytes used on disk.
    func diskSize() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Bytes on disk per site ID ("" for media not tied to a site).
    func sizeBySite() -> [String: Int] {
        saveIndex()
        var out: [String: Int] = [:]
        for e in entries() { out[siteIndex[e.url.lastPathComponent] ?? "", default: 0] += e.size }
        return out
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        siteIndex = [:]
        indexDirty = true
        saveIndex()
    }

    /// Deletes only the files that came from one site ("" = files not tagged with a site).
    /// Returns the bytes freed.
    @discardableResult
    func clear(siteID: String) -> Int {
        var freed = 0
        for e in entries() where (siteIndex[e.url.lastPathComponent] ?? "") == siteID {
            try? FileManager.default.removeItem(at: e.url)
            memory.removeObject(forKey: e.url.lastPathComponent as NSString)
            siteIndex[e.url.lastPathComponent] = nil
            freed += e.size
        }
        indexDirty = true
        saveIndex()
        return freed
    }

    /// Deletes least-recently-used files until the cache fits the limit from Settings.
    func trim() {
        let limitMB = UserDefaults.standard.object(forKey: AppSettings.K.cacheLimitMB) as? Int ?? 300
        let limit = limitMB * 1024 * 1024
        expire()
        var files = entries()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        files.sort { $0.date < $1.date }
        for f in files {
            try? FileManager.default.removeItem(at: f.url)
            siteIndex[f.url.lastPathComponent] = nil
            indexDirty = true
            total -= f.size
            if total <= Int(Double(limit) * 0.9) { break }
        }
    }

    /// Deletes files not opened for the number of days chosen in Settings (reading a file
    /// refreshes its date). Returns the bytes freed.
    @discardableResult
    func expire() -> Int {
        let days = UserDefaults.standard.object(forKey: AppSettings.K.cacheExpiryDays) as? Int ?? 0
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var freed = 0
        for f in entries() where f.date < cutoff {
            try? FileManager.default.removeItem(at: f.url)
            siteIndex[f.url.lastPathComponent] = nil
            indexDirty = true
            freed += f.size
        }
        if freed > 0 { saveIndex() }
        return freed
    }

    private func entries() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (u, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
        }
    }
}
