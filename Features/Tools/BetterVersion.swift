import SwiftUI

/// Viewer ⋯ › Find Better Version: reverse-searches the picture, opens the matches that are
/// posts on your sites, and lists the ones bigger than what you're looking at, each with
/// "Download Original".
struct BetterVersionSheet: View {
    let post: Post
    let currentSize: CGSize?
    @Environment(\.dismiss) private var dismiss
    @State private var found: [(post: Post, size: CGSize?, similarity: Double?)] = []
    @State private var status = "Searching…"
    @State private var running = true

    var currentPixels: CGFloat { (currentSize ?? post.pixelSize).map { $0.width * $0.height } ?? 0 }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        if running { ProgressView() }
                        Text(status).foregroundColor(.secondary).accessibilityIdentifier("betterStatus")
                    }
                    if let s = currentSize ?? post.pixelSize {
                        Text("This one: \(Int(s.width)) × \(Int(s.height))").font(.footnote)
                    }
                }
                if !found.isEmpty {
                    Section("Larger versions") {
                        ForEach(found, id: \.post.key) { f in
                            HStack(spacing: 10) {
                                CachedAsyncImage(url: f.post.thumbnailURL, maxPixel: 200).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.size.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "Size unknown").font(.headline)
                                    Text("\(AdapterRegistry.shared.displayName(for: f.post.siteID)) #\(f.post.id)\(f.similarity.map { String(format: " · %.0f%%", $0) } ?? "")")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Download Original") { Task { await DownloadManager.shared.enqueue([f.post]) } }
                                    .buttonStyle(.borderedProminent).font(.caption)
                                    .accessibilityIdentifier("downloadOriginal")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Find Better Version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await search() }
        }
    }

    func search() async {
        defer { running = false }
        guard let engine = ReverseEngineStore.shared.engines.first(where: \.enabled) else {
            status = "No reverse search engine is switched on (Settings › Tools › Reverse Search)."
            return
        }
        do {
            let matches = try await ReverseSearch.run(engine, post: post)
            status = "Checking \(matches.count) match\(matches.count == 1 ? "" : "es") on your sites…"
            var out: [(Post, CGSize?, Double?)] = []
            for m in matches.prefix(12) {
                guard let s = m.source, let site = LinkRouter.site(for: s), let id = LinkRouter.target(of: s).postID,
                      let a = AdapterRegistry.shared.adapter(for: site.id), let p = try? await a.fetchPost(id: id),
                      p.key != post.key else { continue }
                let size = p.pixelSize
                let pixels = size.map { $0.width * $0.height } ?? 0
                if currentPixels == 0 || pixels > currentPixels * 1.05 { out.append((p, size, m.similarity)) }
            }
            found = out.sorted { ($0.1.map { $0.width * $0.height } ?? 0) > ($1.1.map { $0.width * $0.height } ?? 0) }
                .map { (post: $0.0, size: $0.1, similarity: $0.2) }
            status = found.isEmpty ? "No larger version found on your sites (\(matches.count) match\(matches.count == 1 ? "" : "es") checked)."
                : "Found \(found.count) larger version\(found.count == 1 ? "" : "s")."
        } catch {
            status = error.localizedDescription
        }
    }
}
