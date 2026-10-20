import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One JSON file with everything needed to move MediaDeck to another phone: settings,
/// adapters, favorites, collections, history, saved searches, custom themes and reverse
/// search engines. Passwords, API keys and the passcode are never included.
@MainActor
enum Backup {
    static let format = "MediaDeck backup"

    static func make() throws -> Data {
        var root: [String: Any] = [
            "_format": format,
            "_version": 1,
            "_created": ISO8601DateFormatter().string(from: Date()),
            "_note": "Passwords, API keys and the app passcode are not in this file.",
        ]
        if let s = try? JSONSerialization.jsonObject(with: AppSettings.shared.exportJSON()) as? [String: Any] {
            root["settings"] = s.filter { !$0.key.hasPrefix("_") }
        }
        if let data = try? Data(contentsOf: AdapterRegistry.documentsFile),
           let list = try? JSONSerialization.jsonObject(with: data) {
            root["adapters"] = list
        }
        let d = UserDefaults.standard
        root["adapterOrder"] = d.stringArray(forKey: "adapterOrder") ?? []
        root["adapterDisabled"] = d.stringArray(forKey: "adapterDisabled") ?? []
        root["library"] = LibraryStore.shared.backupJSON()
        if let t = d.data(forKey: "customThemes"), let list = try? JSONSerialization.jsonObject(with: t) {
            root["customThemes"] = list
            root["activeCustomTheme"] = d.string(forKey: "activeCustomTheme") ?? ""
        }
        if let e = try? JSONSerialization.jsonObject(with: Data(ReverseEngineStore.shared.json.utf8)) {
            root["reverseEngines"] = e
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Merges a backup into what's here and returns a summary. Settings are replaced;
    /// adapters, engines and themes are added when their id isn't here yet; library items
    /// are added when missing. Nothing is deleted.
    static func restore(_ data: Data) throws -> String {
        guard !LockManager.shared.decoyActive else { throw AppError.message("Restoring isn't available right now.") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["_format"] as? String == format else {
            throw AppError.message("That file isn't a MediaDeck backup. (Settings-only and adapters-only files are imported in their own sections.)")
        }
        var parts: [String] = []

        if let s = root["settings"] as? [String: Any], !s.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: s) {
            try? AppSettings.shared.importJSON(data)
            parts.append("settings")
        }

        if let list = root["adapters"] as? [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: list)
            let incoming = try AdapterRegistry.decode(data)
            let have = Set(AdapterRegistry.shared.configs.map(\.id))
            let added = incoming.filter { !have.contains($0.id) }
            for c in added { try AdapterRegistry.shared.upsert(c) }
            let d = UserDefaults.standard
            let disabled = Set(d.stringArray(forKey: "adapterDisabled") ?? [])
                .union((root["adapterDisabled"] as? [String] ?? []).filter { id in added.contains { $0.id == id } })
            d.set(Array(disabled), forKey: "adapterDisabled")
            if !added.isEmpty { parts.append("\(added.count) adapter\(added.count == 1 ? "" : "s")") }
        }

        if let lib = root["library"] as? [String: Any] {
            let n = LibraryStore.shared.mergeBackup(lib)
            if n.favorites > 0 { parts.append("\(n.favorites) favorite\(n.favorites == 1 ? "" : "s")") }
            if n.collections > 0 { parts.append("\(n.collections) collection\(n.collections == 1 ? "" : "s")") }
            if n.savedSearches > 0 { parts.append("\(n.savedSearches) saved search\(n.savedSearches == 1 ? "" : "es")") }
            if n.history > 0 { parts.append("\(n.history) history item\(n.history == 1 ? "" : "s")") }
        }

        if let themes = root["customThemes"],
           let data = try? JSONSerialization.data(withJSONObject: themes),
           let list = try? JSONDecoder().decode([CustomTheme].self, from: data) {
            let store = CustomThemeStore.shared
            let have = Set(store.themes.map(\.id))
            let new = list.filter { !have.contains($0.id) }
            new.forEach(store.save)
            if !new.isEmpty { parts.append("\(new.count) theme\(new.count == 1 ? "" : "s")") }
        }

        if let engines = root["reverseEngines"],
           let data = try? JSONSerialization.data(withJSONObject: engines),
           let list = try? JSONDecoder().decode([ReverseEngine].self, from: data) {
            let store = ReverseEngineStore.shared
            let have = Set(store.engines.map(\.id))
            let new = list.filter { !have.contains($0.id) }
            new.forEach(store.upsert)
            if !new.isEmpty { parts.append("\(new.count) reverse search engine\(new.count == 1 ? "" : "s")") }
        }

        return parts.isEmpty ? "Nothing new: everything in the backup is already here."
            : "Restored " + parts.joined(separator: ", ") + "."
    }

    static func exportNow() {
        do {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            Presenter.exportData(try make(), filename: "MediaDeck-backup-\(f.string(from: Date())).json")
        } catch { ToastCenter.shared.error(error, prefix: "Backup failed") }
    }

    static func importNow() {
        Presenter.importFile(types: [.json, .data]) { url in
            Task { @MainActor in
                do { ToastCenter.shared.show(try restore(Data(contentsOf: url)), style: .success) }
                catch { ToastCenter.shared.error(error, prefix: "Restore failed") }
            }
        }
    }
}

/// Settings › Storage: what takes space, by site and kind.
struct StorageView: View {
    struct Slice: Identifiable {
        let id = UUID()
        let label: String
        let kind: String
        let bytes: Int
    }

