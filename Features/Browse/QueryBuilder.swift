import SwiftUI

/// Builds a search without typing syntax: tags to include, tags to leave out, sort and
/// rating, with suggestions from the site and a preview of the final search text.
struct QueryBuilderSheet: View {
    @ObservedObject var tab: SearchTabModel
    @Environment(\.dismiss) private var dismiss
    @State private var include: [String] = []
    @State private var exclude: [String] = []
    @State private var input = ""
    @State private var excluding = false
    @State private var sort: String?
    @State private var rating: String?
    @State private var suggestions: [String] = []

    var config: AdapterConfig? { AdapterRegistry.shared.config(for: tab.siteID) }

    /// The search-bar text this builds.
    var query: String {
        (include.map(TagQuery.display) + exclude.map { TagQuery.display("-" + $0) }).joined(separator: " ")
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Add as", selection: $excluding) {
                        Text("Must have").tag(false)
                        Text("Leave out").tag(true)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField(excluding ? "Tag to leave out" : "Tag to include", text: $input)
                            .textInputAutocapitalization(.never).disableAutocorrection(true)
                            .onSubmit { add(input) }
                            .accessibilityIdentifier("builderInput")
                        Button("Add") { add(input) }
                            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("builderAdd")
                    }
                    ForEach(suggestions, id: \.self) { s in
                        Button { add(s) } label: {
                            HStack { Image(systemName: "text.magnifyingglass").foregroundColor(.secondary); Text(s).foregroundColor(.primary) }
                        }
                    }
                } header: { Text("Add a tag") }

                Section("Must have") {
                    if include.isEmpty { Text("No tags: shows everything.").foregroundColor(.secondary) }
                    ForEach(include, id: \.self) { t in chip(t, color: .accentColor) }
                        .onDelete { include.remove(atOffsets: $0) }
                }
                Section("Leave out") {
                    if exclude.isEmpty { Text("Nothing left out.").foregroundColor(.secondary) }
                    ForEach(exclude, id: \.self) { t in chip(t, color: .red) }
                        .onDelete { exclude.remove(atOffsets: $0) }
                }

                if let c = config, !c.sortOptions.isEmpty || !c.ratingOptions.isEmpty {
                    Section("Order and rating") {
                        if !c.sortOptions.isEmpty {
                            Picker("Sort", selection: $sort) {
                                Text("Default").tag(String?.none)
                                ForEach(c.sortOptions, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                        }
                        if !c.ratingOptions.isEmpty {
                            Picker("Rating", selection: $rating) {
                                Text("Any").tag(String?.none)
                                ForEach(c.ratingOptions, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                        }
                    }
                }

                Section {
                    Text(query.isEmpty ? "(everything)" : query)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("builderPreview")
                } header: { Text("Search text") } footer: {
                    Text("This is what goes into the search bar; you can also type it there yourself.")
                }
            }
            .keyboardDoneButton()
            .navigationTitle("Build a Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") {
                        tab.query = query
                        tab.sort = sort
                        tab.rating = rating
                        tab.saveSticky()
                        dismiss()
                        Task { await tab.search() }
                    }
                    .accessibilityIdentifier("builderSearch")
                }
            }
            .onAppear(perform: loadFromTab)
            .task(id: input) { await suggest() }
        }
    }

    func chip(_ t: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(TagTranslations.shared.display(t))
            if TagTranslations.shared.display(t) != t { Text(t).font(.caption).foregroundColor(.secondary) }
        }
    }

    func loadFromTab() {
        for t in TagQuery.parse(tab.query) {
            if t.hasPrefix("-") { exclude.append(String(t.dropFirst())) } else { include.append(t) }
        }
        sort = tab.sort
        rating = tab.rating
    }

    func add(_ raw: String) {
        var t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var leaveOut = excluding
        if t.hasPrefix("-") { leaveOut = true; t.removeFirst() }
        t = TagTranslations.shared.original(t)
        include.removeAll { $0 == t }
        exclude.removeAll { $0 == t }
        if leaveOut { exclude.append(t) } else { include.append(t) }
        input = ""
        suggestions = []
        Haptics.tap()
    }

    func suggest() async {
        let q = input.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let adapter = AdapterRegistry.shared.adapter(for: tab.siteID) else { suggestions = []; return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        suggestions = Array(((try? await adapter.suggest(q)) ?? []).prefix(6))
    }
}
