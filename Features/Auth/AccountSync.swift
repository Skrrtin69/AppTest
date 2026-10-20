import SwiftUI

/// After an explicit login, reads the account's own settings (if the adapter has an
/// account settings address) and offers them for review before anything is changed.
@MainActor
final class AccountSync: ObservableObject {
    static let shared = AccountSync()

    struct Pending: Identifiable {
        let id = UUID()
        let siteID: String
        let siteName: String
        let tags: [String]
        let sort: String?
        let rating: String?
    }

    @Published var pending: Pending?

    func run(_ adapter: GenericAdapter) async {
        guard adapter.supportsAccountSync else { return }
        do {
            let s = try await adapter.fetchAccountSettings()
            let local = AppSettings.shared.blacklistSet
            let newTags = s.blacklist.filter { !local.contains($0.lowercased()) }
            let sort = s.sort.flatMap { v in adapter.config.sortOptions.first { $0.lowercased() == v.lowercased() } }
            let rating = s.rating.flatMap { v in adapter.config.ratingOptions.first { $0.lowercased() == v.lowercased() } }
            guard !newTags.isEmpty || sort != nil || rating != nil else {
                ToastCenter.shared.show("Your \(adapter.displayName) settings have nothing new to import.")
                return
            }
            pending = Pending(siteID: adapter.id, siteName: adapter.displayName, tags: newTags, sort: sort, rating: rating)
        } catch {
            ToastCenter.shared.error(error, prefix: "Couldn't read your account settings")
        }
    }
}

/// Checklist of the site's own hidden tags (and default sort/rating) before merging.
struct AccountImportSheet: View {
    let pending: AccountSync.Pending
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String>
    @State private var useSort = true
    @State private var useRating = true

    init(pending: AccountSync.Pending) {
        self.pending = pending
        _chosen = State(initialValue: Set(pending.tags))
    }

    var body: some View {
        NavigationView {
            List {
                if !pending.tags.isEmpty {
                    Section {
                        ForEach(pending.tags, id: \.self) { tag in
                            Button {
                                if chosen.contains(tag) { chosen.remove(tag) } else { chosen.insert(tag) }
                            } label: {
                                HStack {
                                    Image(systemName: chosen.contains(tag) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(chosen.contains(tag) ? .accentColor : .secondary)
                                    Text(tag).foregroundColor(.primary)
                                }
                            }
                            .accessibilityLabel("\(tag)\(chosen.contains(tag) ? ", will be hidden" : "")")
                        }
                    } header: { Text("Tags your account hides") } footer: {
                        Text("\(pending.siteName) hides these for your account. Checked tags are added to MediaDeck's blacklist, which applies to every site.")
                    }
                }
                if pending.sort != nil || pending.rating != nil {
                    Section("Defaults for \(pending.siteName)") {
                        if let s = pending.sort { Toggle("Sort: \(s)", isOn: $useSort) }
                        if let r = pending.rating { Toggle("Rating: \(r)", isOn: $useRating) }
                    }
                }
            }
            .navigationTitle("Import Account Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { apply() }.accessibilityIdentifier("importAccountSettings")
                }
            }
        }
    }

    func apply() {
        let settings = AppSettings.shared
        for t in pending.tags where chosen.contains(t) && !settings.blacklistSet.contains(t.lowercased()) {
            settings.blacklist.append(t.lowercased())
        }
        let current = StickyOptions.load(pending.siteID)
        StickyOptions.save(pending.siteID,
                           sort: useSort ? (pending.sort ?? current.sort) : current.sort,
                           rating: useRating ? (pending.rating ?? current.rating) : current.rating)
        ToastCenter.shared.show("Imported \(chosen.count) hidden tag\(chosen.count == 1 ? "" : "s") from \(pending.siteName)", style: .success)
        dismiss()
    }
}
