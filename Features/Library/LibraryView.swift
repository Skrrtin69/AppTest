import SwiftUI

/// Grid of completed downloads, stored under Documents/Downloads (also visible in the Files app).
struct LibraryView: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var registry = AdapterRegistry.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var siteFilter: String?
    @State private var search = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var viewer: ViewerRequest?
    @State private var confirmDelete = false

    var items: [DownloadItem] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return downloads.completed.reversed().filter { item in
            (siteFilter == nil || item.post.siteID == siteFilter) &&
            (q.isEmpty || item.filename.lowercased().contains(q) || item.post.siteID.lowercased().contains(q) ||
             registry.displayName(for: item.post.siteID).lowercased().contains(q) ||
             item.post.tags.contains { $0.lowercased().contains(q) })
        }
    }

    var sites: [String] { Array(Set(downloads.completed.map { $0.post.siteID })).sorted() }

    /// Library items as posts that point at the local files.
    func localPosts(_ list: [DownloadItem]) -> [Post] {
        list.compactMap { i in i.fileURL.map { i.post.with(mediaURL: $0, thumbnailURL: i.post.mediaType == .image || i.post.mediaType == .gif ? $0 : nil) } }
    }

    var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 3), count: settings.gridColumns) }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if downloads.completed.isEmpty {
                    EmptyStateView(icon: "tray", title: "Library is empty",
                                   message: "Downloaded media shows up here. Tap the download button in the viewer, or select several thumbnails and download them together.")
                } else if items.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "No matches", message: "Nothing in your library matches this filter.")
                } else {
                    ScrollView {
                        let list = items
                        let posts = localPosts(list)
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                                cell(item, post: posts.indices.contains(i) ? posts[i] : item.post)
                                    .onTapGesture {
                                        if selecting { toggle(item.id) } else { viewer = ViewerRequest(posts: posts, index: i) }
                                    }
                                    .contextMenu { menu(for: [item]) }
                            }
                        }
                        .padding(3)
                        Text("\(list.count) item\(list.count == 1 ? "" : "s")").font(.caption).foregroundColor(.secondary).padding()
                    }
                }
                if selecting { selectionBar }
            }
            .themedBackground()
            .searchable(text: $search, prompt: "Search filename, tags, site")
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button { siteFilter = nil } label: { siteFilter == nil ? Label("All Sites", systemImage: "checkmark") : Label("All Sites", systemImage: "") }
                        ForEach(sites, id: \.self) { s in
                            Button { siteFilter = s } label: {
                                siteFilter == s ? Label(registry.displayName(for: s), systemImage: "checkmark") : Label(registry.displayName(for: s), systemImage: "")
                            }
                        }
                    } label: { Label(siteFilter.map { registry.displayName(for: $0) } ?? "All Sites", systemImage: "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("Filter by site")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selecting ? "Done" : "Select") { selecting.toggle(); selected = [] }
                        .disabled(downloads.completed.isEmpty)
                }
            }
            .fullScreenCover(item: $viewer) { ViewerView(posts: $0.posts, startIndex: $0.index, isLocal: true) }
            .confirmationDialog("Delete \(selected.count) item(s) from this device?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    downloads.remove(Array(selected)); selected = []; selecting = false
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        Haptics.tap()
    }

    func cell(_ item: DownloadItem, post: Post) -> some View {
        GridCell(post: post, aspect: settings.thumbAspect, selecting: selecting, isSelected: selected.contains(item.id))
            .accessibilityLabel("Library \(item.filename)\(selected.contains(item.id) ? ", selected" : "")")
    }

    @ViewBuilder func menu(for list: [DownloadItem]) -> some View {
        Button { Task { await downloads.exportToPhotos(list) } } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
        Button { downloads.exportToFiles(list) } label: { Label("Export to Files", systemImage: "folder") }
        Button { downloads.exportZIP(list) } label: { Label("Export as ZIP", systemImage: "doc.zipper") }
        Button { Presenter.share(list.compactMap { $0.fileURL }) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        Button {
            selecting = true
            selected = Set(list.map { $0.id })
        } label: { Label("Select", systemImage: "checkmark.circle") }
        Button(role: .destructive) { downloads.remove(list.map { $0.id }) } label: { Label("Delete", systemImage: "trash") }
    }

    var selectionBar: some View {
        let picked = items.filter { selected.contains($0.id) }
        return HStack(spacing: 18) {
            Button(selected.count == items.count ? "None" : "All") {
                selected = selected.count == items.count ? [] : Set(items.map { $0.id })
            }
            Button("Invert") { selected = Set(items.map { $0.id }).subtracting(selected) }
            Text("\(picked.count) selected").font(.subheadline)
            Spacer()
            Button { Task { await downloads.exportToPhotos(picked) } } label: { Image(systemName: "photo.on.rectangle") }
                .disabled(picked.isEmpty).accessibilityLabel("Save selected to Photos")
            Button { downloads.exportToFiles(picked) } label: { Image(systemName: "folder") }
                .disabled(picked.isEmpty).accessibilityLabel("Export selected to Files")
            Button { downloads.exportZIP(picked) } label: { Image(systemName: "doc.zipper") }
                .disabled(picked.isEmpty).accessibilityLabel("Export selected as ZIP")
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .disabled(picked.isEmpty).accessibilityLabel("Delete selected")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.thinMaterial)
    }
}
