import SwiftUI

/// Full-screen viewer. Swipe left/right between posts; pinch or double-tap to zoom;
/// single tap toggles the controls. Neighbors within 2 positions are preloaded.
struct ViewerView: View {
    /// Grows when `source` loads more results while you swipe toward the end.
    @State private var posts: [Post]
    var isLocal: Bool = false
    /// The search the posts came from (Browse): swiping near the end loads its next page.
    private let source: SearchTabModel?
    private let startKey: String?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = LibraryStore.shared
    @State private var index: Int
    @State private var chrome = true
    @State private var zoomed = false
    @State private var slideshow = false
    @ObservedObject private var activity = VideoActivity.shared
    @State private var autoHidOnIndex: Int?
    /// Slideshow in random order (remembered), and the posts it has shown this round.
    @AppStorage("slideshowShuffle") private var slideshowShuffle = false
    @State private var shuffleSeen: Set<Int> = []
    @State private var showInfo = false
    @State private var collectionBatch: PostBatch?
    @State private var reverseFor: PostBatch?
    @State private var quickHide: PostBatch?
    @State private var editing: PostBatch?
    @State private var archivePage: AccountView.WebPageRequest?
    @State private var betterFor: PostBatch?
    @ObservedObject private var dominant = DominantColors.shared
    @State private var sizes: [String: CGSize] = [:]
    // Vertical drag: swipe down to close; left edge = brightness, right edge = volume.
    @State private var dragMode: ViewerDragMode = .none
    @State private var dragOffset: CGFloat = 0
    @State private var startLevel: Double = 0
    @State private var hud: (icon: String, level: Double)?

    init(posts: [Post], startIndex: Int, isLocal: Bool = false, source: SearchTabModel? = nil) {
        _posts = State(initialValue: posts)
        self.isLocal = isLocal
        self.source = source
        let start = min(max(0, startIndex), max(0, posts.count - 1))
        _index = State(initialValue: start)
        startKey = posts.indices.contains(start) ? posts[start].key : nil
    }

    /// Near the last loaded post: fetch the search's next page and add the new posts at the
    /// end, so swiping keeps going past what the grid had loaded. Not in right-to-left or
    /// two-page mode, where adding posts would move every page under your finger.
    private func loadMoreIfNeeded() {
        guard let s = source, !settings.readingRTL, !spreads, index >= posts.count - 4,
              s.hasNext, !s.isLoading else { return }
        Task {
            await s.loadMore()
            let have = Set(posts.map(\.key))
            let new = s.visiblePosts(blacklist: settings.blacklistSet).filter { !have.contains($0.key) }
            if !new.isEmpty { posts.append(contentsOf: new) }
        }
    }

    var current: Post? { posts.indices.contains(index) ? posts[index] : nil }

