import SwiftUI

/// One open search. Each tab keeps its own results, pagination and scroll position.
@MainActor
final class SearchTabModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var siteID: String
    @Published var query: String
    @Published var sort: String?
    @Published var rating: String?
    @Published private(set) var posts: [Post] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasNext = true
    @Published private(set) var error: String?
    @Published private(set) var hasSearched = false
    @Published var selecting = false
    @Published var selected: Set<String> = []

    private var page = 1
    private var cursor: String?
    private var generation = 0
    private var seen = Set<String>()

    init(siteID: String, query: String = "") {
        self.siteID = siteID
        self.query = query
    }

    var title: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? "All" : q
    }

    var siteName: String { AdapterRegistry.shared.displayName(for: siteID) }

    /// Space-separated tags; a leading "-" excludes a tag and is passed through unchanged.
    var tags: [String] {
        query.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init).filter { $0 != "-" }
    }

    /// Blacklisted posts are hidden (applied live, so editing the blacklist updates every grid).
    func visiblePosts(blacklist: Set<String>) -> [Post] {
        guard !blacklist.isEmpty else { return posts }
        return posts.filter { !$0.tags.contains { blacklist.contains($0.lowercased()) } }
    }

    /// Starts over from page 1.
    func search(recordHistory: Bool = true) async {
        generation += 1
        posts = []
        seen = []
        page = 1
        cursor = nil
        hasNext = true
        error = nil
        isLoading = false
        hasSearched = true
        selected = []
        if recordHistory, query.nonEmpty != nil {
            LibraryStore.shared.recordSearch(query, siteID: siteID)
        }
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, hasNext else { return }
        guard let adapter = AdapterRegistry.shared.adapter(for: siteID) else {
            error = "The site \"\(siteID)\" isn't in your adapters list anymore. Pick another site."
            hasNext = false
            return
        }
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            try await AuthManager.shared.ensureSession(for: adapter)
            let options = SearchOptions(sort: sort, rating: rating, extra: [:], cursor: cursor)
            let result = try await adapter.search(tags: tags, options: options, page: page)
            guard gen == generation else { return }
            let fresh = result.posts.filter { seen.insert($0.key).inserted }
            posts.append(contentsOf: fresh)
            page += 1
            cursor = result.nextCursor
            hasNext = result.hasNextPage && !result.posts.isEmpty
            error = nil
        } catch {
            guard gen == generation else { return }
            if error is CancellationError { return }
            self.error = error.localizedDescription
            ToastCenter.shared.error(error, prefix: siteName)
        }
    }

    /// Infinite scroll trigger: load when one of the last few cells appears.
    func onCellAppear(index: Int, visibleCount: Int) {
        if index >= visibleCount - 6 && hasNext && !isLoading && error == nil {
            Task { await loadMore() }
        }
    }

    func retry() async {
        if posts.isEmpty { await search(recordHistory: false) } else { error = nil; await loadMore() }
    }

    func toggleSelect(_ post: Post) {
        if selected.contains(post.key) { selected.remove(post.key) } else { selected.insert(post.key) }
        Haptics.tap()
    }

    func selectedPosts() -> [Post] { posts.filter { selected.contains($0.key) } }
}

/// The set of open search tabs.
@MainActor
final class BrowseModel: ObservableObject {
    static let shared = BrowseModel()
    @Published var tabs: [SearchTabModel] = []
    @Published var selectedID: UUID?

    var current: SearchTabModel? { tabs.first { $0.id == selectedID } ?? tabs.first }

    /// Makes sure there's at least one tab pointing at an enabled site.
    func ensureTab() {
        let enabled = AdapterRegistry.shared.enabledConfigs
        guard let first = enabled.first else { return }
        if tabs.isEmpty {
            let t = SearchTabModel(siteID: first.id)
            tabs = [t]
            selectedID = t.id
            Task { await t.search(recordHistory: false) }
        }
        for t in tabs where AdapterRegistry.shared.config(for: t.siteID) == nil {
            t.siteID = first.id
        }
    }

    @discardableResult
    func openTab(siteID: String, query: String) -> SearchTabModel {
        let t = SearchTabModel(siteID: siteID, query: query)
        tabs.append(t)
        selectedID = t.id
        Task { await t.search() }
        return t
    }

    func close(_ tab: SearchTabModel) {
        guard tabs.count > 1 else { return }
        let idx = tabs.firstIndex { $0.id == tab.id } ?? 0
        tabs.removeAll { $0.id == tab.id }
        if selectedID == tab.id { selectedID = tabs[max(0, idx - 1)].id }
    }
}

/// Cross-tab navigation (e.g. tapping a tag in the viewer opens a search in Browse).
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    enum Tab: Hashable { case browse, favorites, library, downloads, settings }
    @Published var tab: Tab = .browse

    func search(tag: String, siteID: String) {
        tab = .browse
        let site = AdapterRegistry.shared.config(for: siteID) != nil ? siteID : (AdapterRegistry.shared.enabledConfigs.first?.id ?? siteID)
        BrowseModel.shared.openTab(siteID: site, query: tag)
    }
}
