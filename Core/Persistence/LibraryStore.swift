import CoreData
import SwiftUI

struct FavoriteItem: Identifiable, Hashable {
    let key: String
    let post: Post
    let createdAt: Date
    let collectionIDs: Set<String>
    var id: String { key }
}

struct CollectionItem: Identifiable, Hashable {
    let id: String
    let name: String
    let keys: [String]
}

struct HistoryItem: Identifiable, Hashable {
    let id: NSManagedObjectID
    let query: String
    let siteID: String
    let date: Date
}

struct SavedSearchItem: Identifiable, Hashable {
    let id: String
    let name: String
    let query: String
    let siteID: String
}

/// Favorites, collections, search history and saved searches (Core Data),
/// exposed to SwiftUI as plain value arrays.
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var favorites: [FavoriteItem] = []
    @Published private(set) var collections: [CollectionItem] = []
    @Published private(set) var history: [HistoryItem] = []
    @Published private(set) var savedSearches: [SavedSearchItem] = []
    @Published private(set) var favoriteKeys: Set<String> = []

    private let stack = CoreDataStack.shared
    private var ctx: NSManagedObjectContext { stack.context }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() { reload() }

    func reload() {
        let favReq = NSFetchRequest<FavoriteMO>(entityName: "Favorite")
        favReq.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        let favs = (try? ctx.fetch(favReq)) ?? []
        favorites = favs.compactMap { mo in
            guard let post = try? decoder.decode(Post.self, from: mo.postData) else { return nil }
            return FavoriteItem(key: mo.key, post: post, createdAt: mo.createdAt, collectionIDs: Set(mo.collections.map { $0.id }))
        }
        favoriteKeys = Set(favorites.map { $0.key })

        let colReq = NSFetchRequest<CollectionMO>(entityName: "Collection")
        colReq.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        collections = ((try? ctx.fetch(colReq)) ?? []).map { c in
            CollectionItem(id: c.id, name: c.name, keys: c.favorites.sorted { $0.createdAt > $1.createdAt }.map { $0.key })
        }

        let hReq = NSFetchRequest<HistoryMO>(entityName: "History")
        hReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        hReq.fetchLimit = 100
        history = ((try? ctx.fetch(hReq)) ?? []).map { HistoryItem(id: $0.objectID, query: $0.query, siteID: $0.siteID, date: $0.date) }

        let sReq = NSFetchRequest<SavedSearchMO>(entityName: "SavedSearch")
        sReq.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        savedSearches = ((try? ctx.fetch(sReq)) ?? []).map { SavedSearchItem(id: $0.id, name: $0.name, query: $0.query, siteID: $0.siteID) }
    }

    private func commit() {
        stack.save()
        reload()
    }

    // MARK: Favorites

    func isFavorite(_ post: Post) -> Bool { favoriteKeys.contains(post.key) }

    private func favoriteMO(_ key: String) -> FavoriteMO? {
        let r = NSFetchRequest<FavoriteMO>(entityName: "Favorite")
        r.predicate = NSPredicate(format: "key == %@", key)
        r.fetchLimit = 1
        return try? ctx.fetch(r).first
    }

    @discardableResult
    private func ensureFavorite(_ post: Post) -> FavoriteMO {
        if let mo = favoriteMO(post.key) { return mo }
        let mo = FavoriteMO(context: ctx)
        mo.key = post.key
        mo.siteID = post.siteID
        mo.postData = (try? encoder.encode(post)) ?? Data()
        mo.createdAt = Date()
        return mo
    }

    func toggleFavorite(_ post: Post) {
        if let mo = favoriteMO(post.key) {
            let collectionIDs = mo.collections.map { $0.id }
            ctx.delete(mo)
            ToastCenter.shared.show("Removed from favorites", actionTitle: "Undo") { [weak self] in
                guard let self = self else { return }
                let f = self.ensureFavorite(post)
                for id in collectionIDs { if let c = self.collectionMO(id) { f.collections.insert(c) } }
                self.commit()
                Task { await FavoriteSync.shared.push(post, add: true) }
            }
            Task { await FavoriteSync.shared.push(post, add: false) }
        } else {
            ensureFavorite(post)
            ToastCenter.shared.show("Added to favorites", style: .success)
            Task { await FavoriteSync.shared.push(post, add: true) }
        }
        commit()
    }

    func addFavorites(_ posts: [Post]) {
        posts.forEach { ensureFavorite($0) }
        commit()
    }

    func removeFavorites(keys: [String]) {
        keys.compactMap { favoriteMO($0) }.forEach { ctx.delete($0) }
        commit()
    }

    // MARK: Collections

    private func collectionMO(_ id: String) -> CollectionMO? {
        let r = NSFetchRequest<CollectionMO>(entityName: "Collection")
        r.predicate = NSPredicate(format: "id == %@", id)
        r.fetchLimit = 1
        return try? ctx.fetch(r).first
    }

    @discardableResult
    func createCollection(named name: String) -> String? {
        guard let n = name.nonEmpty else { return nil }
        let c = CollectionMO(context: ctx)
        c.id = UUID().uuidString
        c.name = n
        c.createdAt = Date()
        commit()
        return c.id
    }

    func renameCollection(_ id: String, to name: String) {
        guard let c = collectionMO(id), let n = name.nonEmpty else { return }
        c.name = n
        commit()
    }

    func deleteCollection(_ id: String) {
        if let c = collectionMO(id) { ctx.delete(c) }
        commit()
    }

    /// Adding to a collection also favorites the post.
    func add(_ posts: [Post], toCollection id: String) {
        guard let c = collectionMO(id) else { return }
        for p in posts {
            let f = ensureFavorite(p)
            f.collections.insert(c)
        }
        commit()
        ToastCenter.shared.show("Added \(posts.count) to \(c.name)", style: .success)
    }

    func remove(_ keys: [String], fromCollection id: String) {
        guard let c = collectionMO(id) else { return }
        for k in keys { if let f = favoriteMO(k) { f.collections.remove(c) } }
        commit()
    }

    func posts(inCollection id: String) -> [Post] {
        guard let c = collections.first(where: { $0.id == id }) else { return [] }
        let byKey = Dictionary(uniqueKeysWithValues: favorites.map { ($0.key, $0.post) })
        return c.keys.compactMap { byKey[$0] }
    }

    // MARK: History & saved searches

    func recordSearch(_ query: String, siteID: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        // Re-running a search moves it to the top instead of duplicating it.
        let r = NSFetchRequest<HistoryMO>(entityName: "History")
        r.predicate = NSPredicate(format: "query == %@ AND siteID == %@", q, siteID)
        ((try? ctx.fetch(r)) ?? []).forEach { ctx.delete($0) }
        let h = HistoryMO(context: ctx)
        h.query = q
        h.siteID = siteID
        h.date = Date()
        commit()
    }

    func deleteHistory(_ item: HistoryItem) {
        if let mo = try? ctx.existingObject(with: item.id) { ctx.delete(mo) }
        commit()
    }

    func clearHistory() {
        let r = NSFetchRequest<HistoryMO>(entityName: "History")
        ((try? ctx.fetch(r)) ?? []).forEach { ctx.delete($0) }
        commit()
    }

    func saveSearch(name: String, query: String, siteID: String) {
        let s = SavedSearchMO(context: ctx)
        s.id = UUID().uuidString
        s.name = name.nonEmpty ?? (query.nonEmpty ?? "All posts")
        s.query = query
        s.siteID = siteID
        s.createdAt = Date()
        commit()
        ToastCenter.shared.show("Search saved", style: .success)
    }

    func deleteSavedSearch(_ id: String) {
        let r = NSFetchRequest<SavedSearchMO>(entityName: "SavedSearch")
        r.predicate = NSPredicate(format: "id == %@", id)
        ((try? ctx.fetch(r)) ?? []).forEach { ctx.delete($0) }
        commit()
    }
}
