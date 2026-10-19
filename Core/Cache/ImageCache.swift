import Foundation
import CryptoKit

/// Two-tier byte cache for remote media: NSCache in memory, files on disk.
/// Disk entries are touched on read so eviction removes the least-recently-used files first.
actor ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, NSData>()
    private let directory: URL
    private var writesSinceTrim = 0

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("MediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.totalCostLimit = 80 * 1024 * 1024
    }

    nonisolated static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent(key) }

    func data(for url: URL) -> Data? {
        let key = Self.key(for: url)
        if let d = memory.object(forKey: key as NSString) { return d as Data }
        let file = fileURL(key)
        guard let d = try? Data(contentsOf: file) else { return nil }
        // Touch for LRU.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        memory.setObject(d as NSData, forKey: key as NSString, cost: d.count)
        return d
    }

    func store(_ data: Data, for url: URL) {
        let key = Self.key(for: url)
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        try? data.write(to: fileURL(key), options: .atomic)
        writesSinceTrim += 1
        if writesSinceTrim >= 25 {
            writesSinceTrim = 0
            trim()
        }
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

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Deletes least-recently-used files until the cache fits the limit from Settings.
    func trim() {
        let limitMB = UserDefaults.standard.object(forKey: AppSettings.K.cacheLimitMB) as? Int ?? 300
        let limit = limitMB * 1024 * 1024
        var files = entries()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        files.sort { $0.date < $1.date }
        for f in files {
            try? FileManager.default.removeItem(at: f.url)
            total -= f.size
            if total <= Int(Double(limit) * 0.9) { break }
        }
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
