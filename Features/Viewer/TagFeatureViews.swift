import SwiftUI

/// Tags that often appear with `tag` (adapter's relatedTagsPath). Tap one to search it.
struct RelatedTagsSection: View {
    let adapter: GenericAdapter
    let tag: String
    let onTag: (String) -> Void
    @State private var related: [String]?
    @State private var error: String?

    var body: some View {
        Section("Related to \"\(tag)\"") {
            if let e = error {
                Text(e).font(.footnote).foregroundColor(.red)
            } else if let r = related {
                if r.isEmpty { Text("No related tags.").foregroundColor(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(r, id: \.self) { t in
                        Button { onTag(t) } label: {
                            Text(t).font(.footnote).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color.purple.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Related tag \(t)")
                    }
                }
                .padding(.vertical, 4)
            } else {
                ProgressView()
            }
        }
        .task(id: tag) {
            do { related = try await adapter.relatedTags(tag) } catch { self.error = error.localizedDescription }
        }
    }
}

/// A tag's description and other names (wikiPath / tagAliasesPath).
struct TagInfoSheet: View {
    let adapter: GenericAdapter
    let tag: String
    let onSearch: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var wiki: GenericAdapter.TagWiki?
    @State private var aliasesOnly: [String]?
    @State private var error: String?

    var body: some View {
        NavigationView {
            List {
                if let w = wiki {
                    Section(w.title) {
                        if !w.body.isEmpty { Text(w.body).textSelection(.enabled) }
                    }
                    aliasSection(w.aliases)
                } else if let a = aliasesOnly {
                    aliasSection(a)
                } else if let e = error {
                    Text(e).foregroundColor(.secondary)
                } else {
                    ProgressView()
                }
                Section {
                    Button { dismiss(); onSearch(tag) } label: { Label("Search \"\(tag)\"", systemImage: "magnifyingglass") }
                }
            }
            .navigationTitle(tag)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    @ViewBuilder func aliasSection(_ names: [String]) -> some View {
        if !names.isEmpty {
            Section("Also known as") {
                ForEach(names, id: \.self) { n in
                    Button { dismiss(); onSearch(n) } label: { Text(n) }
                }
            }
        }
    }

    func load() async {
        do {
            if adapter.supportsWiki {
                wiki = try await adapter.wiki(tag)
            } else {
                aliasesOnly = try await adapter.aliases(tag)
                if aliasesOnly?.isEmpty == true { error = "No other names for \"\(tag)\"." }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Viewer button for adapters with a vote address. Shows the server's own reply.
struct VoteButton: View {
    let post: Post
    @State private var busy = false

    var body: some View {
        Button {
            guard let adapter = AdapterRegistry.shared.adapter(for: post.siteID) else { return }
            busy = true
            Task {
                defer { busy = false }
                do {
                    try? await AuthManager.shared.ensureSession(for: adapter)
                    let message = try await adapter.vote(post)
                    ToastCenter.shared.show(message, style: .success)
                } catch {
                    ToastCenter.shared.error(error)
                }
            }
        } label: {
            Image(systemName: busy ? "hourglass" : "hand.thumbsup")
        }
        .disabled(busy)
        .accessibilityLabel("Vote")
    }
}
