import SwiftUI
import UserNotifications

/// "Follow Artist": a tag (usually an artist) checked on every enabled site about once a day.
/// New posts are downloaded quietly and announced with a notification.
@MainActor
final class FollowStore: ObservableObject {
    static let shared = FollowStore()

    struct Followed: Codable, Identifiable {
        var tag: String
        var seen: [String] = []        // post keys already known
        var lastCheck: Date?
        var newTotal = 0
        var id: String { tag }
    }

    @Published private(set) var items: [Followed] = []
    private let key = "followedTags"
    /// At most this many new posts are downloaded per tag per check.
    static let maxDownloads = 10

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([Followed].self, from: d) { items = l }
    }

    func isFollowing(_ tag: String) -> Bool { items.contains { $0.tag.lowercased() == tag.lowercased() } }

    func toggle(_ tag: String) {
        if isFollowing(tag) {
            items.removeAll { $0.tag.lowercased() == tag.lowercased() }
            ToastCenter.shared.show("Stopped following \(tag)")
        } else {
            items.append(Followed(tag: tag))
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            ToastCenter.shared.show("Following \(tag): new posts download automatically", style: .success)
            Task { await check(only: tag) }
            SearchWatch.schedule()
        }
        persist()
    }

    /// Runs the daily check if it's due (background refresh or opening the app).
    func checkIfDue() async {
        let last = items.compactMap(\.lastCheck).min() ?? .distantPast
        guard !items.isEmpty, Date().timeIntervalSince(last) > 24 * 3600 else { return }
        await check()
    }

    /// Searches every enabled site for each followed tag. The first check of a tag only
    /// remembers what exists; later checks download what's new.
    @discardableResult
    func check(only: String? = nil) async -> Int {
        guard !LockManager.shared.decoyActive else { return 0 }
        var total = 0
        var lines: [String] = []
        for i in items.indices where only == nil || items[i].tag == only {
            let tag = items[i].tag
            let first = items[i].lastCheck == nil
            var fresh: [Post] = []
            var keys: [String] = []
            for c in AdapterRegistry.shared.enabledConfigs {
                guard let a = AdapterRegistry.shared.adapter(for: c.id),
                      let r = try? await a.search(tags: [tag], options: SearchOptions(), page: c.firstPageIndex) else { continue }
                let posts = r.posts.filter { !AppSettings.shared.isBlacklisted($0) }
                keys += posts.map(\.key)
                if !first { fresh += posts.filter { !items[i].seen.contains($0.key) } }
            }
            items[i].seen = Array(Set(items[i].seen + keys)).suffix(2000).map { $0 }
            items[i].lastCheck = Date()
            if !fresh.isEmpty {
                let batch = Array(fresh.prefix(Self.maxDownloads))
                await DownloadManager.shared.enqueueQuietly(batch)
                items[i].newTotal += batch.count
                total += batch.count
                lines.append("\(batch.count) new by \(tag)")
            }
            DebugLog.log("Follow", "\(tag): \(keys.count) found, \(fresh.count) new\(first ? " (first check)" : "")")
        }
        persist()
        if !lines.isEmpty {
            let c = UNMutableNotificationContent()
            c.title = "MediaDeck"
            c.body = lines.joined(separator: "\n") + " — saved to your Library"
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        return total
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

extension DownloadManager {
    /// Queues downloads without questions or messages (Follow Artist).
    @MainActor
    func enqueueQuietly(_ posts: [Post]) async {
        let warn = AppSettings.shared.warnOnCellular
        AppSettings.shared.warnOnCellular = false
        await enqueue(posts)
        AppSettings.shared.warnOnCellular = warn
    }
}

struct FollowedView: View {
    @ObservedObject private var store = FollowStore.shared
    @State private var result: String?

    var body: some View {
        List {
            Section {
                if store.items.isEmpty { Text("Hold a tag in the Info panel and choose Follow, or tap Follow next to an artist.").foregroundColor(.secondary) }
                ForEach(store.items) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.tag)
                        Text(f.lastCheck.map { "Checked \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())) · \(f.newTotal) downloaded" } ?? "Not checked yet")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .onDelete { idx in idx.map { store.items[$0].tag }.forEach(store.toggle) }
            } footer: {
                Text("Every followed tag is searched on all your switched-on sites about once a day (when iOS gives MediaDeck background time, and when you open the app). New posts are downloaded to the Library and you get a notification.")
            }
            Section {
                Button("Check Now") { Task { let n = await store.check(); result = "\(n) new post\(n == 1 ? "" : "s") downloaded" } }
                    .accessibilityIdentifier("followCheckNow")
                if let r = result { Text(r).foregroundColor(.secondary) }
            }
        }
        .navigationTitle("Followed Artists")
    }
}

// MARK: - Reading progress for galleries

/// The page you were on in each gallery (UserDefaults; the Core Data model is left alone).
final class ReadingProgress: ObservableObject {
    static let shared = ReadingProgress()
    struct Mark: Codable { var page: Int; var total: Int }
    @Published private(set) var marks: [String: Mark] = [:]
    private let key = "readingProgress"

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let m = try? JSONDecoder().decode([String: Mark].self, from: d) { marks = m }
    }

    func save(_ postKey: String, page: Int, total: Int) {
        guard total > 1 else { return }
        if page <= 0 { marks[postKey] = nil } else { marks[postKey] = Mark(page: page, total: total) }
        if let d = try? JSONEncoder().encode(marks) { UserDefaults.standard.set(d, forKey: key) }
    }

    func mark(_ postKey: String) -> Mark? { marks[postKey] }
}

// MARK: - Split spreads

/// Gallery pages shown as two halves (a scanned double page), remembered per page address.
final class SplitPages: ObservableObject {
    static let shared = SplitPages()
    @Published private(set) var urls: Set<String> = []
    private let key = "splitPages"

    private init() { urls = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    func isSplit(_ u: URL) -> Bool { urls.contains(u.absoluteString) }

    func toggle(_ u: URL) {
        if urls.contains(u.absoluteString) { urls.remove(u.absoluteString) } else { urls.insert(u.absoluteString) }
        UserDefaults.standard.set(Array(urls), forKey: key)
    }
}
