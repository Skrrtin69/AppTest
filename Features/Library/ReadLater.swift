import SwiftUI

/// Posts saved to look at later — lighter than favorites: no collections, no account sync,
/// and "Clear Viewed" removes the ones already opened.
final class ReadLaterStore: ObservableObject {
    static let shared = ReadLaterStore()
    struct Entry: Codable, Identifiable {
        let post: Post
        let added: Date
        var id: String { post.key }
    }

    private let key = "readLater"
    @Published private(set) var all: [Entry] = []

    /// Decoy mode shows nothing.
    var entries: [Entry] { LockManager.shared.decoyActive ? [] : all }
    var keys: Set<String> { Set(entries.map(\.id)) }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Entry].self, from: data) { all = list }
    }

    func contains(_ p: Post) -> Bool { keys.contains(p.key) }

    func toggle(_ p: Post) {
        guard !LockManager.shared.decoyActive else { return }
        if contains(p) {
            remove([p.key])
            ToastCenter.shared.show("Removed from Read Later")
        } else {
            add([p])
            ToastCenter.shared.show("Saved to Read Later", style: .success)
        }
    }

    func add(_ posts: [Post]) {
        guard !LockManager.shared.decoyActive else { return }
        let have = Set(all.map(\.id))
        all.insert(contentsOf: posts.filter { !have.contains($0.key) }.map { Entry(post: $0, added: Date()) }, at: 0)
        persist()
    }

    func remove(_ keys: [String]) {
        guard !LockManager.shared.decoyActive else { return }
        let k = Set(keys)
        all.removeAll { k.contains($0.id) }
        persist()
    }

    /// Removes everything already opened in the viewer. Returns how many.
    @discardableResult
    func clearViewed() -> Int {
        let viewed = all.filter { ViewedStore.shared.isViewed($0.id) }.map(\.id)
        remove(viewed)
        return viewed.count
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }

    // Backup
    func backupJSON() -> Any {
        (try? JSONEncoder().encode(all)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
    }

    func merge(_ json: Any) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return 0 }
        let have = Set(all.map(\.id))
        let new = list.filter { !have.contains($0.id) }
        all.append(contentsOf: new)
        persist()
        return new.count
    }
}

/// Favorites tab › Later.
struct ReadLaterGrid: View {
    @ObservedObject private var store = ReadLaterStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var viewed = ViewedStore.shared
    let onOpen: ([Post], Int) -> Void
    let onAddToCollection: ([Post]) -> Void

    var posts: [Post] { store.entries.map(\.post).filter { !settings.isBlacklisted($0) } }

    var body: some View {
        if posts.isEmpty {
            EmptyStateView(icon: "bookmark", title: "Nothing saved for later",
                           message: "Long-press a thumbnail and choose Read Later, or use ⋯ in the viewer.")
        } else {
            VStack(spacing: 4) {
                HStack {
                    Text("\(posts.count) saved · \(posts.filter { viewed.isViewed($0.key) }.count) viewed")
                        .font(.footnote).foregroundColor(.secondary)
                    Spacer()
                    Button("Clear Viewed") {
                        let n = store.clearViewed()
                        ToastCenter.shared.show(n == 0 ? "Nothing viewed yet" : "Removed \(n) viewed post\(n == 1 ? "" : "s")")
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("clearViewedLater")
                }
                .padding(.horizontal, 12)
                ScrollView {
                    PostGrid(posts: posts, onTap: { onOpen(posts, $0) }, onAddToCollection: onAddToCollection) { EmptyView() }
                }
            }
        }
    }
}
