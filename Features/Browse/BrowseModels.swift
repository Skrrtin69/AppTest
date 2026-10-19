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

    var siteName: String { isMerged ? "All Sites" : AdapterRegistry.shared.displayName(for: siteID) }

    // MARK: Merged search

    /// Pseudo site ID for a tab that searches every enabled site at once.
    static let mergedID = "__all_sites__"
    var isMerged: Bool { siteID == Self.mergedID }

    /// Each site's own pagination inside a merged tab.
    struct SiteCursor {
        var page = 1
        var cursor: String?
        var hasNext = true
        var error: String?
    }
    private var siteStates: [String: SiteCursor] = [:]
    /// Sites that failed in a merged tab (site name → message), for the banner.
    @Published private(set) var siteErrors: [String: String] = [:]
    @Published var errorBannerDismissed = false
    private var seenMedia = Set<String>()

    /// Fetches the next page from every site that still has more, in parallel, and merges
    /// them. A failing site is reported in the banner; the others keep going.
    private func loadMerged(replace: Bool) async {
        let gen = generation
        if replace { siteStates = [:] }
        let ids = AdapterRegistry.shared.enabledConfigs.map { $0.id }
        for id in ids where siteStates[id] == nil { siteStates[id] = SiteCursor() }
        let active = ids.filter { siteStates[$0]?.hasNext == true && siteStates[$0]?.error == nil }
        guard !active.isEmpty else { hasNext = false; return }
        isLoading = true
        defer { if gen == generation { isLoading = false } }

        let tags = self.tags
        var jobs: [(String, GenericAdapter, SiteCursor)] = []
        for id in active { if let a = AdapterRegistry.shared.adapter(for: id), let st = siteStates[id] { jobs.append((id, a, st)) } }
        let results: [String: Result<SearchResult, Error>] = await withTaskGroup(of: (String, Result<SearchResult, Error>).self) { group in
            for (id, adapter, st) in jobs {
                group.addTask {
                    do {
                        try await AuthManager.shared.ensureSession(for: adapter)
                        let r = try await adapter.search(tags: tags, options: SearchOptions(cursor: st.cursor), page: st.page)
                        return (id, .success(r))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            var out: [String: Result<SearchResult, Error>] = [:]
            for await (id, r) in group { out[id] = r }
            return out
        }
        guard gen == generation else { return }

        var perSite: [[Post]] = []
        var errors = replace ? [:] : siteErrors
        for (id, _, _) in jobs {
            guard let r = results[id] else { continue }
            switch r {
            case .success(let res):
                siteStates[id]?.page += 1
                siteStates[id]?.cursor = res.nextCursor
                siteStates[id]?.hasNext = res.hasNextPage && !res.posts.isEmpty
                perSite.append(res.posts)
            case .failure(let e):
                if Self.isCancellation(e) { continue }
                siteStates[id]?.error = e.localizedDescription
                errors[AdapterRegistry.shared.displayName(for: id)] = e.localizedDescription
            }
        }
        // Interleave so every site shows up near the top, then drop duplicates by
        // post key or by identical media address (the same file mirrored on two sites).
        var merged: [Post] = []
        let longest = perSite.map { $0.count }.max() ?? 0
        for i in 0..<longest { for list in perSite where i < list.count { merged.append(list[i]) } }
        if replace { seen = []; seenMedia = [] }
        let fresh = merged.filter { seen.insert($0.key).inserted && seenMedia.insert($0.mediaURL.absoluteString).inserted }
        if replace { posts = fresh } else { posts.append(contentsOf: fresh) }
        siteErrors = errors
        if !errors.isEmpty && replace { errorBannerDismissed = false }
        hasNext = siteStates.values.contains { $0.hasNext && $0.error == nil }
        error = (posts.isEmpty && !errors.isEmpty && errors.count == jobs.count)
            ? errors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n") : nil
    }

    /// Space-separated tags; a leading "-" excludes a tag and is passed through unchanged.
    /// Space-separated tags; "quoted phrases" are one tag; "-" excludes a tag.
    var tags: [String] { TagQuery.parse(query) }

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
        siteStates = [:]
        siteErrors = [:]
        seenMedia = []
        if recordHistory, query.nonEmpty != nil, !isMerged {
            LibraryStore.shared.recordSearch(query, siteID: siteID)
        }
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, hasNext else { return }
        if isMerged { await loadMerged(replace: false); return }
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
            guard gen == generation, !Self.isCancellation(error) else { return }
            self.error = error.localizedDescription
            ToastCenter.shared.error(error, prefix: siteName)
        }
    }

    /// Pull-to-refresh: fetches page 1 first and swaps it in, keeping the current grid on
    /// screen meanwhile (clearing it would tear down the scroll view running the refresh).
    func refresh() async {
        if isMerged {
            generation += 1
            hasSearched = true
            await loadMerged(replace: true)
            return
        }
        guard let adapter = AdapterRegistry.shared.adapter(for: siteID) else { return }
        generation += 1
        let gen = generation
        do {
            try await AuthManager.shared.ensureSession(for: adapter)
            let result = try await adapter.search(tags: tags, options: SearchOptions(sort: sort, rating: rating), page: 1)
            guard gen == generation else { return }
            var keys = Set<String>()
            posts = result.posts.filter { keys.insert($0.key).inserted }
            seen = keys
            page = 2
            cursor = result.nextCursor
            hasNext = result.hasNextPage && !result.posts.isEmpty
            error = nil
            hasSearched = true
            isLoading = false
        } catch {
            guard gen == generation, !Self.isCancellation(error) else { return }
            self.error = error.localizedDescription
            ToastCenter.shared.error(error, prefix: siteName)
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
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

/// Debounced tag suggestions for the search bar (adapter's autocompletePath).
@MainActor
final class SuggestionModel: ObservableObject {
    @Published private(set) var suggestions: [String] = []
    private var task: Task<Void, Never>?

    /// Waits 300 ms after the last keystroke, then asks the site for suggestions.
    func update(text: String, siteID: String?) {
        task?.cancel()
        let token = TagQuery.partialToken(text)
        guard token.count >= 2, let id = siteID, let adapter = AdapterRegistry.shared.adapter(for: id),
              adapter.supportsAutocomplete else {
            suggestions = []
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await adapter.suggest(token)
                guard !Task.isCancelled else { return }
                self?.suggestions = Array(found.filter { $0.lowercased() != token.lowercased() || found.count == 1 }.prefix(8))
            } catch {
                guard !Task.isCancelled else { return }
                self?.suggestions = []
            }
        }
    }

    func clear() {
        task?.cancel()
        suggestions = []
    }
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
        // Tabs pointing at a removed or switched-off site move to the first enabled one.
        let enabledIDs = Set(enabled.map { $0.id })
        for t in tabs where !t.isMerged && !enabledIDs.contains(t.siteID) {
            t.siteID = first.id
            Task { await t.search(recordHistory: false) }
        }
        objectWillChange.send()
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
