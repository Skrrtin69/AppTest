import SwiftUI

/// Local favorites (independent of any server) and named collections.
struct FavoritesView: View {
    enum Mode: String, CaseIterable { case favorites = "Favorites", collections = "Collections" }
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var mode: Mode = .favorites
    @State private var viewer: ViewerRequest?
    @State private var collectionBatch: PostBatch?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var newCollection = ""
    @State private var showNewCollection = false

    @State private var siteFilter: String?
    @State private var query = ""

    /// Every site's favorites together, narrowed by the site chip and the search text.
    var favoritePosts: [Post] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return store.favorites.map { $0.post }.filter { p in
            !settings.isBlacklisted(p) && (siteFilter == nil || p.siteID == siteFilter) &&
            (q.isEmpty || p.id.lowercased().contains(q) || p.tags.contains { $0.lowercased().contains(q) } ||
             AdapterRegistry.shared.displayName(for: p.siteID).lowercased().contains(q))
        }
    }

    var favoriteSites: [String] { Array(Set(store.favorites.map { $0.post.siteID })).sorted() }

    var filterBar: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search favorites (tags, ID, site)", text: $query)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityIdentifier("favoritesSearch")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.16)))
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
                if mode == .favorites { favoritesGrid } else { collectionsList }
            }
            .themedBackground()
            .navigationTitle(mode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if mode == .favorites {
                        Button(selecting ? "Done" : "Select") { selecting.toggle(); selected = [] }
                            .disabled(favoritePosts.isEmpty)
                    } else {
                        Button { showNewCollection = true } label: { Image(systemName: "folder.badge.plus") }
                            .accessibilityLabel("New collection")
                    }
                }
            }
            .fullScreenCover(item: $viewer) { ViewerView(posts: $0.posts, startIndex: $0.index) }
            .sheet(item: $collectionBatch) { CollectionPickerSheet(posts: $0.posts) }
            .sheet(isPresented: $showNewCollection) { NewCollectionSheet() }
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
        if store.collections.isEmpty {
            EmptyStateView(icon: "folder", title: "No collections",
                           message: "Create one with the button above, or long-press a thumbnail › Add to Collection.",
                           actionTitle: "New Collection") { showNewCollection = true }
        } else {
            List {
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
