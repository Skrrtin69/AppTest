import Foundation
import UIKit

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
        // Leaving the app with the viewer open: save what was opened so far, in case iOS
        // or the app switcher ends the app before the viewer closes.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.flush()
        }
    }

    /// Posts opened while the viewer is up. Every grid cell watches `viewed`, so changing it
    /// on each swipe redrew every grid behind the viewer (and rewrote the whole list to disk).
    /// They're added in one go when the viewer closes.
    private var pending: [String] = []
    var holdChanges = false {
        didSet { if !holdChanges { flush() } }
    }

    func markViewed(_ post: Post) {
        guard !isViewed(post.key) else { return }
        if holdChanges {
            pending.append(post.key)
            return
        }
        add([post.key])
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let keys = pending
        pending = []
        add(keys)
    }

    private func add(_ keys: [String]) {
        var set = viewed
        for k in keys where !set.contains(k) {
            set.insert(k)
            order.append(k)
        }
        if order.count > cap {
            let drop = order.prefix(order.count - cap)
            drop.forEach { set.remove($0) }
            order.removeFirst(drop.count)
        }
        viewed = set
        UserDefaults.standard.set(order, forKey: key)
    }

    func isViewed(_ key: String) -> Bool { viewed.contains(key) || pending.contains(key) }
    func isRevealed(_ key: String) -> Bool { revealed.contains(key) }
    func reveal(_ key: String) { revealed.insert(key) }

    func clearViewed() {
        pending = []
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
