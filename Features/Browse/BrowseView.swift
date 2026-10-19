import SwiftUI

struct ViewerRequest: Identifiable {
    let id = UUID()
    let posts: [Post]
    let index: Int
}

struct BrowseView: View {
    @ObservedObject var model = BrowseModel.shared
    @ObservedObject var registry = AdapterRegistry.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var searchText = ""
    @State private var showHistory = false
    @State private var viewer: ViewerRequest?
    @State private var collectionBatch: PostBatch?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar
                tabStrip
                Divider()
                ZStack {
                    if model.tabs.isEmpty {
                        EmptyStateView(icon: "square.stack.3d.up.slash", title: "No sites enabled",
                                       message: "Turn on a site in Settings › Sites & Adapters.")
                    }
                    ForEach(model.tabs) { tab in
                        SearchTabView(tab: tab, onOpen: { posts, i in viewer = ViewerRequest(posts: posts, index: i) },
                                      onAddToCollection: { collectionBatch = PostBatch(posts: $0) })
                            .opacity(tab.id == model.current?.id ? 1 : 0)
                            .allowsHitTesting(tab.id == model.current?.id)
                            .accessibilityHidden(tab.id != model.current?.id)
                    }
                }
            }
            .themedBackground()
            .navigationTitle(model.current?.siteName ?? "Browse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { siteMenu }
                ToolbarItem(placement: .navigationBarTrailing) { optionsMenu }
            }
            .sheet(isPresented: $showHistory) {
                SearchHistorySheet { query, site in
                    showHistory = false
                    run(query: query, siteID: site)
                }
            }
            .sheet(item: $collectionBatch) { CollectionPickerSheet(posts: $0.posts) }
            .fullScreenCover(item: $viewer) { req in
                ViewerView(posts: req.posts, startIndex: req.index)
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            model.ensureTab()
            searchText = model.current?.query ?? ""
        }
        .onChange(of: model.selectedID) { _ in searchText = model.current?.query ?? "" }
        .onChange(of: registry.configs) { _ in model.ensureTab() }
    }

    // MARK: Pieces

    var searchBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Tags (space-separated, -tag to exclude)", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { run(query: searchText, siteID: model.current?.siteID) }
                    .accessibilityIdentifier("searchField")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .accessibilityLabel("Clear search text")
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.16)))
            Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .accessibilityLabel("Search history and saved searches")
            Button {
                if let t = model.current {
                    LibraryStore.shared.saveSearch(name: searchText, query: searchText, siteID: t.siteID)
                }
            } label: { Image(systemName: "bookmark") }
            .accessibilityLabel("Save this search")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    TabChip(tab: tab, isSelected: tab.id == model.current?.id, canClose: model.tabs.count > 1,
                            onSelect: { model.selectedID = tab.id },
                            onClose: { model.close(tab) })
                }
                Button {
                    let site = model.current?.siteID ?? registry.enabledConfigs.first?.id
                    if let s = site { model.openTab(siteID: s, query: "") }
                } label: {
                    Image(systemName: "plus").padding(8)
                }
                .accessibilityLabel("New search tab")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    var siteMenu: some View {
        Menu {
            ForEach(registry.enabledConfigs) { c in
                Button {
                    guard let t = model.current else { return }
                    t.siteID = c.id
                    model.objectWillChange.send()   // nav title shows the tab's site
                    t.sort = nil
                    t.rating = nil
                    Task { await t.search(recordHistory: false) }
                } label: {
                    if c.id == model.current?.siteID { Label(c.displayName, systemImage: "checkmark") } else { Text(c.displayName) }
                }
            }
        } label: {
            Label("Site", systemImage: "globe")
        }
        .accessibilityLabel("Switch site")
    }

    var optionsMenu: some View {
        Menu {
            if let t = model.current, let cfg = registry.config(for: t.siteID) {
                if !cfg.sortOptions.isEmpty {
                    Menu("Sort: \(t.sort ?? "default")") {
                        Button("Default") { t.sort = nil; Task { await t.search(recordHistory: false) } }
                        ForEach(cfg.sortOptions, id: \.self) { o in
                            Button(o) { t.sort = o; Task { await t.search(recordHistory: false) } }
                        }
                    }
                }
                if !cfg.ratingOptions.isEmpty {
                    Menu("Rating: \(t.rating ?? "any")") {
                        Button("Any") { t.rating = nil; Task { await t.search(recordHistory: false) } }
                        ForEach(cfg.ratingOptions, id: \.self) { o in
                            Button(o) { t.rating = o; Task { await t.search(recordHistory: false) } }
                        }
                    }
                }
                Button {
                    t.selecting.toggle()
                    t.selected = []
                } label: { Label(t.selecting ? "Done Selecting" : "Select", systemImage: "checkmark.circle") }
            }
            Menu("Columns: \(settings.gridColumns)") {
                ForEach(2...5, id: \.self) { n in
                    Button { settings.gridColumns = n } label: {
                        if n == settings.gridColumns { Label("\(n) columns", systemImage: "checkmark") } else { Text("\(n) columns") }
                    }
                }
            }
            Menu("Thumbnails: \(settings.thumbAspect.label)") {
                ForEach(ThumbAspect.allCases) { a in
                    Button(a.label) { settings.thumbAspect = a }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("View options")
    }

    func run(query: String, siteID: String?) {
        searchFocused = false
        guard let t = model.current else { return }
        if let s = siteID, registry.config(for: s) != nil { t.siteID = s }
        t.query = query
        searchText = query
        Task { await t.search() }
    }
}

struct TabChip: View {
    @ObservedObject var tab: SearchTabModel
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("\(tab.title)").lineLimit(1).font(.subheadline.weight(isSelected ? .semibold : .regular))
            Text("· \(tab.siteName)").lineLimit(1).font(.caption).foregroundColor(.secondary)
            if canClose && isSelected {
                Button(action: onClose) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .accessibilityLabel("Close tab \(tab.title)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.14)))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Tab \(tab.title) on \(tab.siteName)")
    }
}

/// Grid + infinite scroll + pull-to-refresh + selection bar for one tab.
struct SearchTabView: View {
    @ObservedObject var tab: SearchTabModel
    @ObservedObject var settings = AppSettings.shared
    let onOpen: ([Post], Int) -> Void
    let onAddToCollection: ([Post]) -> Void

    var body: some View {
        let visible = tab.visiblePosts(blacklist: settings.blacklistSet)
        VStack(spacing: 0) {
            if visible.isEmpty && !tab.isLoading {
                if let err = tab.error {
                    EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load", message: err,
                                   actionTitle: "Retry") { Task { await tab.retry() } }
                } else if tab.hasSearched {
                    EmptyStateView(icon: "magnifyingglass", title: "No results",
                                   message: tab.posts.isEmpty ? "Nothing matched \"\(tab.title)\" on \(tab.siteName)." :
                                    "All results are hidden by your tag blacklist.",
                                   actionTitle: "Retry") { Task { await tab.search(recordHistory: false) } }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    PostGrid(posts: visible, selecting: tab.selecting, selected: tab.selected,
                             onTap: { i in
                                 if tab.selecting { tab.toggleSelect(visible[i]) } else { Haptics.tap(); onOpen(visible, i) }
                             },
                             onLongPressSelect: { p in tab.selecting = true; tab.selected = [p.key] },
                             onAppearIndex: { i in tab.onCellAppear(index: i, visibleCount: visible.count) },
                             onAddToCollection: onAddToCollection) {
                        footer
                    }
                }
                .refreshable { await tab.search(recordHistory: false) }
            }
            if tab.selecting { selectionBar }
        }
    }

    @ViewBuilder var footer: some View {
        Group {
            if tab.isLoading {
                HStack(spacing: 8) { ProgressView(); Text("Loading more…").foregroundColor(.secondary) }
                    .accessibilityIdentifier("loadingFooter")
            } else if let err = tab.error {
                VStack(spacing: 6) {
                    Text(err).font(.caption).foregroundColor(.red).multilineTextAlignment(.center)
                    Button("Retry") { Task { await tab.retry() } }
                }
            } else if !tab.hasNext && !tab.posts.isEmpty {
                Text("End of results · \(tab.posts.count) posts").font(.caption).foregroundColor(.secondary)
                    .accessibilityIdentifier("endOfResults")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    var selectionBar: some View {
        let picked = tab.selectedPosts()
        return HStack(spacing: 14) {
            Button("Cancel") { tab.selecting = false; tab.selected = [] }
            Spacer()
            Text("\(picked.count) selected").font(.subheadline)
            Spacer()
            Button {
                let all = tab.visiblePosts(blacklist: settings.blacklistSet)
                tab.selected = picked.count == all.count ? [] : Set(all.map { $0.key })
            } label: { Image(systemName: "checklist") }
            .accessibilityLabel("Select all")
            Button { LibraryStore.shared.addFavorites(picked); ToastCenter.shared.show("Favorited \(picked.count)", style: .success) }
                label: { Image(systemName: "heart") }
                .disabled(picked.isEmpty).accessibilityLabel("Favorite selected")
            Button { onAddToCollection(picked) } label: { Image(systemName: "folder.badge.plus") }
                .disabled(picked.isEmpty).accessibilityLabel("Add selected to collection")
            Button {
                Task { await DownloadManager.shared.enqueue(picked) }
                tab.selecting = false
                tab.selected = []
            } label: { Image(systemName: "arrow.down.circle.fill") }
                .disabled(picked.isEmpty).accessibilityLabel("Download selected")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            if let t = actionTitle, let a = action {
                Button(t, action: a).buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SearchHistorySheet: View {
    let onRun: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var registry = AdapterRegistry.shared

    var body: some View {
        NavigationView {
            List {
                Section("Saved searches") {
                    if store.savedSearches.isEmpty { Text("Tap the bookmark icon next to the search field to save a search.").foregroundColor(.secondary).font(.footnote) }
                    ForEach(store.savedSearches) { s in
                        Button { onRun(s.query, s.siteID) } label: {
                            VStack(alignment: .leading) {
                                Text(s.name)
                                Text("\(s.query.nonEmpty ?? "(all)") · \(registry.displayName(for: s.siteID))").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { store.savedSearches[$0].id }.forEach(store.deleteSavedSearch) }
                }
                Section("Recent searches") {
                    if store.history.isEmpty { Text("No searches yet.").foregroundColor(.secondary) }
                    ForEach(store.history) { h in
                        Button { onRun(h.query, h.siteID) } label: {
                            HStack {
                                Image(systemName: "clock")
                                Text(h.query)
                                Spacer()
                                Text(registry.displayName(for: h.siteID)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { store.history[$0] }.forEach(store.deleteHistory) }
                }
            }
            .navigationTitle("Searches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear History") { store.clearHistory() }.disabled(store.history.isEmpty)
                }
            }
        }
    }
}
