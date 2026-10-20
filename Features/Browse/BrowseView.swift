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
    @State private var reviewing: EditRequest?
    @StateObject private var suggester = SuggestionModel()
    @State private var showJump = false
    @State private var builderFor: SearchTabModel?
    @State private var jumpText = ""
    @ObservedObject private var viewedStore = ViewedStore.shared
    @ObservedObject private var reviews = AdapterReviewStore.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar
                if !chipTags.isEmpty { chipRow }
                if searchFocused && !suggester.suggestions.isEmpty { suggestionList }
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
                ToolbarItem(placement: .principal) { siteTitle }
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
            .sheet(item: $builderFor, onDismiss: { searchText = model.current?.query ?? "" }) { QueryBuilderSheet(tab: $0) }
            .sheet(isPresented: $showJump) {
                NavigationView {
                    Form {
                        TextField("Page number", text: $jumpText)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("jumpPageField")
                        Button("Go") {
                            if let n = Int(jumpText), n >= 1, let t = model.current {
                                showJump = false
                                Task { await t.jump(to: n) }
                            }
                        }
                        .disabled(Int(jumpText) == nil)
                        .accessibilityIdentifier("jumpGo")
                    }
                    .keyboardDoneButton()
                    .navigationTitle("Go to Page")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showJump = false } } }
                }
            }
            .sheet(item: $reviewing) { req in
                NavigationView { AdapterEditorView(config: req.config, isNew: false, focus: req.focus) }
                    .interactiveDismissDisabled(true)
            }
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
        .onChange(of: registry.disabledIDs) { _ in model.ensureTab() }
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
                    .onSubmit { suggester.clear(); run(query: searchText, siteID: model.current?.siteID) }
                    .onChange(of: searchText) { suggester.update(text: $0, siteID: model.current?.siteID) }
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
            Button { randomize() } label: { Image(systemName: "dice") }
                .accessibilityLabel("Random results")
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

    /// Tags shown as pills: everything typed except the word still being typed.
    var chipTags: [String] {
        var tags = TagQuery.parse(searchText)
        if searchFocused && !searchText.hasSuffix(" ") && !tags.isEmpty { tags.removeLast() }
        return tags
    }

    var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(chipTags.enumerated()), id: \.offset) { i, tag in
                    let excluded = tag.hasPrefix("-")
                    HStack(spacing: 4) {
                        Text(excluded ? "− " + tag.dropFirst() : tag).font(.caption.weight(.medium))
                        Button { removeChip(at: i) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .accessibilityLabel("Remove tag \(tag)")
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(excluded ? Color.red.opacity(0.18) : Color.accentColor.opacity(0.18)))
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .accessibilityIdentifier("tagChips")
    }

    func removeChip(at index: Int) {
        var tags = TagQuery.parse(searchText)
        let typing = searchFocused && !searchText.hasSuffix(" ") && !tags.isEmpty ? tags.removeLast() : nil
        guard tags.indices.contains(index) else { return }
        tags.remove(at: index)
        searchText = (tags.map(TagQuery.display) + (typing.map { [$0] } ?? [])).joined(separator: " ")
        Haptics.tap()
        if typing == nil { run(query: searchText, siteID: model.current?.siteID) }
    }

    /// Dice: the site's own random sort if it has one, else its random tag.
    func randomize() {
        guard let t = model.current else { return }
        guard !t.isMerged, let cfg = registry.config(for: t.siteID) else {
            ToastCenter.shared.show("Pick a single site to get random results.")
            return
        }
        if let r = cfg.sortOptions.first(where: { $0.lowercased().contains("random") }) {
            t.sort = r
            t.saveSticky()
            Task { await t.search(recordHistory: false) }
            ToastCenter.shared.show("Sorted randomly")
        } else if let tag = cfg.randomTag?.nonEmpty {
            if !TagQuery.parse(searchText).contains(tag) { searchText = (searchText.trimmingCharacters(in: .whitespaces) + " " + tag).trimmingCharacters(in: .whitespaces) }
            run(query: searchText, siteID: t.siteID)
        } else {
            ToastCenter.shared.show("\(cfg.displayName) has no random option. Add a Sort choice containing 'random' or a Random tag in its adapter.", style: .error)
        }
    }

    var suggestionList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggester.suggestions, id: \.self) { s in
                    Button {
                        searchText = TagQuery.applySuggestion(s, to: searchText)
                        suggester.clear()
                        Haptics.tap()
                    } label: {
                        Label(s, systemImage: "text.badge.plus").font(.subheadline)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Suggestion \(s)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .accessibilityIdentifier("suggestions")
    }

    var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    TabChip(tab: tab, isSelected: tab.id == model.current?.id, canClose: model.tabs.count > 1,
                            reviewCount: reviewFields(tab.siteID).count,
                            onSelect: {
                                // Tapping the tab that's already open scrolls its grid to the top.
                                if tab.id == model.current?.id { tab.scrollToTopToken += 1 } else { model.selectedID = tab.id }
                            },
                            onClose: { model.close(tab) },
                            onReview: {
                                if let cfg = registry.config(for: tab.siteID) {
                                    reviewing = EditRequest(config: cfg, isNew: false, focus: reviewFields(tab.siteID).first)
                                }
                            })
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

    /// The site name; swipe it sideways to go to the next or previous site.
    var siteTitle: some View {
        HStack(spacing: 6) {
            if settings.swipeSites && registry.enabledConfigs.count > 1 {
                Image(systemName: "chevron.left").font(.caption2).foregroundColor(.secondary)
            }
            Text(model.current?.siteName ?? "Browse").font(.headline).lineLimit(1)
            if settings.swipeSites && registry.enabledConfigs.count > 1 {
                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in
            guard settings.swipeSites, abs(v.translation.width) > 40, abs(v.translation.width) > abs(v.translation.height) else { return }
            switchSite(by: v.translation.width < 0 ? 1 : -1)
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.current?.siteName ?? "Browse")
        .accessibilityHint(settings.swipeSites ? "Swipe left or right to switch sites" : "")
        .accessibilityIdentifier("siteTitle")
        .accessibilityAction(named: "Next site") { switchSite(by: 1) }
        .accessibilityAction(named: "Previous site") { switchSite(by: -1) }
    }

    /// Moves the current tab to the next (+1) or previous (-1) enabled site, wrapping around.
    func switchSite(by step: Int) {
        let sites = registry.enabledConfigs
        guard let t = model.current, sites.count > 1 else { return }
        let i = sites.firstIndex { $0.id == t.siteID } ?? (step > 0 ? -1 : 0)
        let next = sites[(i + step + sites.count) % sites.count]
        t.siteID = next.id
        model.objectWillChange.send()
        t.applySticky()
        Haptics.tap()
        Task { await t.search(recordHistory: false) }
    }

    var siteMenu: some View {
        Menu {
            Button {
                guard let t = model.current else { return }
                t.siteID = SearchTabModel.mergedID
                t.sort = nil
                t.rating = nil
                model.objectWillChange.send()
                Task { await t.search(recordHistory: false) }
            } label: {
                if model.current?.isMerged == true { Label("All Sites (merged)", systemImage: "checkmark") } else { Label("All Sites (merged)", systemImage: "square.stack.3d.down.right") }
            }
            Divider()
            ForEach(registry.enabledConfigs) { c in
                Button {
                    guard let t = model.current else { return }
                    t.siteID = c.id
                    model.objectWillChange.send()   // nav title shows the tab's site
                    t.applySticky()
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
                        Button("Default") { t.sort = nil; t.saveSticky(); Task { await t.search(recordHistory: false) } }
                        ForEach(cfg.sortOptions, id: \.self) { o in
                            Button(o) { t.sort = o; t.saveSticky(); Task { await t.search(recordHistory: false) } }
                        }
                    }
                }
                if !cfg.ratingOptions.isEmpty {
                    Menu("Rating: \(t.rating ?? "any")") {
                        Button("Any") { t.rating = nil; t.saveSticky(); Task { await t.search(recordHistory: false) } }
                        ForEach(cfg.ratingOptions, id: \.self) { o in
                            Button(o) { t.rating = o; t.saveSticky(); Task { await t.search(recordHistory: false) } }
                        }
                    }
                }
                if t.supportsPageJump {
                    Button { jumpText = ""; showJump = true } label: { Label("Go to page…", systemImage: "arrow.right.to.line") }
                }
                Button { builderFor = t } label: { Label("Build a Search…", systemImage: "slider.horizontal.3") }
                Button { t.scrollToTopToken += 1 } label: { Label("Scroll to top", systemImage: "arrow.up.to.line") }
                Button {
                    let all = t.visiblePosts(blacklist: settings.blacklistSet)
                    Task {
                        guard await Confirm.ask(title: "Download all \(all.count) results?",
                                                message: "Everything loaded in this grid so far will be added to the download queue.",
                                                confirm: "Download All") else { return }
                        await DownloadManager.shared.enqueue(all)
                    }
                } label: { Label("Download All Results", systemImage: "square.and.arrow.down.on.square") }
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

    /// Low-confidence Auto-Configure fields the user hasn't looked at for this site.
    func reviewFields(_ siteID: String) -> [AdapterConfig.CodingKeys] {
        _ = reviews.all.count   // re-evaluate when the store changes
        guard let cfg = registry.config(for: siteID) else { return [] }
        return reviews.pendingLowFields(for: cfg)
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
    var reviewCount: Int = 0
    let onSelect: () -> Void
    let onClose: () -> Void
    var onReview: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    Text("\(tab.title)").lineLimit(1).font(.subheadline.weight(isSelected ? .semibold : .regular))
                    Text("· \(tab.siteName)").lineLimit(1).font(.caption).foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tab \(tab.title) on \(tab.siteName)")
            if reviewCount > 0 {
                Button(action: onReview) {
                    Text("\(reviewCount)").font(.caption2.weight(.bold)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }
                .accessibilityLabel("Review \(reviewCount) low-confidence field\(reviewCount == 1 ? "" : "s") for \(tab.siteName)")
            }
            // Kept as its own element so VoiceOver (and automation) can reach it.
            if canClose && isSelected {
                Button(action: onClose) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .accessibilityLabel("Close tab \(tab.title)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.14)))
        .accessibilityElement(children: .contain)
    }
}

/// Grid + infinite scroll + pull-to-refresh + selection bar for one tab.
struct SearchTabView: View {
    @ObservedObject var tab: SearchTabModel
    @ObservedObject var settings = AppSettings.shared
    @State private var accountFor: AccountRequest?
    @State private var massReverse: PostBatch?
    /// Scrolled far enough down to offer the floating "back to top" button.
    @State private var showTopButton = false
    let onOpen: ([Post], Int) -> Void
    let onAddToCollection: ([Post]) -> Void

    var body: some View {
        let visible = tab.visiblePosts(blacklist: settings.blacklistSet)
        VStack(spacing: 0) {
            if !tab.siteErrors.isEmpty && !tab.errorBannerDismissed && !visible.isEmpty {
                PartialFailureBanner(errors: tab.siteErrors) { tab.errorBannerDismissed = true }
            }
            if !tab.guestNotes.isEmpty && !tab.guestBannerDismissed {
                GuestLimitBanner(notes: tab.guestNotes, siteName: tab.siteName,
                                 onLogin: { accountFor = AccountRequest(siteID: tab.siteID) },
                                 onDismiss: { tab.guestBannerDismissed = true })
            }
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
                ScrollViewReader { proxy in
                ScrollView {
                    // Lazy, so the marker disappears once scrolled well past: that's when the
                    // floating "back to top" button shows.
                    LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 1).id("gridTop")
                        .onAppear { withAnimation(.easeInOut(duration: 0.2)) { showTopButton = false } }
                        .onDisappear { withAnimation(.easeInOut(duration: 0.2)) { showTopButton = true } }
                    PostGrid(posts: visible, selecting: tab.selecting, selected: tab.selected, showSource: tab.isMerged,
                             onTap: { i in
                                 if tab.selecting { tab.toggleSelect(visible[i]) } else { Haptics.tap(); onOpen(visible, i) }
                             },
                             onLongPressSelect: { p in tab.selecting = true; tab.selected = [p.key] },
                             onAppearIndex: { i in tab.onCellAppear(index: i, visibleCount: visible.count) },
                             onAddToCollection: onAddToCollection) {
                        footer
                    }
                    }
                }
                .refreshable { await tab.refresh() }
                .onChange(of: tab.scrollToTopToken) { _ in withAnimation { proxy.scrollTo("gridTop", anchor: .top) } }
                .overlay(alignment: .bottomTrailing) {
                    if showTopButton && !tab.selecting {
                        Button { Haptics.tap(); tab.scrollToTopToken += 1 } label: {
                            Image(systemName: "arrow.up").font(.headline.weight(.bold))
                                .foregroundColor(.white)
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(Color.accentColor).shadow(radius: 4))
                        }
                        .padding(16)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Scroll to top")
                        .accessibilityIdentifier("scrollToTopButton")
                    }
                }
                }
            }
            if tab.selecting { selectionBar }
        }
        .sheet(item: $massReverse) { MassReverseSheet(posts: $0.posts) }
        .sheet(item: $accountFor) { req in
            NavigationView {
                AccountView(adapterID: req.siteID, displayName: AdapterRegistry.shared.displayName(for: req.siteID),
                            authStyle: AdapterRegistry.shared.config(for: req.siteID)?.authStyle ?? .none)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { accountFor = nil } } }
            }
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
                Text("End of results · \(tab.posts.count) post\(tab.posts.count == 1 ? "" : "s")").font(.caption).foregroundColor(.secondary)
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
            .accessibilityLabel(picked.count == tab.visiblePosts(blacklist: settings.blacklistSet).count ? "Select none" : "Select all")
            Button {
                let all = Set(tab.visiblePosts(blacklist: settings.blacklistSet).map { $0.key })
                tab.selected = all.subtracting(tab.selected)
            } label: { Image(systemName: "arrow.left.arrow.right.circle") }
            .accessibilityLabel("Invert selection")
            Button { LibraryStore.shared.addFavorites(picked); ToastCenter.shared.show("Favorited \(picked.count)", style: .success) }
                label: { Image(systemName: "heart") }
                .disabled(picked.isEmpty).accessibilityLabel("Favorite selected")
            Button { onAddToCollection(picked) } label: { Image(systemName: "folder.badge.plus") }
                .disabled(picked.isEmpty).accessibilityLabel("Add selected to collection")
            Button { massReverse = PostBatch(posts: picked) } label: { Image(systemName: "magnifyingglass.circle") }
                .disabled(picked.isEmpty).accessibilityLabel("Reverse search selected")
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

struct AccountRequest: Identifiable { let id = UUID(); let siteID: String }

/// The site is showing guests less; offers to add a login.
struct GuestLimitBanner: View {
    let notes: [String]
    let siteName: String
    let onLogin: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(siteName) may be limiting guests").font(.caption.weight(.semibold))
                ForEach(notes.prefix(2), id: \.self) { Text($0).font(.caption2).foregroundColor(.secondary).lineLimit(2) }
                Button("Add a login", action: onLogin).font(.caption.weight(.semibold))
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .accessibilityLabel("Dismiss notice")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .gesture(DragGesture(minimumDistance: 8).onEnded { v in if v.translation.height < -20 { onDismiss() } })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guestLimitBanner")
    }
}

/// Subtle notice that some sites of a merged search failed while the rest loaded.
struct PartialFailureBanner: View {
    let errors: [String: String]
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing results from the other sites").font(.caption.weight(.semibold))
                ForEach(errors.keys.sorted(), id: \.self) { k in
                    Text("\(k): \(errors[k] ?? "")").font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .accessibilityLabel("Dismiss notice")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .gesture(DragGesture(minimumDistance: 8).onEnded { v in if v.translation.height < -20 { onDismiss() } })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("partialFailureBanner")
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
    @ObservedObject private var watch = SearchWatch.shared
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var registry = AdapterRegistry.shared

    var body: some View {
        NavigationView {
            List {
                Section("Saved searches") {
                    if store.savedSearches.isEmpty { Text("Tap the bookmark icon next to the search field to save a search.").foregroundColor(.secondary).font(.footnote) }
                    else { Text("Swipe a saved search right (or hold it) to be told about new posts.").foregroundColor(.secondary).font(.footnote) }
                    ForEach(store.savedSearches) { s in
                        Button { watch.markSeen(s.id); onRun(s.query, s.siteID) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    HStack(spacing: 6) {
                                        Text(s.name)
                                        if watch.isWatching(s.id) { Image(systemName: "bell.fill").font(.caption2).foregroundColor(.accentColor) }
                                    }
                                    Text("\(s.query.nonEmpty ?? "(all)") · \(registry.displayName(for: s.siteID))").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if watch.newCount(s.id) > 0 {
                                    Text("\(watch.newCount(s.id)) new").font(.caption.weight(.bold)).foregroundColor(.white)
                                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.accentColor))
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { watch.toggle(s) } label: {
                                Label(watch.isWatching(s.id) ? "Stop Watching" : "Watch", systemImage: watch.isWatching(s.id) ? "bell.slash" : "bell")
                            }
                            .tint(.accentColor)
                        }
                        .contextMenu {
                            Button { watch.toggle(s) } label: {
                                Label(watch.isWatching(s.id) ? "Stop Watching" : "Watch for New Posts", systemImage: watch.isWatching(s.id) ? "bell.slash" : "bell")
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

