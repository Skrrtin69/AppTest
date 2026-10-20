import SwiftUI
import UIKit
import WidgetKit
import CryptoKit

/// Items sent from the share sheet. Links open on the matching site; a picture opens a
/// reverse search.
@MainActor
enum ShareInbox {
    static func process() {
        guard let inbox = AppGroup.inbox,
              let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        for f in sorted {
            defer { try? FileManager.default.removeItem(at: f) }
            if f.pathExtension == "link" {
                guard let text = try? String(contentsOf: f, encoding: .utf8), let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                if !LinkRouter.open(url) {
                    ToastCenter.shared.show("Shared link isn't from one of your sites.", style: .error, actionTitle: "Copy") {
                        UIPasteboard.general.string = url.absoluteString
                    }
                }
            } else {
                // A picture: keep a private copy (the inbox file is removed) and offer a reverse search.
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString).\(f.pathExtension)")
                guard (try? FileManager.default.copyItem(at: f, to: copy)) != nil else { continue }
                // Presented from the topmost screen, so it also appears over the viewer or a sheet.
                presentWhenReady(UIHostingController(rootView: SharedImageSheet(shared: SharedImage(url: copy))))
            }
        }
    }

    /// The share sheet is still closing when the app hears about a shared item; presenting
    /// over it then fails silently. Wait until the topmost screen is settled.
    static func presentWhenReady(_ vc: UIViewController, attempt: Int = 0) {
        let top = Presenter.topController()
        let busy = top == nil || top!.isBeingDismissed || top!.isBeingPresented || top is UIActivityViewController
            || top!.presentingViewController?.isBeingDismissed == true
        if busy && attempt < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { presentWhenReady(vc, attempt: attempt + 1) }
            return
        }
        top?.present(vc, animated: true)
    }

    /// mediadeck://inbox, mediadeck://favorites,
    /// mediadeck://search?tag=X[&site=Y], mediadeck://post?id=Y[&site=Z]
    private static var lastLink: (url: URL, at: Date)?

    static func handle(_ url: URL) {
        guard url.scheme == "mediadeck" else { return }
        // The same link can arrive twice when it also launches/activates the app.
        if let l = lastLink, l.url == url, Date().timeIntervalSince(l.at) < 2 { return }
        lastLink = (url, Date())
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ names: String...) -> String? { items.first { names.contains($0.name.lowercased()) }?.value?.nonEmpty }
        // "site" may be an adapter id or its display name; without it the open site is used.
        let site = q("site")
        switch url.host {
        case "search":
            let tags = q("tag", "tags", "q") ?? ""
            AppRouter.shared.queueSearch(tags: tags, siteName: site)
            DebugLog.log("Link", "search \"\(tags)\" on \(site ?? "current site")")
        case "post":
            guard let id = q("id") else { ToastCenter.shared.show("That link has no post id.", style: .error); return }
            // A numbers-only search opens that post directly.
            AppRouter.shared.queueSearch(tags: id, siteName: site)
            DebugLog.log("Link", "post \(id) on \(site ?? "current site")")
        // Wait for the share sheet to finish closing before showing anything.
        case "inbox": DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { process() }
        case "favorites": AppRouter.shared.tab = .favorites
        default: break
        }
    }
}

struct SharedImage: Identifiable {
    let id = UUID()
    let url: URL

    /// A stand-in post so the shared picture can go through reverse search.
    var post: Post {
        Post(id: "shared", siteID: "", thumbnailURL: url, mediaURL: url, mediaType: .image,
             tags: [], sourceURL: nil, metadata: [:])
    }
}

/// Keeps the Random Favorite widget's thumbnails and list up to date.
@MainActor
enum WidgetFeedWriter {
    private static var pending: Task<Void, Never>?

    /// Debounced: favorites often change several times in a row.
    static func scheduleUpdate() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await write()
        }
    }

    static func write() async {
        guard let dir = AppGroup.widgetDir, let feedURL = WidgetFeed.fileURL else { return }
        // Decoy mode never touches the widget.
        guard !LockManager.shared.decoyActive else { return }
        let picks = Array(LibraryStore.shared.favorites.shuffled().prefix(24))
        var items: [WidgetFeed.Item] = []
        for f in picks {
            let name = SHA256.hash(data: Data(f.key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
            let file = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) {
                let client = AdapterRegistry.shared.adapter(for: f.post.siteID)?.client
                guard let img = try? await ImagePipeline.shared.image(for: f.post.thumbnailURL, maxPixel: 600, animate: false, client: client),
                      let data = img.jpegData(compressionQuality: 0.8) else { continue }
                try? data.write(to: file, options: .atomic)
            }
            items.append(WidgetFeed.Item(file: name, site: AdapterRegistry.shared.displayName(for: f.post.siteID), key: f.key))
        }
        // Remove thumbnails of favorites that are gone.
        let keep = Set(items.map(\.file) + ["feed.json"])
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(u.lastPathComponent) {
            try? FileManager.default.removeItem(at: u)
        }
        if let data = try? JSONEncoder().encode(WidgetFeed(items: items)) { try? data.write(to: feedURL, options: .atomic) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Shown when a picture arrives from the share sheet.
struct SharedImageSheet: View {
    let shared: SharedImage
    @Environment(\.dismiss) private var dismiss
    @State private var searching = false

    var body: some View {
        if searching {
            ReverseSearchSheet(post: shared.post)
        } else {
            NavigationView {
                VStack(spacing: 16) {
                    CachedAsyncImage(url: shared.url, maxPixel: 1200, contentMode: .scaleAspectFit)
                        .frame(maxHeight: 420)
                    Button { searching = true } label: {
                        Label("Find Where It Comes From", systemImage: "magnifyingglass.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sharedReverseSearch")
                    Spacer()
                }
                .padding()
                .navigationTitle("Shared Picture")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
        }
    }
}
