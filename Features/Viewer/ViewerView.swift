import SwiftUI

/// Full-screen viewer. Swipe left/right between posts; pinch or double-tap to zoom;
/// single tap toggles the controls. Neighbors within 2 positions are preloaded.
struct ViewerView: View {
    let posts: [Post]
    var isLocal: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = LibraryStore.shared
    @State private var index: Int
    @State private var chrome = true
    @State private var zoomed = false
    @State private var slideshow = false
    @State private var showInfo = false
    @State private var collectionBatch: PostBatch?
    @State private var sizes: [String: CGSize] = [:]
    // Vertical drag: swipe down to close; left edge = brightness, right edge = volume.
    @State private var dragMode: ViewerDragMode = .none
    @State private var dragOffset: CGFloat = 0
    @State private var startLevel: Double = 0
    @State private var hud: (icon: String, level: Double)?

    init(posts: [Post], startIndex: Int, isLocal: Bool = false) {
        self.posts = posts
        self.isLocal = isLocal
        _index = State(initialValue: min(max(0, startIndex), max(0, posts.count - 1)))
    }

    var current: Post? { posts.indices.contains(index) ? posts[index] : nil }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - Double(min(dragOffset, 400)) / 600).ignoresSafeArea()
            Group {
                if settings.verticalReading {
                    VerticalReader(posts: posts, startIndex: index, index: $index,
                                   onOpenPaged: { i in settings.verticalReading = false; index = i },
                                   onTap: { withAnimation { chrome.toggle() } })
                } else {
                    TabView(selection: $index) {
                        ForEach(posts.indices, id: \.self) { i in
                            ViewerPage(post: posts[i], isActive: i == index, isNear: abs(i - index) <= 2,
                                       aspect: settings.viewerAspect, showControls: chrome,
                                       onZoom: { zoomed = $0 },
                                       onTap: { withAnimation { chrome.toggle() } },
                                       onSize: { sizes[posts[i].key] = $0 })
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .simultaneousGesture(verticalDrag)
                }
            }
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .scaleEffect(1 - min(dragOffset, 400) / 2000)

            if let h = hud {
                LevelHUD(icon: h.icon, level: h.level).transition(.opacity)
            }

            if chrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .statusBar(hidden: !chrome)
        .onAppear {
            prefetchNeighbors()
            if let p = current { ViewedStore.shared.markViewed(p) }
        }
        .onChange(of: index) { _ in
            prefetchNeighbors()
            if let p = current { ViewedStore.shared.markViewed(p) }
            if !slideshow { Haptics.tap() }
        }
        .task(id: slideshow) {
            guard slideshow else { return }
            while !Task.isCancelled && slideshow {
                try? await Task.sleep(nanoseconds: UInt64(settings.slideshowInterval * 1_000_000_000))
                guard !Task.isCancelled, slideshow, !posts.isEmpty else { break }
                withAnimation { index = (index + 1) % posts.count }
            }
        }
        .sheet(isPresented: $showInfo) {
            if let p = current {
                InfoPanel(post: p, pixelSize: sizes[p.key] ?? p.pixelSize) { tag in
                    showInfo = false
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        AppRouter.shared.search(tag: tag, siteID: p.siteID)
                    }
                }
            }
        }
        .sheet(item: $collectionBatch) { CollectionPickerSheet(posts: $0.posts) }
    }

    // MARK: Gestures

    /// Decides once per drag what it controls: the edges adjust brightness (left) or volume
    /// (right); elsewhere a downward drag closes the viewer. Sideways drags stay with paging.
    var verticalDrag: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onChanged { v in
                let dx = v.translation.width, dy = v.translation.height
                if dragMode == .none {
                    guard abs(dy) > abs(dx) * 1.3 else { dragMode = .other; return }
                    let width = UIScreen.main.bounds.width
                    if v.startLocation.x < 44 {
                        dragMode = .brightness
                        startLevel = Double(UIScreen.main.brightness)
                    } else if v.startLocation.x > width - 44 {
                        dragMode = .volume
                        startLevel = Double(SystemVolume.shared.current)
                    } else if dy > 0 && !zoomed {
                        dragMode = .dismiss
                    } else {
                        dragMode = .other
                    }
                }
                switch dragMode {
                case .dismiss:
                    dragOffset = max(0, dy)
                case .brightness:
                    let level = min(1, max(0, startLevel - Double(dy) / 350))
                    UIScreen.main.brightness = CGFloat(level)
                    hud = ("sun.max.fill", level)
                case .volume:
                    let level = min(1, max(0, startLevel - Double(dy) / 350))
                    SystemVolume.shared.set(Float(level))
                    hud = ("speaker.wave.2.fill", level)
                default:
                    break
                }
            }
            .onEnded { v in
                if dragMode == .dismiss && (dragOffset > 140 || v.predictedEndTranslation.height > 400) {
                    dismiss()
                } else {
                    withAnimation(.spring()) { dragOffset = 0 }
                }
                dragMode = .none
                withAnimation(.easeOut.delay(0.6)) { hud = nil }
            }
    }

    // MARK: Bars

    var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)) }
                .accessibilityLabel("Close viewer")
            Text("\(index + 1) / \(posts.count)").font(.subheadline.monospacedDigit())
                .accessibilityIdentifier("viewerIndex")
            Spacer()
            Menu {
                ForEach([2, 3, 5, 8, 10, 15, 20, 30], id: \.self) { s in
                    Button {
                        settings.slideshowInterval = Double(s)
                    } label: {
                        if Int(settings.slideshowInterval) == s { Label("\(s) seconds", systemImage: "checkmark") } else { Text("\(s) seconds") }
                    }
                }
            } label: {
                Text("\(Int(settings.slideshowInterval))s").font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .overlay(Capsule().stroke(Color.white.opacity(0.6)))
            }
            .accessibilityLabel("Slideshow interval \(Int(settings.slideshowInterval)) seconds")
            Button { slideshow.toggle(); Haptics.tap() } label: {
                Image(systemName: slideshow ? "pause.circle.fill" : "play.circle").font(.title3)
            }
            .accessibilityLabel(slideshow ? "Pause slideshow" : "Start slideshow")
            if !settings.verticalReading {
                Button { settings.viewerAspect = settings.viewerAspect.next; Haptics.tap() } label: {
                    Text(settings.viewerAspect.label).font(.caption.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .overlay(Capsule().stroke(Color.white.opacity(0.6)))
                }
                .accessibilityLabel("Image size \(settings.viewerAspect.label)")
            }
            Button { settings.verticalReading.toggle(); Haptics.tap() } label: {
                Image(systemName: settings.verticalReading ? "rectangle.split.1x2.fill" : "rectangle.split.1x2").font(.title3)
            }
            .accessibilityLabel(settings.verticalReading ? "Vertical reading on" : "Vertical reading off")
            Button { showInfo = true } label: { Image(systemName: "info.circle").font(.title3) }
                .accessibilityLabel("Info")
        }
        .foregroundColor(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .padding(.top, 34)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    }

    var bottomBar: some View {
        HStack {
            if let p = current {
                Button { store.toggleFavorite(p) } label: {
                    Image(systemName: store.isFavorite(p) ? "heart.fill" : "heart")
                        .foregroundColor(store.isFavorite(p) ? .pink : .white)
                }
                .accessibilityLabel(store.isFavorite(p) ? "Unfavorite" : "Favorite")
                Spacer()
                if !isLocal {
                    Button { Task { await DownloadManager.shared.enqueue([p]) } } label: { Image(systemName: "arrow.down.circle") }
                        .accessibilityLabel("Download")
                    Spacer()
                }
                if AdapterRegistry.shared.adapter(for: p.siteID)?.supportsVoting == true {
                    VoteButton(post: p)
                    Spacer()
                }
                Button { collectionBatch = PostBatch(posts: [p]) } label: { Image(systemName: "folder.badge.plus") }
                    .accessibilityLabel("Add to collection")
                Spacer()
                Button { Presenter.share([p.mediaURL]) } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share")
                Spacer()
                Menu {
                    if p.mediaType != .video {
                        Button { Task { await ImageClipboard.copy(p) } } label: { Label("Copy Image", systemImage: "photo.on.rectangle") }
                    }
                    Button {
                        UIPasteboard.general.string = p.mediaURL.absoluteString
                        ToastCenter.shared.show("URL copied")
                    } label: { Label("Copy Media URL", systemImage: "doc.on.doc") }
                    if let s = p.sourceURL {
                        Button { UIPasteboard.general.string = s.absoluteString; ToastCenter.shared.show("Source URL copied") }
                            label: { Label("Copy Source URL", systemImage: "link") }
                        Button { UIApplication.shared.open(s) } label: { Label("Open Source", systemImage: "safari") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
            }
        }
        .font(.title2)
        .foregroundColor(.white)
        .padding(.horizontal, 28).padding(.vertical, 14)
        .padding(.bottom, 20)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    func prefetchNeighbors() {
        guard !posts.isEmpty else { return }
        let range = max(0, index - 2)...min(posts.count - 1, index + 2)
        let urls = range.filter { $0 != index }.map { posts[$0] }.filter { $0.mediaType != .video }.map { $0.mediaURL }
        ImagePipeline.shared.prefetch(urls, client: current.flatMap { AdapterRegistry.shared.adapter(for: $0.siteID)?.client })
    }
}

/// One page of the viewer.
struct ViewerPage: View {
    let post: Post
    let isActive: Bool
    let isNear: Bool
    var aspect: ViewerAspect = .fit
    var showControls: Bool = true
    var onZoom: (Bool) -> Void
    var onTap: () -> Void
    var onSize: (CGSize) -> Void

    var body: some View {
        Group {
            if !isNear {
                Color.black
            } else if post.mediaType == .video {
                MediaVideoView(url: post.mediaURL, isActive: isActive, showControls: showControls, siteID: post.siteID)
            } else {
                FullImagePage(post: post, aspect: aspect, onZoom: onZoom, onTap: onTap, onSize: onSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct FullImagePage: View {
    let post: Post
    var aspect: ViewerAspect = .fit
    var onZoom: (Bool) -> Void
    var onTap: () -> Void
    var onSize: (CGSize) -> Void
    @StateObject private var model = ImageLoadModel()

    var body: some View {
        ZStack {
            if let img = model.image {
                ZoomableImageView(image: img, aspect: aspect, onZoomChange: onZoom, onSingleTap: onTap)
                    .accessibilityIdentifier("viewerImage")
            } else {
                CachedAsyncImage(url: post.thumbnailURL, maxPixel: 600, contentMode: .scaleAspectFit)
                    .opacity(0.6)
                if let e = model.error {
                    VStack(spacing: 10) {
                        Text(e).foregroundColor(.white).multilineTextAlignment(.center).font(.footnote)
                        Button("Retry") { Task { await load(force: true) } }.buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.7)))
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: post.mediaURL) { await load(force: false) }
    }

    func load(force: Bool) async {
        let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
        await model.load(post.mediaURL, maxPixel: 4096, animate: true, client: client, onLoad: { img in
            onSize(CGSize(width: img.size.width * img.scale, height: img.size.height * img.scale))
        }, force: force)
    }
}
