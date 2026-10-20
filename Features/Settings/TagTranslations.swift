import SwiftUI

/// The user's own names for tags ("tag translations"), e.g. a tag in another language shown
/// in yours. Shown on tag chips; typing the translated name in a search sends the original.
/// Stored in Documents/tag_translations.json as { "original": "shown name" }.
final class TagTranslations: ObservableObject {
    static let shared = TagTranslations()
    @Published private(set) var map: [String: String] = [:]
    private var reverse: [String: String] = [:]

    var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tag_translations.json")
    }

    private init() { load() }

    func load() {
        if let data = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([String: String].self, from: data) {
            apply(m)
        }
    }

    private func apply(_ m: [String: String]) {
        var clean: [String: String] = [:]
        for (k, v) in m {
            let key = k.trimmingCharacters(in: .whitespaces).lowercased()
            let val = v.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !val.isEmpty { clean[key] = val }
        }
        map = clean
        reverse = Dictionary(clean.map { ($0.value.lowercased(), $0.key) }, uniquingKeysWith: { a, _ in a })
    }

    func save(_ m: [String: String]) {
        apply(m)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(map) { try? data.write(to: file, options: .atomic) }
    }

    func set(_ original: String, to shown: String?) {
        var m = map
        m[original.lowercased()] = shown?.nonEmpty
        save(m)
    }

    /// The name to show for a tag.
    func display(_ tag: String) -> String { map[tag.lowercased()] ?? tag }

    /// A search word back to the site's tag ("-" kept for excluded tags).
    func original(_ word: String) -> String {
        let neg = word.hasPrefix("-")
        let core = neg ? String(word.dropFirst()) : word
        guard let o = reverse[core.lowercased()] else { return word }
        return neg ? "-" + o : o
    }

    var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(map)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Settings › Browsing › Tag Translations.
struct TagTranslationsView: View {
    @ObservedObject private var store = TagTranslations.shared
    @State private var original = ""
    @State private var shown = ""
    @State private var editingJSON = false

    var body: some View {
        List {
            Section {
                TextField("Tag as the site writes it", text: $original)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityIdentifier("translationOriginal")
                TextField("Name to show instead", text: $shown)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("translationShown")
                Button("Add") {
                    store.set(original, to: shown)
                    original = ""; shown = ""
                }
                .disabled(original.trimmingCharacters(in: .whitespaces).isEmpty || shown.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("translationAdd")
            } footer: {
                Text("Tags show your name instead (the original stays in the tag's menu), and typing your name in a search sends the site's tag.")
            }
            Section("\(store.map.count) translation\(store.map.count == 1 ? "" : "s")") {
                ForEach(store.map.keys.sorted(), id: \.self) { k in
                    HStack {
                        Text(k).font(.body.monospaced())
                        Image(systemName: "arrow.right").foregroundColor(.secondary)
                        Text(store.map[k] ?? "")
                    }
                    .accessibilityElement(children: .combine)
                }
                .onDelete { idx in
                    let keys = store.map.keys.sorted()
                    var m = store.map
                    idx.forEach { m[keys[$0]] = nil }
                    store.save(m)
                }
            }
            Section {
                Button { editingJSON = true } label: { Label("Edit as JSON", systemImage: "curlybraces") }
            } footer: {
                Text("Also in Files › On My iPhone › MediaDeck › tag_translations.json.")
            }
        }
        .keyboardDoneButton()
        .navigationTitle("Tag Translations")
        .sheet(isPresented: $editingJSON) { TranslationsJSONEditor() }
    }
}

struct TranslationsJSONEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = TagTranslations.shared.json
    @State private var error: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let e = error { Text(e).font(.footnote).foregroundColor(.red).padding(8) }
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
            }
            .navigationTitle("Translations JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let m = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else {
                            error = "Not saved: use {\"site tag\": \"your name\", …} with quotes and commas."
                            return
                        }
                        TagTranslations.shared.save(m)
                        dismiss()
                    }
                }
            }
        }
    }
}
