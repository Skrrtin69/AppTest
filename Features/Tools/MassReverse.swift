import SwiftUI

/// Reverse search for many selected posts at once, with a report: which have a source,
/// which found nothing, and which point to the same source as another selected post (or to a
/// post already on one of your sites) — likely duplicates.
struct MassReverseSheet: View {
    let posts: [Post]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ReverseEngineStore.shared
    @State private var engineID: String?
    @State private var results: [String: Result] = [:]
    @State private var running = false
    @State private var done = 0

    struct Result {
        var best: ReverseMatch?
        var error: String?
    }

    var engines: [ReverseEngine] { store.engines.filter(\.enabled) }
    var engine: ReverseEngine? { engines.first { $0.id == engineID } ?? engines.first }

    /// Source link → selected posts whose best match is that link.
    var sharedSources: [URL: [Post]] {
        var m: [URL: [Post]] = [:]
        for p in posts { if let s = results[p.key]?.best?.source { m[s, default: []].append(p) } }
        return m.filter { $0.value.count > 1 }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    if engines.isEmpty {
                        Text("No reverse search engine is switched on. Add one in Settings › Tools › Reverse Search.").foregroundColor(.secondary)
                    } else {
                        Picker("Engine", selection: $engineID) {
                            ForEach(engines) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        Button {
                            Task { await runAll() }
                        } label: {
                            Label(running ? "Searching \(done) of \(posts.count)…" : "Search \(posts.count) Picture\(posts.count == 1 ? "" : "s")",
                                  systemImage: "magnifyingglass.circle")
                        }
                        .disabled(running)
                        .accessibilityIdentifier("massRun")
                    }
                } footer: {
                    Text("One picture at a time, with a short pause between them so the engine isn't flooded. Pictures only on this phone are uploaded.")
                }
                if !results.isEmpty { report }
            }
            .navigationTitle("Reverse Search Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { UIPasteboard.general.string = reportText; ToastCenter.shared.show("Report copied") } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(results.isEmpty)
                    .accessibilityLabel("Copy report")
                }
            }
        }
    }

    @ViewBuilder var report: some View {
        let dupes = sharedSources
        let withSource = posts.filter { results[$0.key]?.best?.source != nil }
        let nothing = posts.filter { results[$0.key] != nil && results[$0.key]?.best == nil && results[$0.key]?.error == nil }
        let failed = posts.filter { results[$0.key]?.error != nil }
        Section("Summary") {
            Text("\(withSource.count) with a source · \(nothing.count) without · \(dupes.values.reduce(0) { $0 + $1.count }) in duplicate groups · \(failed.count) failed")
                .font(.footnote).accessibilityIdentifier("massSummary")
        }
        if !dupes.isEmpty {
            Section("Same source (likely duplicates)") {
                ForEach(Array(dupes.keys), id: \.self) { src in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(src.absoluteString).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        Text(dupes[src]!.map { "#\($0.id)" }.joined(separator: ", ")).font(.subheadline)
                    }
                }
            }
        }
        Section("Results") {
            ForEach(posts, id: \.key) { p in row(p) }
        }
    }

    func row(_ p: Post) -> some View {
        let r = results[p.key]
        let onSite = r?.best?.source.flatMap { LinkRouter.site(for: $0) }
        let target = r?.best?.source.map { LinkRouter.target(of: $0) }
        return HStack(spacing: 10) {
            CachedAsyncImage(url: p.thumbnailURL, maxPixel: 160).frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(p.id) · \(AdapterRegistry.shared.displayName(for: p.siteID))").font(.subheadline)
                if let e = r?.error {
                    Text(e).font(.caption).foregroundColor(.red).lineLimit(2)
                } else if let b = r?.best {
                    Text("\(b.similarity.map { String(format: "%.0f%%", $0) } ?? "?") · \(b.source?.host ?? "no link")")
                        .font(.caption).foregroundColor(.secondary)
                    if let s = onSite, let id = target?.postID, !(s.id == p.siteID && id == p.id) {
                        Text("Already on \(s.displayName) as #\(id)").font(.caption).foregroundColor(.orange)
                    }
                } else if r != nil {
                    Text("No source found").font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Waiting").font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if let s = r?.best?.source {
                Button { if !LinkRouter.open(s) { UIApplication.shared.open(s) }; dismiss() } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
            }
        }
    }

    var reportText: String {
        posts.map { p in
            let r = results[p.key]
            let what = r?.error ?? r?.best.map { "\($0.similarity.map { String(format: "%.0f%%", $0) } ?? "?") \($0.source?.absoluteString ?? "")" } ?? "no source"
            return "#\(p.id) (\(AdapterRegistry.shared.displayName(for: p.siteID))): \(what)"
        }.joined(separator: "\n")
    }

    func runAll() async {
        guard let e = engine else { return }
        running = true; done = 0; results = [:]
        defer { running = false }
        for p in posts {
            if Task.isCancelled { break }
            do {
                let matches = try await ReverseSearch.run(e, post: p)
                results[p.key] = Result(best: matches.first)
            } catch {
                results[p.key] = Result(best: nil, error: error.localizedDescription)
            }
            done += 1
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        DebugLog.log("Reverse", "Mass search: \(posts.count) pictures, \(results.values.filter { $0.best != nil }.count) with matches")
    }
}
