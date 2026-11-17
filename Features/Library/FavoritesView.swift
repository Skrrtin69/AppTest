import SwiftUI

/// Local favorites (independent of any server) and named collections.
struct FavoritesView: View {
    enum Mode: String, CaseIterable { case favorites = "Favorites", collections = "Collections", later = "Later", recent = "Recent" }
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var mode: Mode = .favorites
    @State private var viewer: ViewerRequest?
    @State private var collectionBatch: PostBatch?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var newCollection = ""
    @State private var showNewCollection = false
    @State private var editingSmart: SmartCollection?
    @State private var showDupes = false
    @ObservedObject private var smart = SmartCollectionStore.shared

    @State private var siteFilter: String?
    @State private var query = ""
    enum SortOrder: String, CaseIterable { case newest = "Newest First", oldest = "Oldest First", shuffled = "Shuffled" }
    @AppStorage("favoritesSort") private var sortRaw = SortOrder.newest.rawValue
    /// A new order each time Shuffle is picked, stable while you scroll and open posts.
    @State private var shuffleSeed = UInt64.random(in: 1...UInt64.max)
    var sortOrder: SortOrder { SortOrder(rawValue: sortRaw) ?? .newest }

    /// Every site's favorites together, narrowed by the site chip and the search text.
    var favoritePosts: [Post] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        var list = store.favorites.map { $0.post }
        switch sortOrder {
        case .newest: break
        case .oldest: list.reverse()
        case .shuffled:
            let seed = shuffleSeed
            list.sort { Self.mix($0.key, seed) < Self.mix($1.key, seed) }
        }
        return list.filter { p in
            !settings.isBlacklisted(p) && (siteFilter == nil || p.siteID == siteFilter) &&
            (q.isEmpty || p.id.lowercased().contains(q) || p.tags.contains { $0.lowercased().contains(q) } ||
             AdapterRegistry.shared.displayName(for: p.siteID).lowercased().contains(q))
        }
    }

    /// Stable per-launch hash of a key and the shuffle seed (FNV-1a).
    static func mix(_ key: String, _ seed: UInt64) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325 ^ seed
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    var favoriteSites: [String] { Array(Set(store.favorites.map { $0.post.siteID })).sorted() }

    var filterBar: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search favorites (tags, ID, site)", text: $query)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityIdentifier("favoritesSearch")
                    .padding(.trailing, 26)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.16)))
            .overlay(alignment: .trailing) {
                Menu {
                    ForEach(SortOrder.allCases, id: \.self) { o in
                        Button {
                            if o == .shuffled { shuffleSeed = UInt64.random(in: 1...UInt64.max) }
                            sortRaw = o.rawValue
                        } label: {
                            if o == sortOrder && o != .shuffled { Label(o.rawValue, systemImage: "checkmark") }
                            else { Text(o == .shuffled && sortOrder == .shuffled ? "Shuffle Again" : o.rawValue) }
                        }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down").padding(8) }
                .accessibilityLabel("Sort favorites: \(sortOrder.rawValue)")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", selected: siteFilter == nil) { siteFilter = nil }
                    ForEach(favoriteSites, id: \.self) { s in
                        chip(AdapterRegistry.shared.displayName(for: s), selected: siteFilter == s) { siteFilter = s }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(selected ? .bold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter \(title)\(selected ? ", selected" : "")")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(10)
                switch mode {
                case .favorites: favoritesGrid
                case .collections: collectionsList
                case .later:
                    ReadLaterGrid(onOpen: { viewer = ViewerRequest(posts: $0, index: $1) },
                                  onAddToCollection: { collectionBatch = PostBatch(posts: $0) })
                case .recent:
                    RecentlyViewedGrid(onOpen: { viewer = ViewerRequest(posts: $0, index: $1) },
                                       onAddToCollection: { collectionBatch = PostBatch(posts: $0) })
                }
            }
            .themedBackground()
            .navigationTitle(mode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if mode == .favorites && favoritePosts.count > 1 {
                        Button { showDupes = true } label: { Image(systemName: "square.on.square.dashed") }
                            .accessibilityLabel("Find look-alike favorites")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if mode == .favorites {
                        Button(selecting ? "Done" : "Select") { selecting.toggle(); selected = [] }
                            .disabled(favoritePosts.isEmpty)
                    } else if mode == .collections {
                        Button { showNewCollection = true } label: { Image(systemName: "folder.badge.plus") }
                            .accessibilityLabel("New collection")
                    }
                }
            }
            .fullScreenCover(item: $viewer) { ViewerView(posts: $0.posts, startIndex: $0.index) }
            .sheet(item: $collectionBatch) { CollectionPickerSheet(posts: $0.posts) }
            .sheet(isPresented: $showNewCollection) { NewCollectionSheet() }
            .sheet(item: $editingSmart) { SmartCollectionEditor(collection: $0) }
            .sheet(isPresented: $showDupes) { DuplicatesSheet(posts: favoritePosts) }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder var favoritesGrid: some View {
        if !store.favorites.isEmpty { filterBar }
        if favoritePosts.isEmpty && !store.favorites.isEmpty {
            EmptyStateView(icon: "magnifyingglass", title: "No matches", message: "No favorites match this filter.")
        } else if favoritePosts.isEmpty {
            EmptyStateView(icon: "heart", title: "No favorites yet",
                           message: "Long-press any thumbnail and choose Favorite, or tap the heart in the viewer.")
        } else {
            ScrollView {
                PostGrid(posts: favoritePosts, selecting: selecting, selected: selected, showSource: siteFilter == nil, showSyncState: true,
                         onTap: { i in
                             if selecting {
                                 let k = favoritePosts[i].key
                                 if selected.contains(k) { selected.remove(k) } else { selected.insert(k) }
                             } else { viewer = ViewerRequest(posts: favoritePosts, index: i) }
                         },
                         onLongPressSelect: { p in selecting = true; selected = [p.key] },
                         onAddToCollection: { collectionBatch = PostBatch(posts: $0) }) { EmptyView() }
            }
            if selecting {
                HStack(spacing: 18) {
                    Text("\(selected.count) selected")
                    Spacer()
                    Button { collectionBatch = PostBatch(posts: favoritePosts.filter { selected.contains($0.key) }) }
                        label: { Image(systemName: "folder.badge.plus") }.accessibilityLabel("Add selected to collection")
                    Button { Task { await DownloadManager.shared.enqueue(favoritePosts.filter { selected.contains($0.key) }) } }
                        label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel("Download selected")
                    Button(role: .destructive) {
                        store.removeFavorites(keys: Array(selected)); selected = []; selecting = false
                    } label: { Image(systemName: "heart.slash") }.accessibilityLabel("Unfavorite selected")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.thinMaterial)
            }
        }
    }

    @ViewBuilder var collectionsList: some View {
        if store.collections.isEmpty && smart.items.isEmpty {
            EmptyStateView(icon: "folder", title: "No collections",
                           message: "Create one with the button above, or long-press a thumbnail › Add to Collection.",
                           actionTitle: "New Collection") { showNewCollection = true }
            Button { editingSmart = SmartCollection(name: "") } label: { Label("New Smart Collection", systemImage: "sparkles") }
                .padding(.bottom, 30)
                .accessibilityIdentifier("newSmartCollection")
        } else {
            List {
                Section {
                    ForEach(smart.items) { c in
                        NavigationLink(destination: SmartCollectionDetailView(collection: c)) {
                            HStack {
                                Label(c.name, systemImage: "sparkles.rectangle.stack")
                                Spacer()
                                Text("\(smart.posts(for: c).count)").foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { smart.items[$0].id }.forEach(smart.delete) }
                    Button { editingSmart = SmartCollection(name: "") } label: { Label("New Smart Collection", systemImage: "sparkles") }
                        .accessibilityIdentifier("newSmartCollection")
                } header: { Text("Smart") } footer: { Text("Smart collections fill themselves from favorites that match their rules.") }
                Section("Collections") {
                ForEach(store.collections) { c in
                    NavigationLink(destination: CollectionDetailView(collectionID: c.id)) {
                        HStack {
                            Label(c.name, systemImage: "folder.fill")
                            Spacer()
                            Text("\(c.keys.count)").foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { store.collections[$0].id }.forEach(store.deleteCollection) }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

struct NewCollectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        NavigationView {
            Form {
                TextField("Collection name", text: $name).accessibilityIdentifier("collectionNameField")
            }
            .keyboardDoneButton()
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { LibraryStore.shared.createCollection(named: name); dismiss() }
                        .disabled(name.nonEmpty == nil)
                }
            }
        }
    }
}

struct CollectionDetailView: View {
    let collectionID: String
    @ObservedObject private var store = LibraryStore.shared
    @State private var viewer: ViewerRequest?
    @State private var collectionBatch: PostBatch?
    @State private var renaming = false
    @State private var newName = ""

    var posts: [Post] { store.posts(inCollection: collectionID) }
    var name: String { store.collections.first { $0.id == collectionID }?.name ?? "Collection" }

    var body: some View {
        Group {
            if posts.isEmpty {
                EmptyStateView(icon: "folder", title: "Empty collection",
                               message: "Long-press a thumbnail anywhere and choose Add to Collection.")
            } else {
                ScrollView {
                    PostGrid(posts: posts, onTap: { viewer = ViewerRequest(posts: posts, index: $0) },
                             onAddToCollection: { collectionBatch = PostBatch(posts: $0) }) {
                        Text("Long-press › Unfavorite removes an item everywhere. Use the menu above to remove from just this collection.")
                            .font(.caption).foregroundColor(.secondary).padding()
                    }
                }
            }
        }
        .themedBackground()
        .navigationTitle(name)
        .toolbar {
            Menu {
                Button { newName = name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                Button { Task { await DownloadManager.shared.enqueue(posts) } } label: { Label("Download All", systemImage: "arrow.down.circle") }
                Button(role: .destructive) { store.remove(posts.map { $0.key }, fromCollection: collectionID) } label: {
                    Label("Remove All From Collection", systemImage: "folder.badge.minus")
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .fullScreenCover(item: $viewer) { ViewerView(posts: $0.posts, startIndex: $0.index) }
        .sheet(item: $collectionBatch) { CollectionPickerSheet(posts: $0.posts) }
        .sheet(isPresented: $renaming) {
            NavigationView {
                Form { TextField("Name", text: $newName) }
                    .navigationTitle("Rename")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { renaming = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { store.renameCollection(collectionID, to: newName); renaming = false }
                        }
                    }
            }
        }
    }
}
