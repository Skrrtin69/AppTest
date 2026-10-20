import SwiftUI

/// Post details: dimensions, tappable tags, source URL (copy/open), and adapter metadata.
struct InfoPanel: View {
    let post: Post
    let pixelSize: CGSize?
    let onTag: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    @State private var infoTag: InfoTag?
    struct InfoTag: Identifiable { let id = UUID(); let tag: String }
    var adapter: GenericAdapter? { AdapterRegistry.shared.adapter(for: post.siteID) }

    /// The search open in Browse for this post's site (to add to or exclude from).
    var currentQuery: String {
        guard let t = BrowseModel.shared.current, t.siteID == post.siteID else { return "" }
        return t.query.trimmingCharacters(in: .whitespaces)
    }

    func combined(_ term: String) -> String {
        currentQuery.isEmpty ? term : currentQuery + " " + term
    }

    /// Long-press actions on a tag.
    @ViewBuilder
    func tagMenu(_ tag: String, hidden: Bool) -> some View {
        Button { onTag(tag) } label: { Label("Search \(tag)", systemImage: "magnifyingglass") }
        if !currentQuery.isEmpty {
            Button { onTag(combined(tag)) } label: { Label("Add to Current Search", systemImage: "plus.magnifyingglass") }
        }
        Button { onTag(combined("-" + tag)) } label: { Label("Exclude from Search", systemImage: "minus.magnifyingglass") }
        Button {
            UIPasteboard.general.string = tag
            ToastCenter.shared.show("Copied \"\(tag)\"")
        } label: { Label("Copy Tag", systemImage: "doc.on.doc") }
        if adapter?.supportsWiki == true || adapter?.supportsAliases == true {
            Button { infoTag = InfoTag(tag: tag) } label: { Label("About This Tag", systemImage: "info.circle") }
        }
        if hidden {
            Button { settings.blacklist.removeAll { $0.lowercased() == tag.lowercased() } } label: {
                Label("Remove from Blacklist", systemImage: "eye")
            }
        } else {
            Button(role: .destructive) { quickBlacklist(tag) } label: { Label("Blacklist", systemImage: "eye.slash") }
        }
    }

    func quickBlacklist(_ tag: String) {
        let t = tag.lowercased()
        guard !settings.blacklistSet.contains(t) else { return }
        settings.blacklist.append(t)
        Haptics.success()
        ToastCenter.shared.show("Blacklisted \"\(t)\". Remove it in Settings › Tag Blacklist.", style: .success)
    }

    var body: some View {
        NavigationView {
            List {
                Section("Post") {
                    row("Site", AdapterRegistry.shared.displayName(for: post.siteID))
                    row("ID", post.id)
                    row("Type", post.mediaType.label)
                    row("Dimensions", pixelSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "Unknown until loaded")
                    if let u = post.uploader {
                        HStack {
                            Text("Uploader")
                            Spacer()
                            Text(u).foregroundColor(.secondary)
                            let muted = settings.blacklistSet.contains("uploader:" + u.lowercased())
                            Button(muted ? "Muted" : "Mute") {
                                settings.muteUploader(u)
                                ToastCenter.shared.show("Muted \(u). Unmute in Settings › Tag Blacklist.", style: .success)
                            }
                            .buttonStyle(.bordered).disabled(muted)
                        }
                    }
                }
                Section("Tags (tap to search, hold for more)") {
                    if post.tags.isEmpty { Text("No tags").foregroundColor(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(post.tags, id: \.self) { tag in
                            let hidden = settings.blacklistSet.contains(tag.lowercased())
                            // A menu with a primary action: tap searches, long-press shows the
                            // actions. (A .contextMenu here would cover the whole List row, so
                            // every tag would get the first tag's menu.)
                            Menu {
                                tagMenu(tag, hidden: hidden)
                            } label: {
                                Text(tag).strikethrough(hidden).font(.footnote).lineLimit(1)
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(hidden ? Color.red.opacity(0.2) : TagColors.color(for: post.tagCategories?[tag]).opacity(0.22)))
                            } primaryAction: {
                                onTag(tag)
                            }
                            .buttonStyle(.borderless)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Tag \(tag)\(hidden ? ", blacklisted" : "")")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction(named: "Blacklist") { quickBlacklist(tag) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Shown only when the adapter has these addresses.
                if let a = adapter, a.supportsRelated, let first = post.tags.first {
                    RelatedTagsSection(adapter: a, tag: first, onTag: onTag)
                }
                if let a = adapter, a.supportsWiki || a.supportsAliases, !post.tags.isEmpty {
                    Section("About a tag") {
                        ForEach(post.tags, id: \.self) { t in
                            Button { infoTag = InfoTag(tag: t) } label: {
                                HStack { Text(t); Spacer(); Image(systemName: "info.circle") }
                            }
                            .accessibilityLabel("About tag \(t)")
                        }
                    }
                }
                if let cats = post.tagCategories, !cats.isEmpty {
                    Section("Tag colors") {
                        HStack(spacing: 10) {
                            ForEach(Array(Set(cats.values)).sorted(), id: \.self) { c in
                                HStack(spacing: 4) { Circle().fill(TagColors.color(for: c)).frame(width: 9, height: 9); Text(c).font(.caption) }
                            }
                        }
                    }
                }
                Section("Links") {
                    if let s = post.sourceURL {
                        Text(s.absoluteString).font(.footnote).textSelection(.enabled)
                        Button { UIPasteboard.general.string = s.absoluteString; ToastCenter.shared.show("Source URL copied") }
                            label: { Label("Copy Source URL", systemImage: "doc.on.doc") }
                        Button { UIApplication.shared.open(s) } label: { Label("Open Source", systemImage: "safari") }
                    } else {
                        Text("No source URL").foregroundColor(.secondary)
                    }
                    Button { Task { await HashCopier.copyMD5(post) } } label: { Label("Copy MD5", systemImage: "number.square") }
                    Button { UIPasteboard.general.string = post.mediaURL.absoluteString; ToastCenter.shared.show("Media URL copied") }
                        label: { Label("Copy Media URL", systemImage: "link") }
                }
                if !post.metadata.isEmpty {
                    Section("Metadata") {
                        ForEach(post.metadata.keys.sorted(), id: \.self) { k in row(k, post.metadata[k] ?? "") }
                    }
                }
            }
            .sheet(item: $infoTag) { it in
                if let a = adapter { TagInfoSheet(adapter: a, tag: it.tag, onSearch: onTag) }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundColor(.secondary)
            Spacer()
            Text(v).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