    @State private var slices: [Slice] = []
    @State private var loading = true

    var total: Int { slices.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        List {
            Section {
                if loading {
                    HStack { ProgressView(); Text("Measuring…").foregroundColor(.secondary) }
                } else if slices.isEmpty {
                    Text("Nothing stored yet.").foregroundColor(.secondary)
                } else {
                    StorageChart(slices: slices)
                        .frame(height: CGFloat(max(slices.count, 2)) * 34 + 30)
                        .padding(.vertical, 6)
                }
            } header: { Text("Total \(Self.size(total))") }
            if !slices.isEmpty {
                Section("Details") {
                    ForEach(slices) { s in
                        HStack {
                            Circle().fill(Self.color(s.kind)).frame(width: 9, height: 9)
                            VStack(alignment: .leading) {
                                Text(s.label)
                                Text(s.kind).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(Self.size(s.bytes)).foregroundColor(.secondary).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("Storage")
        .task { await measure() }
        .refreshable { await measure() }
    }

    func measure() async {
        loading = true
        var out: [Slice] = []
        let registry = AdapterRegistry.shared
        for (site, bytes) in await ImageCache.shared.sizeBySite() where bytes > 0 {
            out.append(Slice(label: site.isEmpty ? "Unsorted" : registry.displayName(for: site), kind: "Cache", bytes: bytes))
        }
        var downloads: [String: Int] = [:]
        for item in DownloadManager.shared.completed {
            let onDisk = item.fileURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            downloads[item.post.siteID, default: 0] += onDisk ?? Int(item.bytesTotal)
        }
        for (site, bytes) in downloads where bytes > 0 {
            out.append(Slice(label: registry.displayName(for: site), kind: "Downloads", bytes: bytes))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let db = Self.folderSize(support)
        if db > 0 { out.append(Slice(label: "Library database", kind: "Data", bytes: db)) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let web = Self.folderSize(caches.appendingPathComponent("WebKit")) + Self.folderSize(caches.appendingPathComponent("com.apple.WebKit.GPU"))
        if web > 0 { out.append(Slice(label: "Web pages", kind: "Cache", bytes: web)) }
        slices = out.sorted { $0.bytes > $1.bytes }
        loading = false
    }

    static func folderSize(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += v?.totalFileAllocatedSize ?? 0 }
        }
        return total
    }

    static func size(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "Cache": return .orange
        case "Downloads": return .accentColor
        default: return .purple
        }
    }
}
