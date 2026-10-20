import SwiftUI

/// Reusable thumbnail grid used by Browse, Favorites and Collections.
struct PostGrid<Footer: View>: View {
    let posts: [Post]
    var selecting: Bool = false
    var selected: Set<String> = []
    /// Merged search: label each thumbnail with the site it came from.
    var showSource: Bool = false
    /// Favorites: cloud = also saved to the account, phone = only on this phone.
    var showSyncState: Bool = false
    var onTap: (Int) -> Void
    var onLongPressSelect: ((Post) -> Void)? = nil
    var onAppearIndex: ((Int) -> Void)? = nil
    var onAddToCollection: ([Post]) -> Void
    @ViewBuilder var footer: () -> Footer

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var viewed = ViewedStore.shared
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var columns: [GridItem] {
        // iPhones report a compact vertical size class in landscape, and a full-width iPad window
        // a regular horizontal one: both get more columns. A narrow Split View pane doesn't.
        let n = settings.columns(landscape: verticalSizeClass == .compact || horizontalSizeClass == .regular)
        return Array(repeating: GridItem(.flexible(), spacing: settings.gridSpacing), count: n)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: settings.gridSpacing) {
            ForEach(Array(posts.enumerated()), id: \.element.key) { index, post in
                GridCell(post: post, aspect: settings.thumbAspect, selecting: selecting,
                         isSelected: selected.contains(post.key), showSource: showSource, showSyncState: showSyncState)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // With blur on, the first tap only reveals the thumbnail.
                        if settings.blurThumbnails && !selecting && !viewed.isRevealed(post.key) {
                            viewed.reveal(post.key)
                            Haptics.tap()
                        } else {
                            onTap(index)
                        }
                    }
                    .modifier(PeekContextMenu(post: post) {
                        PostMenuItems(post: post, onSelect: onLongPressSelect.map { f in { f(post) } },
                                      onAddToCollection: { onAddToCollection([post]) })
                    })
                    .onAppear { onAppearIndex?(index) }
                    .accessibilityIdentifier("cell-\(post.id)")
            }
        }
        .padding(.horizontal, settings.gridSpacing)
        footer()
    }
}

struct GridCell: View {
    let post: Post
    let aspect: ThumbAspect
    var selecting: Bool = false
    var isSelected: Bool = false
    var showSource: Bool = false
    var showSyncState: Bool = false
    @ObservedObject private var favoriteSync = FavoriteSync.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var viewed = ViewedStore.shared
    @State private var loadedRatio: CGFloat?

    var blurred: Bool { settings.blurThumbnails && !viewed.isRevealed(post.key) }
    var dimmed: Bool { settings.dimViewed && viewed.isViewed(post.key) && !selecting }

    var ratio: CGFloat {
        guard aspect == .original else { return 1 }
        if let s = post.pixelSize { return s.width / s.height }
        return loadedRatio ?? 1
    }

