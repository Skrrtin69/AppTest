import SwiftUI

/// "Download on Wi-Fi": posts saved while on mobile data, handed to the download queue as
/// soon as the phone is on Wi-Fi with the app open (iOS doesn't wake the app for a network
/// change). On Wi-Fi already, they download right away.
final class WifiDownloadQueue: ObservableObject {
    static let shared = WifiDownloadQueue()

    struct Entry: Codable, Identifiable {
        let post: Post
        let added: Date
        var id: String { post.key }
    }

    private let key = "wifiDownloadQueue"
    @Published private(set) var all: [Entry] = []
    private var observers: [NSObjectProtocol] = []
    private var flushing = false

    /// Decoy mode shows nothing.
    var entries: [Entry] { LockManager.shared.decoyActive ? [] : all }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Entry].self, from: data) { all = list }
    }

    /// Called once at launch: watch for Wi-Fi and for the app coming back.
    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NetworkStatus.changed, object: nil, queue: .main) { [weak self] _ in self?.flushIfOnWiFi() },
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.flushIfOnWiFi() },
        ]
        flushIfOnWiFi()
    }

    func contains(_ p: Post) -> Bool { all.contains { $0.id == p.key } }

    /// From the viewer: on mobile data, save for Wi-Fi; on Wi-Fi, download now.
    @MainActor
    func add(_ posts: [Post]) {
        guard !LockManager.shared.decoyActive, !posts.isEmpty else { return }
        guard NetworkStatus.shared.onMeteredData else {
            Task { await DownloadManager.shared.enqueue(posts) }
            return
        }
        let have = Set(all.map(\.id))
        let new = posts.filter { !have.contains($0.key) }
        guard !new.isEmpty else {
            ToastCenter.shared.show("Already waiting for Wi-Fi")
            return
        }
        all.append(contentsOf: new.map { Entry(post: $0, added: Date()) })
        persist()
        ToastCenter.shared.show(new.count == 1 ? "Will download on Wi-Fi" : "\(new.count) posts will download on Wi-Fi", style: .success)
    }

    func remove(_ keys: [String]) {
        let k = Set(keys)
        all.removeAll { k.contains($0.id) }
        persist()
    }

    func clear() {
        all = []
        persist()
    }

    /// "Download Now" in the queue, even on mobile data (the download queue still asks
    /// first when that setting is on).
    @MainActor
    func downloadNow() {
        let posts = all.map(\.post)
        guard !posts.isEmpty else { return }
        clear()
        Task { await DownloadManager.shared.enqueue(posts) }
    }

    private func flushIfOnWiFi() {
        // Not before the connection type is known (at launch it isn't yet, and on mobile data
        // this would start everything); the first answer calls this again.
        guard !all.isEmpty, !flushing, !LockManager.shared.decoyActive,
              NetworkStatus.shared.known, !NetworkStatus.shared.onMeteredData else { return }
        flushing = true
        let posts = all.map(\.post)
        DebugLog.log("Downloads", "On Wi-Fi: starting \(posts.count) saved download\(posts.count == 1 ? "" : "s")")
        Task { @MainActor in
            await DownloadManager.shared.enqueue(posts)
            // Only what was handed over leaves the list (more may have been added meanwhile).
            remove(posts.map(\.key))
            flushing = false
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Downloads › the posts waiting for Wi-Fi.
struct WifiQueueSection: View {
    @ObservedObject private var queue = WifiDownloadQueue.shared

    var body: some View {
        if !queue.entries.isEmpty {
            Section {
                ForEach(queue.entries) { e in
                    HStack(spacing: 10) {
                        CachedAsyncImage(url: e.post.thumbnailURL, maxPixel: 120, contentMode: .scaleAspectFill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.post.mediaURL.lastPathComponent).font(.subheadline).lineLimit(1)
                            Text("\(e.post.siteID) · waiting for Wi-Fi").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { queue.remove([e.id]) } label: { Label("Remove", systemImage: "xmark") }
                    }
                }
                Button { queue.downloadNow() } label: { Label("Download Now", systemImage: "arrow.down.circle") }
                    .accessibilityIdentifier("wifiQueueDownloadNow")
                Button(role: .destructive) { queue.clear() } label: { Label("Clear", systemImage: "trash") }
            } header: {
                Text("Waiting for Wi-Fi (\(queue.entries.count))")
            } footer: {
                Text("These start by themselves the next time MediaDeck is open on Wi-Fi.")
            }
        }
    }
}
