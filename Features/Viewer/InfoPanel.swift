import SwiftUI

/// Post details: dimensions, tappable tags, source URL (copy/open), and adapter metadata.
struct InfoPanel: View {
    let post: Post
    let pixelSize: CGSize?
    let onTag: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Post") {
                    row("Site", AdapterRegistry.shared.displayName(for: post.siteID))
                    row("ID", post.id)
                    row("Type", post.mediaType.label)
                    row("Dimensions", pixelSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "Unknown until loaded")
                }
                Section("Tags (tap to search)") {
                    if post.tags.isEmpty { Text("No tags").foregroundColor(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(post.tags, id: \.self) { tag in
                            Button { onTag(tag) } label: {
                                Text(tag).font(.footnote).lineLimit(1)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Tag \(tag)")
                        }
                    }
                    .padding(.vertical, 4)
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
                    Button { UIPasteboard.general.string = post.mediaURL.absoluteString; ToastCenter.shared.show("Media URL copied") }
                        label: { Label("Copy Media URL", systemImage: "link") }
                }
                if !post.metadata.isEmpty {
                    Section("Metadata") {
                        ForEach(post.metadata.keys.sorted(), id: \.self) { k in row(k, post.metadata[k] ?? "") }
                    }
                }
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