    var body: some View {
        Color.gray.opacity(0.12)
            .aspectRatio(max(0.4, min(ratio, 2.5)), contentMode: .fit)
            .overlay(
                CachedAsyncImage(url: post.thumbnailURL, maxPixel: 420,
                                 animate: settings.gridGIFsAnimate,
                                 client: AdapterRegistry.shared.adapter(for: post.siteID)?.client,
                                 onLoad: { img in
                                     if img.size.height > 0 { loadedRatio = img.size.width / img.size.height }
                                 })
                    .blur(radius: blurred ? 16 : 0)
            )
            .clipped()
            .opacity(dimmed ? 0.45 : 1)
            .overlay {
                if blurred {
                    Image(systemName: "eye.slash").font(.title3).foregroundColor(.white.opacity(0.85)).shadow(radius: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if post.isGallery {
                    Label("\(post.pages?.count ?? 0)", systemImage: "square.stack.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .foregroundColor(.white)
                        .padding(4)
                } else if post.mediaType != .image {
                    Image(systemName: post.mediaType == .video ? "play.fill" : "sparkles")
                        .font(.caption2.weight(.bold))
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .foregroundColor(.white)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showSource { SourceBadge(siteID: post.siteID).padding(3) }
                if showSyncState {
                    Image(systemName: favoriteSync.isSynced(post) ? "icloud.fill" : "iphone")
                        .font(.caption2.weight(.bold)).foregroundColor(.white)
                        .padding(4).background(Circle().fill(Color.black.opacity(0.55))).padding(3)
                        .accessibilityLabel(favoriteSync.isSynced(post) ? "Saved to account" : "Saved on this phone")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if store.favoriteKeys.contains(post.key) {
                    Image(systemName: "heart.fill").font(.caption2)
                        .foregroundColor(.pink).padding(5)
                        .shadow(radius: 2)
                }
            }
            .overlay {
                if selecting {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(isSelected ? 0.35 : 0)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(isSelected ? .accentColor : .white)
                            .background(Circle().fill(Color.white.opacity(isSelected ? 1 : 0)).padding(2))
                            .padding(6)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(post.isGallery ? "Gallery of \(post.pages?.count ?? 0) pages" : post.mediaType.label) \(post.id)\(showSource ? " from \(AdapterRegistry.shared.displayName(for: post.siteID))" : "")\(blurred ? ", hidden" : "")\(dimmed ? ", viewed" : "")\(isSelected ? ", selected" : "")")
            .accessibilityAddTraits(.isButton)
    }
}

/// Tiny colored label naming a post's site (merged search).
struct SourceBadge: View {
    let siteID: String
    var body: some View {
        let name = AdapterRegistry.shared.displayName(for: siteID)
        Text(Self.short(name))
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Capsule().fill(Self.color(for: siteID)))
            .accessibilityHidden(true)
    }

    /// "Demo Site A" → "DSA"; single words keep their first 4 letters.
    static func short(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        if words.count >= 2 {
            return String(words.prefix(3).compactMap { w in w.first(where: { $0.isLetter }) ?? w.first }).uppercased()
        }
        return String(name.prefix(4)).uppercased()
    }

    /// Stable color per site.
    static func color(for id: String) -> Color {
        let hash = id.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        // Golden-ratio spacing keeps similar IDs ("demo-a", "demo-b") far apart in hue.
        let hue = (Double(hash % 1000) * 0.618033988749895).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.7, brightness: 0.8)
    }
}

/// Long-press menu shared by all grids and the viewer.
struct PostMenuItems: View {
    let post: Post
    var onSelect: (() -> Void)? = nil
    var onAddToCollection: () -> Void
    @ObservedObject private var store = LibraryStore.shared

    var body: some View {
        if let s = onSelect {
            Button { s() } label: { Label("Select", systemImage: "checkmark.circle") }
        }
        Button {
            Task { await DownloadManager.shared.enqueue([post]) }
        } label: { Label("Download", systemImage: "arrow.down.circle") }
        Button {
            store.toggleFavorite(post)
        } label: {
            store.isFavorite(post) ? Label("Unfavorite", systemImage: "heart.slash") : Label("Favorite", systemImage: "heart")
        }
        Button { onAddToCollection() } label: { Label("Add to Collection…", systemImage: "folder.badge.plus") }
        if post.mediaType != .video {
            Button { Task { await ImageClipboard.copy(post) } } label: { Label("Copy Image", systemImage: "photo.on.rectangle") }
        }
        Button {
            UIPasteboard.general.string = post.mediaURL.absoluteString
            ToastCenter.shared.show("URL copied")
        } label: { Label("Copy URL", systemImage: "doc.on.doc") }
        Button {
            UIPasteboard.general.string = post.id
            ToastCenter.shared.show("ID \(post.id) copied")
        } label: { Label("Copy ID", systemImage: "number") }
        Button { Presenter.share([post.mediaURL]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        if let src = post.sourceURL {
            Button { UIApplication.shared.open(src) } label: { Label("Open Source", systemImage: "safari") }
        }
    }
}

struct PostBatch: Identifiable {
    let id = UUID()
    let posts: [Post]
}

/// Pick (or create) a collection for one or more posts.
struct CollectionPickerSheet: View {
    let posts: [Post]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LibraryStore.shared
    @State private var newName = ""

    var body: some View {
        NavigationView {
            List {
                Section("New collection") {
                    HStack {
                        TextField("Collection name", text: $newName)
                            .accessibilityIdentifier("newCollectionName")
                        Button("Create & Add") {
                            if let id = store.createCollection(named: newName) {
                                store.add(posts, toCollection: id)
                                dismiss()
                            }
                        }
                        .disabled(newName.nonEmpty == nil)
                    }
                }
                Section("Add \(posts.count) item\(posts.count == 1 ? "" : "s") to") {
                    if store.collections.isEmpty {
                        Text("No collections yet — create one above.").foregroundColor(.secondary)
                    }
                    ForEach(store.collections) { c in
                        Button {
                            store.add(posts, toCollection: c.id)
                            dismiss()
                        } label: {
                            HStack {
                                Label(c.name, systemImage: "folder")
                                Spacer()
                                Text("\(c.keys.count)").foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .keyboardDoneButton()
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
