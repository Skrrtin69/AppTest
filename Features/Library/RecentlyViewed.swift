import SwiftUI

/// The last posts opened in the viewer, newest first, so a post you swiped past or closed
/// by accident can be found again (Favorites › Recent). Kept on this phone only, capped at
/// `cap`; decoy mode neither records nor shows anything. "Forget which posts I've opened"
/// in Settings clears it along with the dimming.
@MainActor
final class RecentlyViewedStore: ObservableObject {
    static let shared = RecentlyViewedStore()
    struct Entry: Codable, Identifiable {
        let post: Post
        var viewed: Date
        var id: String { post.key }
    }

    private let key = "recentlyViewedPosts"
    private let cap = 400
    @Published private(set) var all: [Entry] = []
    private var saveTask: Task<Void, Never>?

    var entries: [Entry] { LockManager.shared.decoyActive ? [] : all }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Entry].self, from: data) { all = list }
    }

    func record(_ post: Post) {
        guard !LockManager.shared.decoyActive else { return }
        // Already on top: nothing changes (no redraw while paging back and forth).
        if all.first?.id == post.key { return }
        all.removeAll { $0.id == post.key }
        all.insert(Entry(post: post, viewed: Date()), at: 0)
        if all.count > cap { all.removeLast(all.count - cap) }
        scheduleSave()
    }

    func remove(_ keys: Set<String>) {
        guard !LockManager.shared.decoyActive else { return }
        all.removeAll { keys.contains($0.id) }
        scheduleSave()
    }

    func clear() {
        all = []
        saveTask?.cancel()
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Paging through a gallery records a post per swipe; write once things settle.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self = self else { return }
            let snapshot = self.all
            let key = self.key
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: key) }
            }
        }
    }
}

/// Favorites tab › Recent.
struct RecentlyViewedGrid: View {
    @ObservedObject private var store = RecentlyViewedStore.shared
    @ObservedObject private var settings = AppSettings.shared
    let onOpen: ([Post], Int) -> Void
    let onAddToCollection: ([Post]) -> Void
    @State private var confirmClear = false
    /// Only videos stopped partway (they continue where you left off).
    @State private var unfinishedOnly = false
    /// Bumped when a video's saved spot appears or goes, so the filter's list is current.
    @State private var resumeTick = 0

    var posts: [Post] { store.entries.map(\.post).filter { !settings.isBlacklisted($0) } }

    static func isUnfinished(_ p: Post) -> Bool {
        p.mediaType == .video && VideoResumeStore.shared.fraction(for: p.mediaURL) != nil
    }

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: VideoResumeStore.changed)) { _ in resumeTick += 1 }
    }

    @ViewBuilder var content: some View {
        let _ = resumeTick
        let all = posts
        let unfinishedCount = all.filter(Self.isUnfinished).count
        let list = unfinishedOnly && unfinishedCount > 0 ? all.filter(Self.isUnfinished) : all
        if list.isEmpty {
            EmptyStateView(icon: "clock.arrow.circlepath", title: "Nothing viewed yet",
                           message: "Posts you open in the viewer show up here, newest first.")
        } else {
            VStack(spacing: 4) {
                HStack {
                    if unfinishedCount > 0 {
                        Picker("Show", selection: $unfinishedOnly) {
                            Text("All \(all.count)").tag(false)
                            Text("Unfinished Videos \(unfinishedCount)").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("recentUnfinished")
                        .onDisappear { unfinishedOnly = false }
                    } else {
                        Text("Last \(list.count) opened").font(.footnote).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Clear") { confirmClear = true }
                        .font(.footnote)
                        .accessibilityIdentifier("clearRecentlyViewed")
                }
                .padding(.horizontal, 12)
                ScrollView {
                    PostGrid(posts: list, onTap: { onOpen(list, $0) }, onAddToCollection: onAddToCollection) { EmptyView() }
                }
            }
            .confirmationDialog("Clear the list of recently viewed posts?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Recent", role: .destructive) { store.clear() }
            }
        }
    }
}
