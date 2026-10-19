import Foundation

/// Posts the user has opened (dimmed in grids) and thumbnails revealed while blur is on.
/// Viewed keys persist (capped); revealed ones last for this session only.
final class ViewedStore: ObservableObject {
    static let shared = ViewedStore()
    private let key = "viewedPostKeys"
    private let cap = 5000

    @Published private(set) var viewed: Set<String>
    @Published private(set) var revealed: Set<String> = []
    private var order: [String]

    private init() {
        order = UserDefaults.standard.stringArray(forKey: key) ?? []
        viewed = Set(order)
    }

    func markViewed(_ post: Post) {
        guard !viewed.contains(post.key) else { return }
        viewed.insert(post.key)
        order.append(post.key)
        if order.count > cap {
            let drop = order.prefix(order.count - cap)
            drop.forEach { viewed.remove($0) }
            order.removeFirst(drop.count)
        }
        UserDefaults.standard.set(order, forKey: key)
    }

    func isViewed(_ key: String) -> Bool { viewed.contains(key) }
    func isRevealed(_ key: String) -> Bool { revealed.contains(key) }
    func reveal(_ key: String) { revealed.insert(key) }

    func clearViewed() {
        viewed = []
        order = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Remembers the sort and rating chosen for each site, so they stick across tabs and launches.
enum StickyOptions {
    private static let key = "stickySearchOptions"

    static func load(_ siteID: String) -> (sort: String?, rating: String?) {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        return (all[siteID]?["sort"], all[siteID]?["rating"])
    }

    static func save(_ siteID: String, sort: String?, rating: String?) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        var entry: [String: String] = [:]
        if let s = sort { entry["sort"] = s }
        if let r = rating { entry["rating"] = r }
        all[siteID] = entry
        UserDefaults.standard.set(all, forKey: key)
    }
}