    var body: some View {
        ZStack {
            ViewerBackdrop(style: settings.viewerBackground, color: current.flatMap { dominant.colors[$0.key] }).opacity(1 - Double(min(dragOffset, 400)) / 600).ignoresSafeArea()
            Group {
                if settings.verticalReading {
                    VerticalReader(posts: posts, startIndex: index, index: $index,
                                   onOpenPaged: { i in settings.verticalReading = false; index = i },
                                   onTap: { withAnimation { chrome.toggle() } })
                } else {
                    pager
                        .simultaneousGesture(verticalDrag)
                }
            }
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .scaleEffect(1 - min(dragOffset, 400) / 2000)

            if let h = hud {
                LevelHUD(icon: h.icon, level: h.level).transition(.opacity)
            }

            // e.g. "Source deleted. Showing cached preview."
            if let notice = current?.metadata["notice"] {
                VStack {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                        .foregroundColor(.black)
                        .padding(.top, chrome ? 150 : 60)
                        .accessibilityIdentifier("viewerNotice")
                    Spacer()
                }
                .allowsHitTesting(false)
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
        .onDisappear {
            ViewedStore.shared.holdChanges = false
            VideoActivity.shared.reset()
            NotificationCenter.default.post(name: VideoActivity.viewerClosed, object: nil)
            if settings.rotationLock != "auto" { OrientationLock.apply("auto") }
            // Swiped to another post: the grid scrolls to it when the viewer closes.
            if let k = current?.key, k != startKey { ViewerReturn.shared.closed(on: k) }
        }
        .statusBar(hidden: !chrome)
        .modifier(HideHomeIndicator(hidden: !chrome))
        .onAppear {
            // Wait for the full-screen presentation to finish: a rotation requested while it's
            // still animating in is dropped by iOS.
            if settings.rotationLock != "auto" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { OrientationLock.apply(settings.rotationLock) }
            }
            prefetchNeighbors()
            ViewedStore.shared.holdChanges = true
            if let p = current, source?.isPrivate != true { ViewedStore.shared.markViewed(p); RecentlyViewedStore.shared.record(p) }
        }
        .onChange(of: index) { _ in
            prefetchNeighbors()
            loadMoreIfNeeded()
            if let p = current, source?.isPrivate != true { ViewedStore.shared.markViewed(p); RecentlyViewedStore.shared.record(p) }
            if !slideshow { Haptics.tap() }
        }
        // A playing video: the controls step aside after 3 s (a tap brings them back).
        .task(id: "\(chrome)-\(activity.playing)-\(activity.scrubbing)-\(index)-\(showInfo)") {
            // Once per post: controls you bring back with a tap stay until you hide them
            // (so a menu opened from them isn't closed under your finger).
            guard settings.autoHideVideoControls, chrome, activity.playing, !activity.scrubbing,
                  current?.mediaType == .video, !showInfo, autoHidOnIndex != index else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, chrome, activity.playing, !activity.scrubbing, !showInfo else { return }
            autoHidOnIndex = index
            withAnimation { chrome = false }
        }
        .task(id: slideshow) {
            guard slideshow else { return }
            while !Task.isCancelled && slideshow {
                try? await Task.sleep(nanoseconds: UInt64(settings.slideshowInterval * 1_000_000_000))
                guard !Task.isCancelled, slideshow, !posts.isEmpty else { break }
                if slideshowShuffle, posts.count > 2 {
                    // Random order without repeats until every post has been shown once.
                    if shuffleSeen.count >= posts.count - 1 { shuffleSeen = [] }
                    shuffleSeen.insert(index)
                    let left = posts.indices.filter { !shuffleSeen.contains($0) }
                    if let next = left.randomElement() { index = next }
                } else {
                    withAnimation { index = (index + 1) % posts.count }
                }
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
        .sheet(item: $reverseFor) { ReverseSearchSheet(post: $0.posts[0]) }
        .sheet(item: $quickHide) { QuickHideSheet(post: $0.posts[0]) }
        .sheet(item: $editing) { MediaEditorView(post: $0.posts[0]) }
        .sheet(item: $archivePage) { ThemedWebPage(url: $0.url, prefillUsername: "") }
        .sheet(item: $betterFor) { b in BetterVersionSheet(post: b.posts[0], currentSize: sizes[b.posts[0].key]) }
    }

    /// The horizontal pager: one post per page, or two side by side in landscape.
    @ViewBuilder var pager: some View {
        // Right-to-left: the pages are laid out in reverse, so the next post is on
        // the left. (Mirroring the layout instead would also mirror the zoom views.)
        if spreads {
            // Landscape: two posts side by side, like an open book.
            TabView(selection: spreadSelection) {
                ForEach(0..<spreadCount, id: \.self) { slot in
                    let sp = settings.readingRTL ? spreadCount - 1 - slot : slot
                    let pair = [sp * 2, sp * 2 + 1].filter { posts.indices.contains($0) }
                    HStack(spacing: 2) {
                        ForEach(settings.readingRTL ? pair.reversed() : pair, id: \.self) { i in page(i) }
                    }
                    .tag(slot)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .id("spreads-\(settings.readingRTL)")
        } else {
            TabView(selection: pagerSelection) {
                ForEach(posts.indices, id: \.self) { slot in
                    page(postIndex(atSlot: slot)).tag(slot)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .id(settings.readingRTL)
        }
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Two-page spreads: on, sideways, and more than one post.
    var spreads: Bool { settings.twoPageLandscape && verticalSizeClass == .compact && posts.count > 1 }
    var spreadCount: Int { (posts.count + 1) / 2 }

    var spreadSelection: Binding<Int> {
        Binding(get: { settings.readingRTL ? spreadCount - 1 - index / 2 : index / 2 },
                set: { slot in index = (settings.readingRTL ? spreadCount - 1 - slot : slot) * 2 })
    }

    func page(_ i: Int) -> some View {
        ViewerPage(post: posts[i], isActive: i == index, isNear: abs(i - index) <= 2,
                   aspect: settings.viewerAspect, showControls: chrome,
                   onFinished: { if i == index { advance() } },
                   onZoom: { zoomed = $0 },
                   onTap: handleTap,
                   onDoubleTap: handleDoubleTap,
                   onSize: { sizes[posts[i].key] = $0 })
    }

    /// Pager position ↔ post index (reversed in right-to-left mode).
    func postIndex(atSlot slot: Int) -> Int { settings.readingRTL ? posts.count - 1 - slot : slot }

    var pagerSelection: Binding<Int> {
        Binding(get: { postIndex(atSlot: index) }, set: { index = postIndex(atSlot: $0) })
    }

    /// Next post; after the last one, back to the first.
    func advance() {
        guard !posts.isEmpty else { return }
        withAnimation { index = (index + 1) % posts.count }
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
                    // A gallery scrolls vertically itself: no dismiss / edge sliders there.
                    if current?.isGallery == true { dragMode = .other; return }
                    let width = UIScreen.main.bounds.width
                    if v.startLocation.x < 44 && settings.edgeSwipes {
                        dragMode = .brightness
                        startLevel = Double(UIScreen.main.brightness)
                    } else if v.startLocation.x > width - 44 && settings.edgeSwipes {
                        dragMode = .volume
                        startLevel = Double(SystemVolume.shared.current)
                        SystemVolume.shared.begin()
                    } else if dy > 0 && !zoomed && settings.swipeDownAction == "close" {
                        dragMode = .dismiss
                    } else {
                        dragMode = .other
                    }
                }
                switch dragMode {
                case .dismiss:
                    dragOffset = max(0, dy)
                case .brightness:
                    // Relative to where the drag began: the full screen height is 100%.
                    let level = min(1, max(0, startLevel - Double(dy) / Double(UIScreen.main.bounds.height)))
                    UIScreen.main.brightness = CGFloat(level)
                    hud = ("sun.max.fill", level)
                case .volume:
                    let level = min(1, max(0, startLevel - Double(dy) / Double(UIScreen.main.bounds.height)))
                    SystemVolume.shared.set(Float(level))
                    hud = ("speaker.wave.2.fill", level)
                default:
                    break
                }
            }
            .onEnded { v in
                // Swipe up on a post: the action chosen in Settings › Gestures.
                if dragMode == .other, !zoomed, v.translation.height < -110,
                   abs(v.translation.width) < abs(v.translation.height) * 0.6, let p = current, !p.isGallery {
                    perform(settings.swipeUpAction, on: p)
                }
                if dragMode == .dismiss && (dragOffset > 140 || v.predictedEndTranslation.height > 400) {
                    dismiss()
                } else {
                    withAnimation(.spring()) { dragOffset = 0 }
                }
                if dragMode == .volume { SystemVolume.shared.end() }
                dragMode = .none
                withAnimation(.easeOut.delay(0.6)) { hud = nil }
            }
    }

    // MARK: Bars

    var topBar: some View {
        let inBar = ViewerButton.allCases.filter { settings.showsInToolbar($0) }
        let inMenu = ViewerButton.allCases.filter { !settings.showsInToolbar($0) }
        return HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)) }
                .accessibilityLabel("Close viewer")
            // Tap the counter to jump: back to where you started, the first or the last post.
            Menu {
                if let k = startKey, let i = posts.firstIndex(where: { $0.key == k }), i != index {
                    Button { index = i } label: { Label("Back to Where I Started (\(i + 1))", systemImage: "arrow.uturn.backward") }
                }
                if index != 0 {
                    Button { index = 0 } label: { Label("First Post", systemImage: "backward.end") }
                }
                if index != posts.count - 1 {
                    Button { index = posts.count - 1 } label: { Label("Last Loaded Post (\(posts.count))", systemImage: "forward.end") }
                }
            } label: {
                Text("\(index + 1) / \(posts.count)").font(.subheadline.monospacedDigit())
                    .lineLimit(1).fixedSize()
                    .foregroundColor(.white)
            }
            .disabled(posts.count < 2)
            .accessibilityIdentifier("viewerIndex")
            .accessibilityHint("Shows ways to jump to another post")
            Spacer(minLength: 4)
            ForEach(inBar) { barButton($0) }
            if !inMenu.isEmpty {
                Menu {
                    ForEach(inMenu) { menuItem($0) }
                } label: { Image(systemName: "slider.horizontal.3").font(.title3) }
                .accessibilityLabel("More viewer options")
            }
            Button { showInfo = true } label: { Image(systemName: "info.circle").font(.title3) }
                .accessibilityLabel("Info")
        }
        .foregroundColor(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .padding(.top, 34)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder var intervalChoices: some View {
        ForEach([2, 3, 5, 8, 10, 15, 20, 30], id: \.self) { s in
            Button {
                settings.slideshowInterval = Double(s)
            } label: {
                if Int(settings.slideshowInterval) == s { Label("\(s) seconds", systemImage: "checkmark") } else { Text("\(s) seconds") }
            }
        }
        Divider()
        Button { slideshowShuffle.toggle(); shuffleSeen = [] } label: {
            if slideshowShuffle { Label("Shuffle", systemImage: "checkmark") } else { Label("Shuffle", systemImage: "shuffle") }
        }
    }

    /// One top-bar button.
    @ViewBuilder
    func barButton(_ b: ViewerButton) -> some View {
        switch b {
        case .interval:
            Menu { intervalChoices } label: {
                Text("\(Int(settings.slideshowInterval))s").font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .overlay(Capsule().stroke(Color.white.opacity(0.6)))
                    .fixedSize()
            }
            .accessibilityLabel("Slideshow interval \(Int(settings.slideshowInterval)) seconds")
        case .advance:
            Button(action: toggleAdvance) {
                Image(systemName: settings.autoAdvance ? "forward.end.alt.fill" : "repeat.1").font(.title3)
            }
            .accessibilityLabel(settings.autoAdvance ? "End of media: auto-advance" : "End of media: loop")
        case .slideshow:
            Button { slideshow.toggle(); Haptics.tap() } label: {
                Image(systemName: slideshow ? "pause.circle.fill" : "play.circle").font(.title3)
            }
            .accessibilityLabel(slideshow ? "Pause slideshow" : "Start slideshow")
        case .aspect:
            if !settings.verticalReading {
                Button { settings.viewerAspect = settings.viewerAspect.next; Haptics.tap() } label: {
                    Text(settings.viewerAspect.label).font(.caption.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .overlay(Capsule().stroke(Color.white.opacity(0.6)))
                        .fixedSize()
                }
                .accessibilityLabel("Image size \(settings.viewerAspect.label)")
            }
        case .vertical:
            Button { settings.verticalReading.toggle(); Haptics.tap() } label: {
                Image(systemName: settings.verticalReading ? "rectangle.split.1x2.fill" : "rectangle.split.1x2").font(.title3)
            }
            .accessibilityLabel(settings.verticalReading ? "Vertical reading on" : "Vertical reading off")
        case .direction:
            Button(action: toggleDirection) {
                Text(settings.readingRTL ? "RTL" : "LTR").font(.caption.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .overlay(Capsule().stroke(Color.white.opacity(0.6)))
                    .fixedSize()
            }
            .accessibilityLabel(settings.readingRTL ? "Reading direction right to left" : "Reading direction left to right")
        case .tapZones:
            Button(action: toggleTapZones) {
                Image(systemName: settings.tapZones ? "hand.tap.fill" : "hand.tap").font(.title3)
            }
            .accessibilityLabel(settings.tapZones ? "Tap edges to turn: on" : "Tap edges to turn: off")
        case .rotation:
            Button(action: toggleRotation) {
                Image(systemName: settings.rotationLock == "auto" ? "lock.rotation.open" : "lock.rotation").font(.title3)
            }
            .accessibilityLabel(OrientationLock.label(settings.rotationLock))
        case .background:
            Button { settings.cycleViewerBackground(); Haptics.tap() } label: { Image(systemName: "circle.lefthalf.filled").font(.title3) }
                .accessibilityLabel("Background \(settings.viewerBackground)")
        }
    }

    /// The same control as an entry of the ⋯ menu, with its current state in words.
    @ViewBuilder
    func menuItem(_ b: ViewerButton) -> some View {
        switch b {
        case .interval:
            Menu { intervalChoices } label: { Label("Slideshow every \(Int(settings.slideshowInterval)) s", systemImage: b.icon) }
        case .advance:
            Button(action: toggleAdvance) { Label(settings.autoAdvance ? "End of media: auto-advance" : "End of media: loop", systemImage: settings.autoAdvance ? "forward.end.alt" : "repeat.1") }
        case .slideshow:
            Button { slideshow.toggle() } label: { Label(slideshow ? "Pause slideshow" : "Start slideshow", systemImage: slideshow ? "pause.circle" : "play.circle") }
        case .aspect:
            Button { settings.viewerAspect = settings.viewerAspect.next } label: { Label("Image size: \(settings.viewerAspect.label)", systemImage: b.icon) }
        case .vertical:
            Button { settings.verticalReading.toggle() } label: { Label(settings.verticalReading ? "Vertical reading: on" : "Vertical reading: off", systemImage: b.icon) }
        case .direction:
            Button(action: toggleDirection) { Label(settings.readingRTL ? "Direction: right to left" : "Direction: left to right", systemImage: b.icon) }
        case .tapZones:
            Button(action: toggleTapZones) { Label(settings.tapZones ? "Tap edges to turn: on" : "Tap edges to turn: off", systemImage: b.icon) }
        case .rotation:
            Button(action: toggleRotation) { Label(OrientationLock.label(settings.rotationLock), systemImage: settings.rotationLock == "auto" ? "lock.rotation.open" : "lock.rotation") }
        case .background:
            Button { settings.cycleViewerBackground() } label: { Label("Background: \(settings.viewerBackground)", systemImage: b.icon) }
        }
    }

    func toggleAdvance() {
        settings.autoAdvance.toggle(); Haptics.tap()
        ToastCenter.shared.show(settings.autoAdvance ? "Auto-advance: videos and GIFs move on when done, pictures after \(Int(settings.slideshowInterval)) s" : "Loop: each post repeats")
    }

    func toggleDirection() {
        settings.readingRTL.toggle(); Haptics.tap()
        ToastCenter.shared.show(settings.readingRTL ? "Right to left: swipe right for the next post" : "Left to right: swipe left for the next post")
    }

    func toggleTapZones() {
        settings.tapZones.toggle(); Haptics.tap()
        ToastCenter.shared.show(settings.tapZones ? "Tap the left or right edge of a picture to turn the page" : "Tapping a picture shows or hides the controls")
    }

    func toggleRotation() {
        settings.rotationLock = OrientationLock.toggled(from: settings.rotationLock)
        OrientationLock.apply(settings.rotationLock)
        Haptics.tap()
        ToastCenter.shared.show(OrientationLock.label(settings.rotationLock))
    }

    /// Double tap: zoom (handled by the picture itself) or the action chosen in Settings.
    func handleDoubleTap() -> Bool {
        guard settings.doubleTapAction != "zoom", let p = current else { return false }
        perform(settings.doubleTapAction, on: p)
        return true
    }

    /// Runs a remappable gesture action.
    func perform(_ action: String, on p: Post) {
        switch action {
        case "hide": quickHide = PostBatch(posts: [p])
        case "info": showInfo = true
        case "favorite": store.toggleFavorite(p); Haptics.tap()
        case "download": Task { await DownloadManager.shared.enqueue([p]) }; ToastCenter.shared.show("Downloading")
        case "readLater": ReadLaterStore.shared.toggle(p)
        case "wifiDownload": WifiDownloadQueue.shared.add([p])
        case "next": advance()
        case "close": dismiss()
        default: break
        }
    }

    /// A tap on a picture: with tap zones on, the outer 30% on each side turns the page
    /// (mirrored in right-to-left mode); otherwise it shows or hides the controls.
    func handleTap(_ x: CGFloat) {
        guard settings.tapZones, !zoomed, x < 0.3 || x > 0.7 else {
            withAnimation { chrome.toggle() }
            return
        }
        let forward = (x > 0.7) != settings.readingRTL
        let step = spreads ? 2 : 1
        let target = (spreads ? index / 2 * 2 : index) + (forward ? step : -step)
        guard posts.indices.contains(target) else {
            ToastCenter.shared.show(forward ? "Last post" : "First post")
            return
        }
        withAnimation { index = target }
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
                    if !isLocal, let page = PostLinks.pageURL(p) {
                        // In MediaDeck's own browser (comments, notes, related posts), not Safari.
                        Button { archivePage = AccountView.WebPageRequest(url: page) } label: { Label("Open Post Page", systemImage: "globe") }
                        Button { UIPasteboard.general.string = page.absoluteString; ToastCenter.shared.show("Post link copied") }
                            label: { Label("Copy Post Link", systemImage: "link.badge.plus") }
                    }
                    if !isLocal {
                        Button { UIPasteboard.general.string = PostLinks.appLink(p).absoluteString; ToastCenter.shared.show("MediaDeck link copied") }
                            label: { Label("Copy MediaDeck Link", systemImage: "arrow.up.forward.app") }
                    }
                    if let s = p.sourceURL {
                        Button { UIPasteboard.general.string = s.absoluteString; ToastCenter.shared.show("Source URL copied") }
                            label: { Label("Copy Source URL", systemImage: "link") }
                        Button { UIApplication.shared.open(s) } label: { Label("Open Source", systemImage: "safari") }
                    }
                    if !isLocal {
                        Button { WifiDownloadQueue.shared.add([p]) } label: {
                            Label(WifiDownloadQueue.shared.contains(p) ? "Waiting for Wi-Fi" : "Download on Wi-Fi", systemImage: "wifi")
                        }
                        .disabled(WifiDownloadQueue.shared.contains(p))
                    }
                    Divider()
                    Button { ReadLaterStore.shared.toggle(p) } label: {
                        ReadLaterStore.shared.contains(p) ? Label("Remove from Read Later", systemImage: "bookmark.slash")
                            : Label("Read Later", systemImage: "bookmark")
                    }
                    Button { reverseFor = PostBatch(posts: [p]) } label: { Label("Reverse Search", systemImage: "magnifyingglass.circle") }
                    if p.mediaType != .video {
                        Button { betterFor = PostBatch(posts: [p]) } label: { Label("Find Better Version", systemImage: "arrow.up.forward.app") }
                    }
                    Button { quickHide = PostBatch(posts: [p]) } label: { Label("Hide Posts Like This…", systemImage: "eye.slash") }
                    if !isLocal {
                        Button { settings.hidePost(p) } label: { Label("Hide This Post", systemImage: "eye.slash.circle") }
                    }
                    if p.isGallery {
                        Divider()
                        Button { Task { await CBZExporter.export(p) } } label: { Label("Save as CBZ", systemImage: "archivebox") }
                        if let u = ExternalArchive.url(for: p) {
                            Button { archivePage = AccountView.WebPageRequest(url: u) } label: {
                                Label("Generate External Archive", systemImage: "globe")
                            }
                        }
                    }
                    if p.mediaType == .image {
                        Button { editing = PostBatch(posts: [p]) } label: { Label("Edit Picture…", systemImage: "slider.horizontal.below.rectangle") }
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

    /// Fetches the neighbours' pictures ahead of time: the same file each page will show
    /// (the smaller one with Data Saver, Wi-Fi only or Prefer Lighter), never while the
    /// current post is a video (it needs the bandwidth), and not galleries' extra pages.
    func prefetchNeighbors() {
        guard !posts.isEmpty, !settings.savingPower, current?.mediaType != .video else { return }
        let range = max(0, index - 2)...min(posts.count - 1, index + 2)
        let urls = range.filter { $0 != index }.map { posts[$0] }.filter { $0.mediaType != .video }.map(FullImagePage.defaultURL)
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
    var onFinished: () -> Void = {}
    var onZoom: (Bool) -> Void
    /// Horizontal tap position 0…1 (0.5 when unknown).
    var onTap: (CGFloat) -> Void
    var onDoubleTap: () -> Bool = { false }
    var onSize: (CGSize) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var videoAllowed = false
    /// Chosen on the mobile-data screen: play the site's smaller video instead.
    @State private var lighterVideo: URL?
    @State private var fullSize: Int64?
    @State private var lighterSize: Int64?

    /// The site's smaller version, when it is a video too (some sites give a still there).
    var lighterVideoURL: URL? {
        guard let s = post.sampleURL, s != post.mediaURL,
              ["mp4", "webm", "mov", "m4v", "m3u8"].contains(s.pathExtension.lowercased()) else { return nil }
        return s
    }

    var body: some View {
        Group {
            if !isNear {
                Color.clear
            } else if post.isGallery {
                GalleryPage(post: post, isActive: isActive, onTap: { onTap(0.5) }, onFinished: onFinished)
            } else if post.mediaType == .video && settings.mediaWaitsForWiFi && !videoAllowed {
                // Wi-Fi only: a still and buttons (with the file sizes) instead of streaming on mobile data.
                ZStack {
                    CachedAsyncImage(url: post.thumbnailURL, maxPixel: 900, contentMode: .scaleAspectFit)
                    VStack(spacing: 10) {
                        Button { videoAllowed = true } label: {
                            Label("Play on Mobile Data" + (fullSize.map { " · " + ProxyProgress.mb($0) } ?? ""), systemImage: "play.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(Color.black.opacity(0.65)))
                                .foregroundColor(.white)
                        }
                        .accessibilityIdentifier("playOnMobileData")
                        if let light = lighterVideoURL {
                            Button { lighterVideo = light; videoAllowed = true } label: {
                                Label("Play Lighter Version" + (lighterSize.map { " · " + ProxyProgress.mb($0) } ?? ""), systemImage: "leaf.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Capsule().fill(Color.black.opacity(0.65)))
                                    .foregroundColor(.white)
                            }
                            .accessibilityIdentifier("playLighterOnMobileData")
                        }
                    }
                }
                .task(id: post.key) {
                    // Only the pages near the current one ask, and only the size (a HEAD request).
                    fullSize = await MediaSize.shared.size(of: post.mediaURL, siteID: post.siteID)
                    if let light = lighterVideoURL { lighterSize = await MediaSize.shared.size(of: light, siteID: post.siteID) }
                }
            } else if post.mediaType == .video {
                MediaVideoView(url: lighterVideo ?? post.mediaURL, isActive: isActive, showControls: showControls, siteID: post.siteID,
                               onFinished: onFinished, onTap: { onTap(0.5) })
            } else {
                FullImagePage(post: post, aspect: aspect, isActive: isActive, onFinished: onFinished,
                              onZoom: onZoom, onTap: onTap, onDoubleTap: onDoubleTap, onSize: onSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FullImagePage: View {
    let post: Post
    var aspect: ViewerAspect = .fit
    var isActive: Bool = false
    var onFinished: () -> Void = {}
    @ObservedObject private var settings = AppSettings.shared
    var onZoom: (Bool) -> Void
    var onTap: (CGFloat) -> Void
    var onDoubleTap: () -> Bool = { false }
    var onSize: (CGSize) -> Void
    @StateObject private var model = ImageLoadModel()
    /// Data Saver: the user asked for the original of this post.
    @State private var wantsFull = false

    /// The address shown: with Data Saver on, the smaller version until Load Full Resolution.
    var shownURL: URL { wantsFull ? Self.fullURL(post) : Self.defaultURL(post) }

    /// What a page shows before Load Full Resolution (also what the viewer prefetches).
    static func defaultURL(_ post: Post) -> URL {
        let settings = AppSettings.shared
        if settings.mediaWaitsForWiFi { return post.thumbnailURL }
        if settings.dataSaverActive { return post.sampleURL ?? post.thumbnailURL }
        return fullURL(post)
    }

    static func fullURL(_ post: Post) -> URL {
        AppSettings.shared.viewerPrefersLighter ? (post.sampleURL ?? post.mediaURL) : post.mediaURL
    }

    var body: some View {
        ZStack {
            if let img = model.image {
                ZoomableImageView(image: img, aspect: aspect, onZoomChange: onZoom, onSingleTap: onTap, onDoubleTap: onDoubleTap)
                    .accessibilityIdentifier("viewerImage")
                if shownURL != post.mediaURL && (settings.dataSaverActive || settings.mediaWaitsForWiFi) && !wantsFull {
                    VStack {
                        Spacer()
                        Button { wantsFull = true } label: {
                            Label(settings.mediaWaitsForWiFi ? "Load on Mobile Data" : "Load Full Resolution",
                                  systemImage: settings.mediaWaitsForWiFi ? "antenna.radiowaves.left.and.right" : "arrow.up.left.and.arrow.down.right")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(Color.black.opacity(0.65)))
                                .foregroundColor(.white)
                        }
                        .accessibilityIdentifier("loadFullResolution")
                        .padding(.bottom, 110)
                    }
                }
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
        .task(id: shownURL) { await load(force: false) }
        // Auto-advance: a GIF moves on after one full cycle, a still picture after the interval.
        .task(id: "\(isActive)-\(settings.autoAdvance)-\(model.image != nil)") {
            guard isActive, settings.autoAdvance, let img = model.image else { return }
            let seconds = img.images != nil ? max(img.duration, 0.5) : settings.slideshowInterval
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled && isActive && settings.autoAdvance { onFinished() }
        }
    }

    func load(force: Bool) async {
        let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
        // Prefer lighter: the site's medium-size file when there is one.
        let url = shownURL
        let key = post.key
        await model.load(url, maxPixel: 4096, animate: true, client: client, onLoad: { img in
            onSize(CGSize(width: img.size.width * img.scale, height: img.size.height * img.scale))
            DominantColors.shared.compute(for: key, image: img)
        }, force: force)
    }
}

/// Tells the grid which post the viewer closed on, so it can bring that post into view.
@MainActor
final class ViewerReturn: ObservableObject {
    static let shared = ViewerReturn()
    struct Landing: Equatable { let key: String; let id = UUID() }
    @Published private(set) var landing: Landing?
    func closed(on key: String) { landing = Landing(key: key) }
}

/// Addresses for a post outside the app.
enum PostLinks {
    /// The post's web page, when the site's post address is its JSON twin
    /// (posts/{id}.json → posts/{id}, as on Danbooru-style sites). Nil otherwise.
    static func pageURL(_ post: Post) -> URL? {
        guard let c = AdapterRegistry.shared.config(for: post.siteID) else { return nil }
        let path = c.postPath.trimmingCharacters(in: .whitespaces)
        guard let r = path.range(of: ".json"), path[r.upperBound...].first.map({ $0 == "?" }) ?? true else { return nil }
        // The ID has to be in the part kept (post.json?tags=id:{id} would give the list page).
        let kept = String(path[..<r.lowerBound])
        guard kept.contains("{id}") else { return nil }
        let page = kept.replacingOccurrences(of: "{id}", with: post.id)
        // Built the same way the adapter builds its own addresses.
        let full = page.lowercased().hasPrefix("http") ? page : GenericAdapter.join(c.baseURL.absoluteString, page)
        guard let url = URL(string: full), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// mediadeck://post?id=…&site=… (opens this post in MediaDeck; see "Links that open MediaDeck").
    static func appLink(_ post: Post) -> URL {
        var c = URLComponents()
        c.scheme = "mediadeck"; c.host = "post"
        c.queryItems = [URLQueryItem(name: "id", value: post.id), URLQueryItem(name: "site", value: post.siteID)]
        return c.url ?? URL(string: "mediadeck://post")!
    }
}
