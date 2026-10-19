import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var registry = AdapterRegistry.shared
    @ObservedObject private var lock = LockManager.shared
    @State private var cacheSize: Int?
    @State private var showPasscodeSetup = false
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
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("themePicker")
                    Stepper("Grid columns: \(settings.gridColumns)", value: $settings.gridColumns, in: 2...5)
                    Picker("Thumbnail shape", selection: $settings.thumbAspect) {
                        ForEach(ThumbAspect.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Animate GIFs in grids", isOn: $settings.animateGridGIFs)
                    Toggle("Autoplay videos in viewer", isOn: $settings.autoplayVideos)
                }

                Section("Browsing") {
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
                } header: { Text("Downloads") } footer: {
                    Text("Name placeholders: {site} {id} {index} {type} {date}. Use / in Folder for sub-folders, e.g. {site}/{type}. Files are saved in Files › On My iPhone › MediaDeck › Downloads. Changing Background downloads applies after restarting the app.")
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
                    HStack {
                        Text("Cache used")
                        Spacer()
                        Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("cacheSize")
                    }
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

                Section("Security") {
                    if lock.hasPasscode {
                        Button("Change Passcode") { showPasscodeSetup = true }
                        Button("Turn Off Passcode", role: .destructive) { confirm = .removePasscode }
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
                        Text("Locks the app with a 4–6 digit code (and optionally \(lock.biometryName)) whenever you leave it.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("Haptics") {
                    Toggle("Tap feedback", isOn: $settings.hapticsTap)
                    Toggle("Success / error feedback", isOn: $settings.hapticsResult)
                }

                Section {
                    Button("Export Settings to Files") { exportSettings() }
                    Button("Import Settings from Files") { importSettings() }
                    Button("Clear Search History") { confirm = .clearHistory }
                    Button("Delete All Downloads", role: .destructive) { confirm = .clearDownloads }
                    Button("Reset All Settings", role: .destructive) { confirm = .resetSettings }
                } header: { Text("Data") } footer: {
                    Text("Adapters are imported/exported separately under Sites & Adapters.")
                }

                Section("About") {
                    HStack { Text("Version"); Spacer(); Text("\(AppInfo.version) (\(AppInfo.build))").foregroundColor(.secondary) }
                    HStack {
                        Text("Built-in demo server")
                        Spacer()
                        Text(MockServer.shared.isRunning ? "127.0.0.1:\(MockServer.shared.port)" : "stopped")
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
            .navigationTitle("Settings")
            .sheet(isPresented: $showPasscodeSetup) { PasscodeSetupView() }
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
