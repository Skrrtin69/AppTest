import SwiftUI

/// A collection that fills itself from favorites matching rules (sites, tags, type,
/// uploader, how recently added). Stored in UserDefaults; included in backups.
struct SmartCollection: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var sites: [String] = []
    var allTags: [String] = []
    var anyTags: [String] = []
    var noneTags: [String] = []
    var types: [String] = []
    var uploader: String = ""
    var addedWithinDays: Int = 0

    func matches(_ f: FavoriteItem) -> Bool {
        let p = f.post
        let tags = Set(p.tags.map { $0.lowercased() })
        if !sites.isEmpty && !sites.contains(p.siteID) { return false }
        if !allTags.allSatisfy({ tags.contains($0.lowercased()) }) { return false }
        if !anyTags.isEmpty && !anyTags.contains(where: { tags.contains($0.lowercased()) }) { return false }
        if noneTags.contains(where: { tags.contains($0.lowercased()) }) { return false }
        if !types.isEmpty && !types.contains(p.mediaType.rawValue) { return false }
        if let u = uploader.nonEmpty, p.uploader?.lowercased() != u.lowercased() { return false }
        if addedWithinDays > 0, f.createdAt < Date().addingTimeInterval(-Double(addedWithinDays) * 86_400) { return false }
        return true
    }

    /// One line describing the rules.
    var summary: String {
        var parts: [String] = []
        if !sites.isEmpty { parts.append(sites.map { AdapterRegistry.shared.displayName(for: $0) }.joined(separator: " or ")) }
        if !allTags.isEmpty { parts.append("all of " + allTags.joined(separator: ", ")) }
        if !anyTags.isEmpty { parts.append("any of " + anyTags.joined(separator: ", ")) }
        if !noneTags.isEmpty { parts.append("none of " + noneTags.joined(separator: ", ")) }
        if !types.isEmpty { parts.append(types.joined(separator: "/")) }
        if let u = uploader.nonEmpty { parts.append("by " + u) }
        if addedWithinDays > 0 { parts.append("added in the last \(addedWithinDays) days") }
        return parts.isEmpty ? "Every favorite" : parts.joined(separator: " · ")
    }
}

final class SmartCollectionStore: ObservableObject {
    static let shared = SmartCollectionStore()
    private let key = "smartCollections"
    @Published private(set) var items: [SmartCollection] = []

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([SmartCollection].self, from: d) { items = l }
    }

    func save(_ c: SmartCollection) {
        if let i = items.firstIndex(where: { $0.id == c.id }) { items[i] = c } else { items.append(c) }
        persist()
    }

    func delete(_ id: String) { items.removeAll { $0.id == id }; persist() }

    func posts(for c: SmartCollection) -> [Post] {
        LibraryStore.shared.favorites.filter(c.matches).map(\.post)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }

    func backupJSON() -> Any {
        (try? JSONEncoder().encode(items)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
    }

    func merge(_ json: Any) -> Int {
        guard let d = try? JSONSerialization.data(withJSONObject: json),
              let list = try? JSONDecoder().decode([SmartCollection].self, from: d) else { return 0 }
        let have = Set(items.map(\.id))
        let new = list.filter { !have.contains($0.id) }
        items.append(contentsOf: new)
        persist()
        return new.count
    }
}

struct SmartCollectionDetailView: View {
    let collection: SmartCollection
    @ObservedObject private var store = SmartCollectionStore.shared
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var viewer: ViewerRequest?
    @State private var collectionBatch: PostBatch?
    @State private var editing: SmartCollection?

    var current: SmartCollection { store.items.first { $0.id == collection.id } ?? collection }
    var posts: [Post] { store.posts(for: current).filter { !settings.isBlacklisted($0) } }

    var body: some View {
        VStack(spacing: 4) {
            Text(current.summary).font(.footnote).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            if posts.isEmpty {
                EmptyStateView(icon: "sparkles", title: "No matching favorites",
                               message: "Favorites that match these rules appear here automatically.")
            } else {
                ScrollView {
                    PostGrid(posts: posts, onTap: { viewer = ViewerRequest(posts: posts, index: $0) },
                             onAddToCollection: { collectionBatch = PostBatch(posts: $0) }) { EmptyView() }
                }
            }
        }
        .navigationTitle(current.name)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Edit") { editing = current } } }
        .fullScreenCover(item: $viewer) { ViewerView(posts: $0.posts, startIndex: $0.index) }
        .sheet(item: $collectionBatch) { CollectionPickerSheet(posts: $0.posts) }
        .sheet(item: $editing) { SmartCollectionEditor(collection: $0) }
    }
}

struct SmartCollectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var collection: SmartCollection
    @State private var allText = ""
    @State private var anyText = ""
    @State private var noneText = ""

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var preview: Int {
        var c = collection
        c.allTags = Self.words(allText); c.anyTags = Self.words(anyText); c.noneTags = Self.words(noneText)
        return LibraryStore.shared.favorites.filter(c.matches).count
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("Name", text: $collection.name).accessibilityIdentifier("smartName")
                Section {
                    field("Has all of", $allText)
                    field("Has any of", $anyText)
                    field("Has none of", $noneText)
                } header: { Text("Tags") } footer: { Text("Separate tags with spaces or commas.") }
                Section("Sites (none ticked = every site)") {
                    ForEach(AdapterRegistry.shared.listedConfigs) { c in
                        Toggle(c.displayName, isOn: Binding(get: { collection.sites.contains(c.id) }, set: { on in
                            if on { collection.sites.append(c.id) } else { collection.sites.removeAll { $0 == c.id } }
                        }))
                    }
                }
                Section("Type (none ticked = every type)") {
                    ForEach([MediaType.image, .gif, .video], id: \.self) { t in
                        Toggle(t.label, isOn: Binding(get: { collection.types.contains(t.rawValue) }, set: { on in
                            if on { collection.types.append(t.rawValue) } else { collection.types.removeAll { $0 == t.rawValue } }
                        }))
                    }
                }
                Section("More") {
                    TextField("Uploader (optional)", text: $collection.uploader)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                    Picker("Added", selection: $collection.addedWithinDays) {
                        Text("Any time").tag(0)
                        Text("Last 7 days").tag(7)
                        Text("Last 30 days").tag(30)
                        Text("Last 365 days").tag(365)
                    }
                }
                Section { Text("\(preview) favorite\(preview == 1 ? "" : "s") match right now").foregroundColor(.secondary) }
            }
            .keyboardDoneButton()
            .navigationTitle("Smart Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        collection.allTags = Self.words(allText)
                        collection.anyTags = Self.words(anyText)
                        collection.noneTags = Self.words(noneText)
                        SmartCollectionStore.shared.save(collection)
                        dismiss()
                    }
                    .disabled(collection.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("smartSave")
                }
            }
            .onAppear {
                allText = collection.allTags.joined(separator: " ")
                anyText = collection.anyTags.joined(separator: " ")
                noneText = collection.noneTags.joined(separator: " ")
            }
        }
    }

    func field(_ title: String, _ b: Binding<String>) -> some View {
        TextField(title, text: b).textInputAutocapitalization(.never).disableAutocorrection(true)
            .accessibilityIdentifier("smart-" + title)
    }
}
