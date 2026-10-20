import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var registry = AdapterRegistry.shared
    @ObservedObject private var lock = LockManager.shared
    @State private var cacheSize: Int?
    @State private var siteCacheSizes: [String: Int] = [:]
    @State private var showPasscodeSetup = false
    @State private var showDecoySetup = false
    @State private var versionTaps = 0
    @State private var showDebug = false
    @State private var confirm: ConfirmAction?

    enum ConfirmAction: String, Identifiable {
        case clearDownloads, resetSettings, clearHistory, removePasscode
        var id: String { rawValue }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Sites") {
                    NavigationLink(destination: AdaptersListView()) {
                        HStack {
                            Label("Sites & Adapters", systemImage: "globe")
                            Spacer()
                            Text("\(registry.enabledConfigs.count) on").foregroundColor(.secondary)
                        }
                    }
                    .accessibilityIdentifier("sitesAndAdapters")
                }

                Section("Appearance") {
                    NavigationLink(destination: ThemesView()) {
                        HStack { Text("Theme"); Spacer(); Text(settings.theme.label).foregroundColor(.secondary) }
                    }
                    .accessibilityIdentifier("themePicker")
                    Stepper("Grid columns: \(settings.gridColumns)", value: $settings.gridColumns, in: 2...5)
                    VStack(alignment: .leading) {
                        Text("Grid spacing: \(Int(settings.gridSpacing)) pt")
                        Slider(value: $settings.gridSpacing, in: 0...12, step: 1)
                            .accessibilityLabel("Grid spacing")
                    }
                    Picker("Thumbnail shape", selection: $settings.thumbAspect) {
                        ForEach(ThumbAspect.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Animate GIFs in grids", isOn: $settings.animateGridGIFs)
                    Toggle("Smart square thumbnails", isOn: $settings.smartThumbnails)
                        .accessibilityIdentifier("smartThumbnails")
                    Toggle("Play alongside other audio", isOn: $settings.mixWithOthers)
                        .accessibilityIdentifier("mixWithOthers")
                    Toggle("Prefer lighter images in the viewer", isOn: $settings.preferLighter)
                    Toggle("Blur thumbnails until tapped", isOn: $settings.blurThumbnails)
                    Toggle("Dim posts I've already opened", isOn: $settings.dimViewed)
                    Button("Forget which posts I've opened") {
                        ViewedStore.shared.clearViewed()
                        ToastCenter.shared.show("Viewed history cleared", style: .success)
                    }
                }

                Section {
                    Toggle("Autoplay videos in viewer", isOn: $settings.autoplayVideos)
                    Toggle("Start videos muted", isOn: $settings.startMuted)
                        .accessibilityIdentifier("startMutedToggle")
                    Toggle("Enable Volume/Brightness Swipes", isOn: $settings.edgeSwipes)
                        .accessibilityIdentifier("edgeSwipesToggle")
                    Toggle("Use VLCKit for Video (Faster, Larger App)", isOn: $settings.useVLC)
                        .accessibilityIdentifier("useVLCToggle")
                        .disabled(!VLCVideoView.available)
                } header: { Text("Reading & Viewer") } footer: {
                    Text("Swipes: drag along the right edge of a post for volume, the left edge for brightness. VLCKit plays WebM and MKV videos with native code instead of the web player's WebAssembly decoder, which is much faster for large files. It doesn't use the hardware decoder (iOS doesn't offer one for VP9 to apps). VLCKit is part of every copy of the app, so this switch only picks the player.")
                }

                Section {
                    Toggle("Right-to-left page order", isOn: $settings.readingRTL)
                    Toggle("Tap picture edges to turn pages", isOn: $settings.tapZones)
                    Picker("Rotation in the viewer", selection: $settings.rotationLock) {
                        Text("Automatic").tag("auto")
                        Text("Lock portrait").tag("portrait")
                        Text("Lock landscape").tag("landscape")
                    }
                    NavigationLink(destination: ViewerToolbarSettingsView()) {
                        Text("Viewer toolbar")
                    }
                    .accessibilityIdentifier("viewerToolbarSettings")
                    Toggle("Swipe the site name to switch sites", isOn: $settings.swipeSites)
                    Toggle("Two pages side by side in landscape", isOn: $settings.twoPageLandscape)
                    Picker("Fallback site", selection: $settings.fallbackSite) {
                        Text("None").tag("")
                        ForEach(registry.listedConfigs) { Text($0.displayName).tag($0.id) }
                    }
                    .accessibilityIdentifier("fallbackSitePicker")
                    Picker("Double tap a picture", selection: $settings.doubleTapAction) {
                        Text("Zoom").tag("zoom"); Text("Favorite").tag("favorite"); Text("Info").tag("info")
                        Text("Next post").tag("next"); Text("Read Later").tag("readLater"); Text("Nothing").tag("none")
                    }
                    .accessibilityIdentifier("doubleTapPicker")
                    Picker("Swipe up on a post", selection: $settings.swipeUpAction) {
                        Text("Hide posts like this").tag("hide"); Text("Info").tag("info"); Text("Favorite").tag("favorite")
                        Text("Download").tag("download"); Text("Read Later").tag("readLater"); Text("Nothing").tag("none")
                    }
                    .accessibilityIdentifier("swipeUpPicker")
                    Picker("Swipe down", selection: $settings.swipeDownAction) {
                        Text("Close the viewer").tag("close"); Text("Nothing").tag("none")
                    }
                } header: { Text("Reading") } footer: {
                    Text("Right-to-left suits manga: swipe right for the next post. With edge taps on, tapping the outer third of a picture turns the page and the middle shows the controls.")
                }

                Section {
                    Picker("Battery Saver", selection: $settings.batterySaver) {
                        Text("Off").tag("off")
                        Text("With Low Power Mode").tag("auto")
                        Text("Always on").tag("on")
                    }
                    .accessibilityIdentifier("batterySaverPicker")
                    if settings.savingPower {
                        Label("Battery Saver is on now", systemImage: "battery.25").foregroundColor(.orange)
                    }
                    Toggle("Full-size media only on Wi-Fi", isOn: $settings.wifiOnlyMedia)
                        .accessibilityIdentifier("wifiOnlyToggle")
                    Picker("Data Saver", selection: $settings.dataSaver) {
                        Text("Off").tag("off")
                        Text("On mobile data").tag("cellular")
                        Text("Always").tag("always")
                    }
                    .accessibilityIdentifier("dataSaverPicker")
                } header: { Text("Battery and data") } footer: {
                    Text("Battery Saver stops GIF animation in grids, doesn't start videos by itself, shows the lighter file in the viewer when the site has one, and doesn't preload the next posts. Data Saver opens pictures in their smaller version first; tap Load Full Resolution for the original. With Wi-Fi only on, mobile data loads just thumbnails until you tap Load or Play.")
                }

                Section {
                    NavigationLink(destination: ReverseEnginesView()) {
                        HStack { Label("Reverse Search", systemImage: "magnifyingglass.circle"); Spacer()
                            Text("\(ReverseEngineStore.shared.engines.filter(\.enabled).count) on").foregroundColor(.secondary) }
                    }
                    .accessibilityIdentifier("reverseSearchSettings")
                    Toggle("Offer to open copied links", isOn: $settings.detectClipboardLinks)
                    NavigationLink(destination: FollowedView()) { Label("Followed Artists", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("followedArtists")
                    NavigationLink(destination: WiFiTransferView()) { Label("Wi-Fi Transfer", systemImage: "wifi") }
                        .accessibilityIdentifier("wifiTransfer")
                    NavigationLink(destination: LocalDuplicatesView()) { Label("Find Duplicates", systemImage: "square.on.square") }
                        .accessibilityIdentifier("findDuplicates")
                } header: { Text("Tools") } footer: {
                    Text("When you copy a link to a post or search on one of your sites and come back to MediaDeck, it offers to open it here. iOS asks for permission when you tap Open.")
                }

                Section("Browsing") {
                    NavigationLink(destination: TagTranslationsView()) {
                        HStack { Label("Tag Translations", systemImage: "character.bubble"); Spacer()
                            Text("\(TagTranslations.shared.map.count)").foregroundColor(.secondary) }
                    }
                    .accessibilityIdentifier("tagTranslations")
                    NavigationLink(destination: BlacklistView()) {
                        HStack {
                            Label("Tag Blacklist", systemImage: "eye.slash")
                            Spacer()
                            Text("\(settings.blacklist.count)").foregroundColor(.secondary)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Slideshow: every \(Int(settings.slideshowInterval)) seconds")
                        Slider(value: $settings.slideshowInterval, in: 2...30, step: 1)
                            .accessibilityLabel("Slideshow interval")
                    }
                }

                Section {
                    Picker("Download quality", selection: $settings.downloadQuality) {
                        Text("Original").tag(MediaQuality.original)
                        Text("Preview (smaller)").tag(MediaQuality.preview)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File name")
                        TextField(AppSettings.defaultFilenameTemplate, text: $settings.filenameTemplate)
                            .font(.body.monospaced()).textInputAutocapitalization(.never).disableAutocorrection(true)
                            .accessibilityIdentifier("filenameTemplate")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Folder")
                        TextField("(none — all in one folder)", text: $settings.folderTemplate)
                            .font(.body.monospaced()).textInputAutocapitalization(.never).disableAutocorrection(true)
                            .accessibilityIdentifier("folderTemplate")
                    }
                    VStack(alignment: .leading) {
                        Text("Simultaneous downloads: \(settings.maxDownloads)")
                        Slider(value: intBinding($settings.maxDownloads), in: 1...8, step: 1)
                            .accessibilityLabel("Simultaneous downloads")
                    }
                    Toggle("Background downloads", isOn: $settings.backgroundDownloads)
                    Toggle("Strip EXIF data (camera, GPS)", isOn: $settings.stripEXIF)
                        .accessibilityIdentifier("stripEXIF")
                    Toggle("Auto-tag downloads (on this phone)", isOn: $settings.autoTagDownloads)
                        .accessibilityIdentifier("autoTag")
                    Toggle("Ask before big downloads on cellular", isOn: $settings.warnOnCellular)
                    Picker("Skip files larger than", selection: $settings.maxDownloadMB) {
                        Text("No limit").tag(0.0)
                        ForEach([0.1, 1, 5, 10, 25, 50, 100, 250], id: \.self) { mb in
                            Text(mb < 1 ? "\(String(format: "%.1f", mb)) MB" : "\(Int(mb)) MB").tag(mb)
                        }
                    }
                    .accessibilityIdentifier("maxDownloadPicker")
                } header: { Text("Downloads") } footer: {
                    Text("Name placeholders: {site} {id} {index} {type} {date}. Use / in Folder for sub-folders, e.g. {site}/{type}. Files are saved in Files › On My iPhone › MediaDeck › Downloads. Changing Background downloads applies after restarting the app; if this device can't do background downloads, the app notices and switches to regular downloads automatically.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Simultaneous thumbnail loads: \(settings.maxThumbLoads)")
                        Slider(value: intBinding($settings.maxThumbLoads), in: 1...16, step: 1)
                            .accessibilityLabel("Simultaneous thumbnail loads")
                    }
                    VStack(alignment: .leading) {
                        Text("Cache size limit: \(settings.cacheLimitMB) MB")
                        Slider(value: intBinding($settings.cacheLimitMB), in: 50...2000, step: 50)
                            .accessibilityLabel("Cache size limit")
                    }
                    Picker("Delete cached files not opened in", selection: $settings.cacheExpiryDays) {
                        Text("Never").tag(0)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                    .accessibilityIdentifier("cacheExpiryPicker")
                    .onChange(of: settings.cacheExpiryDays) { days in
                        guard days > 0 else { return }
                        Task {
                            let freed = await ImageCache.shared.expire()
                            await refreshCache()
                            if freed > 0 {
                                ToastCenter.shared.show("Removed \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .file)) not opened in \(days) days", style: .success)
                            }
                        }
                    }
                    HStack {
                        Text("Cache used")
                        Spacer()
                        Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("cacheSize")
                    }
                    Menu {
                        ForEach(registry.configs) { c in
                            Button("\(c.displayName) (\(ByteCountFormatter.string(fromByteCount: Int64(siteCacheSizes[c.id] ?? 0), countStyle: .file)))") {
                                Task {
                                    let freed = await ImageCache.shared.clear(siteID: c.id)
                                    ImagePipeline.shared.clearMemory()
                                    await refreshCache()
                                    ToastCenter.shared.show("Cleared \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .file)) cached from \(c.displayName)", style: .success)
                                }
                            }
                        }
                        if let other = siteCacheSizes[""], other > 0 {
                            Button("Unsorted (\(ByteCountFormatter.string(fromByteCount: Int64(other), countStyle: .file)))") {
                                Task {
                                    let freed = await ImageCache.shared.clear(siteID: "")
                                    ImagePipeline.shared.clearMemory()
                                    await refreshCache()
                                    ToastCenter.shared.show("Cleared \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .file)) of unsorted cache", style: .success)
                                }
                            }
                        }
                    } label: { Text("Clear Cache for One Site…") }
                    .accessibilityIdentifier("clearSiteCache")
                    Button("Clear Cache") {
                        Task {
                            await ImageCache.shared.clear()
                            ImagePipeline.shared.clearMemory()
                            await refreshCache()
                            ToastCenter.shared.show("Cache cleared", style: .success)
                        }
                    }
                    .accessibilityIdentifier("clearCache")
                } header: { Text("Performance") } footer: {
                    Text("Each site's request speed is set per adapter (Requests per second).")
                }

                Section {
                    if lock.decoyActive {
                        // Decoy mode: nothing here reveals or changes the real passcode.
                        Button("Lock Now") { lock.lockNow() }
                    } else if lock.hasPasscode {
                        Button("Change Passcode") { showPasscodeSetup = true }
                        Button("Turn Off Passcode", role: .destructive) { confirm = .removePasscode }
                        if lock.hasDecoy {
                            Button("Change Decoy Passcode") { showDecoySetup = true }
                            Button("Remove Decoy Passcode", role: .destructive) {
                                lock.removeDecoyPasscode()
                                ToastCenter.shared.show("Decoy passcode removed")
                            }
                        } else {
                            Button("Set Decoy Passcode…") { showDecoySetup = true }
                                .accessibilityIdentifier("setDecoy")
                        }
                        Toggle("Unlock with \(lock.biometryName)", isOn: $settings.biometricsEnabled)
                            .disabled(!lock.biometricsAvailable)
                        Picker("Require passcode", selection: $settings.lockGraceSeconds) {
                            Text("Immediately").tag(0)
                            Text("After 30 seconds").tag(30)
                            Text("After 1 minute").tag(60)
                            Text("After 5 minutes").tag(300)
                            Text("After 15 minutes").tag(900)
                        }
                        Button("Lock Now") { lock.lockNow() }
                    } else {
                        Button("Turn On Passcode") { showPasscodeSetup = true }
                            .accessibilityIdentifier("turnOnPasscode")
                        Text("Locks the app with a 4-digit code (and optionally \(lock.biometryName)) whenever you leave it.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    Picker("Panic gesture", selection: $settings.panicGesture) {
                        Text("Off").tag("off"); Text("Shake the phone").tag("shake"); Text("Two-finger swipe down").tag("twoFingerSwipe")
                    }
                    .accessibilityIdentifier("panicGesture")
                    if settings.panicGesture != "off" {
                        Picker("Panic shows", selection: $settings.panicAction) {
                            Text("Blur").tag("blur"); Text("Calculator").tag("calculator")
                        }
                        .accessibilityIdentifier("panicAction")
                    }
                } header: { Text("Security") } footer: {
                    if lock.hasPasscode && !lock.decoyActive {
                        Text("Panic: the gesture covers the app at once. Blur: tap three times to uncover. Calculator: type your passcode and press =, or without a passcode hold AC for two seconds. A decoy passcode opens MediaDeck looking unused: no favorites, collections, history or downloads, and only the demo sites. Nothing is deleted, and nothing new is saved. Your real passcode brings everything back.")
                    }
                }

                Section("Haptics") {
                    Toggle("Tap feedback", isOn: $settings.hapticsTap)
                    Toggle("Success / error feedback", isOn: $settings.hapticsResult)
                }

                Section {
                    NavigationLink(destination: StorageView()) { Label("Storage", systemImage: "chart.bar.xaxis") }
                        .accessibilityIdentifier("storageView")
                    Button { Backup.exportNow() } label: { Label("Back Up Everything…", systemImage: "externaldrive.badge.plus") }
                        .disabled(lock.decoyActive)
                    Button { Backup.importNow() } label: { Label("Restore from Backup…", systemImage: "externaldrive.badge.checkmark") }
                        .disabled(lock.decoyActive)
                    Button("Export Settings to Files") { exportSettings() }
                    Button("Import Settings from Files") { importSettings() }
                    Button("Clear Search History") { confirm = .clearHistory }
                    Button("Delete All Downloads", role: .destructive) { confirm = .clearDownloads }
                    Button("Reset All Settings", role: .destructive) { confirm = .resetSettings }
                } header: { Text("Data") } footer: {
                    Text("A backup holds settings, adapters, favorites, collections, history, saved searches, themes and reverse search engines in one JSON file. Passwords, API keys and the passcode are never included. Restoring adds what's missing and never deletes anything.")
                }

                Section("About") {
                    HStack { Text("Version"); Spacer(); Text("\(AppInfo.version) (\(AppInfo.build))").foregroundColor(.secondary) }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            versionTaps += 1
                            if versionTaps >= 5 { versionTaps = 0; showDebug = true }
                        }
                        .background(NavigationLink(destination: DebugConsoleView(), isActive: $showDebug) { EmptyView() }.opacity(0))
                        .accessibilityIdentifier("versionRow")
                    HStack {
                        Text("Built-in demo server")
                        Spacer()
                        Text(MockServer.shared.isRunning ? "127.0.0.1:" + String(MockServer.shared.port) : "stopped")
                            .font(.caption.monospaced()).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Update address")
                        TextField(AppSettings.defaultUpdateURL, text: $settings.updateURL)
                            .font(.caption.monospaced()).textInputAutocapitalization(.never).disableAutocorrection(true)
                    }
                    Button("Check for Updates") {
                        if let u = URL(string: settings.updateURL) { UIApplication.shared.open(u) }
                        else { ToastCenter.shared.show("The update address isn't valid.", style: .error) }
                    }
                }
            }
            .themedBackground()
            .keyboardDoneButton()
            .navigationTitle("Settings")
            .sheet(isPresented: $showPasscodeSetup) { PasscodeSetupView() }
            .sheet(isPresented: $showDecoySetup) { PasscodeSetupView(decoy: true) }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                Button("Confirm", role: .destructive) { perform(confirm) }
            }
            .task { await refreshCache() }
        }
        .navigationViewStyle(.stack)
    }

    var confirmTitle: String {
        switch confirm {
        case .clearDownloads: return "Delete every downloaded file and the download queue?"
        case .resetSettings: return "Reset every setting to its default? (Adapters, favorites and downloads are kept.)"
        case .clearHistory: return "Clear all search history?"
        case .removePasscode: return "Turn off the app passcode?"
        case .none: return ""
        }
    }

    func perform(_ action: ConfirmAction?) {
        switch action {
        case .clearDownloads:
            DownloadManager.shared.removeAll()
            ToastCenter.shared.show("Downloads deleted", style: .success)
        case .resetSettings:
            settings.resetAll()
            ImagePipeline.shared.setConcurrency(settings.maxThumbLoads)
            ToastCenter.shared.show("Settings reset", style: .success)
        case .clearHistory:
            LibraryStore.shared.clearHistory()
            ToastCenter.shared.show("Search history cleared", style: .success)
        case .removePasscode:
            do { try lock.removePasscode(); ToastCenter.shared.show("Passcode off") } catch { ToastCenter.shared.error(error) }
        case .none: break
        }
        confirm = nil
    }

    func refreshCache() async {
        cacheSize = await ImageCache.shared.diskSize()
        siteCacheSizes = await ImageCache.shared.sizeBySite()
    }

    func intBinding(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int($0.rounded()) })
    }

    func exportSettings() {
        do {
            Presenter.exportData(try settings.exportJSON(), filename: "MediaDeck-settings.json")
        } catch { ToastCenter.shared.error(error, prefix: "Export failed") }
    }

    func importSettings() {
        Presenter.importFile(types: [.json, .data]) { url in
            do {
                try settings.importJSON(try Data(contentsOf: url))
                ToastCenter.shared.show("Settings imported", style: .success)
            } catch { ToastCenter.shared.error(error, prefix: "Import failed") }
        }
    }
}

struct BlacklistView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var newTag = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Tag to hide", text: $newTag)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                        .onSubmit(add)
                        .accessibilityIdentifier("blacklistField")
                    Button("Add", action: add).disabled(newTag.nonEmpty == nil)
                        .accessibilityIdentifier("blacklistAdd")
                }
            } footer: {
                Text("Posts with any of these tags are hidden everywhere: search results, favorites and collections. Separate several tags with spaces.")
            }
            Section("Hidden tags") {
                if settings.blacklist.isEmpty { Text("None").foregroundColor(.secondary) }
                ForEach(settings.blacklist, id: \.self) { Text($0) }
                    .onDelete { settings.blacklist.remove(atOffsets: $0) }
            }
        }
        .keyboardDoneButton()
        .navigationTitle("Tag Blacklist")
        .toolbar { EditButton() }
    }

    func add() {
        let tags = newTag.lowercased().split(separator: " ").map(String.init)
        for t in tags where !settings.blacklist.contains(t) { settings.blacklist.append(t) }
        newTag = ""
        if !tags.isEmpty { ToastCenter.shared.show("Hidden: \(tags.joined(separator: ", "))") }
    }
}
