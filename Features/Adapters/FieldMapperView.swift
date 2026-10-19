import SwiftUI

/// Paste a JSON answer, tap Analyze, and see every dotted path with its value.
/// "Copy" puts the path on the clipboard; "Use as…" assigns it to a field of the adapter
/// being edited (when opened from the editor).
struct FieldMapperView: View {
    var config: Binding<AdapterConfig>?

    @State private var input = ""
    @State private var rows: [DottedPath.Row] = []
    @State private var parseError: String?
    @State private var filter = ""
    @State private var fetching = false
    @State private var analyzed = false

    /// `initialJSON` opens the mapper already analyzed (used by Auto-Configure's
    /// "Open Field Mapper" when it couldn't find the list itself).
    init(config: Binding<AdapterConfig>? = nil, initialJSON: String = "") {
        self.config = config
        _input = State(initialValue: initialJSON)
    }

    var filteredRows: [DottedPath.Row] {
        let f = filter.lowercased().trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return rows }
        return rows.filter { $0.path.lowercased().contains(f) || $0.preview.lowercased().contains(f) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste an answer from the site below (it starts with { or [ ), then tap Analyze. Every piece of information gets a path — that's what goes into the adapter's fields.")
                    .font(.footnote).foregroundColor(.secondary)

                TextEditor(text: $input)
                    .font(.caption.monospaced())
                    .frame(height: 170)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.35)))
                    .overlay(alignment: .topLeading) {
                        if input.isEmpty {
                            Text("Paste JSON here…").font(.caption).foregroundColor(.secondary).padding(8).allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("jsonInput")

                HStack {
                    Button { analyze() } label: { Label("Analyze", systemImage: "wand.and.rays") }
                        .buttonStyle(.borderedProminent)
                        .disabled(input.nonEmpty == nil)
                        .accessibilityIdentifier("analyzeButton")
                    Button {
                        input = UIPasteboard.general.string ?? ""
                        analyze()
                    } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                        .buttonStyle(.bordered)
                    Button("Clear") { input = ""; rows = []; parseError = nil; analyzed = false }
                        .buttonStyle(.bordered)
                }

                Menu {
                    if let cfg = config?.wrappedValue {
                        Button("Fetch from this adapter's search address") { Task { await fetchSample(cfg) } }
                    }
                    Button("Demo Site A sample (flat)") { Task { await fetchURL("a/posts.json?page=1") } }
                    Button("Demo Site B sample (nested)") { Task { await fetchURL("b/search?q=") } }
                } label: {
                    Label(fetching ? "Fetching…" : "Get a sample answer…", systemImage: "arrow.down.doc")
                }
                .disabled(fetching)
                .accessibilityIdentifier("getSampleMenu")

                if let e = parseError {
                    Text(e).font(.footnote).foregroundColor(.red).accessibilityIdentifier("parseError")
                }

                if config != nil {
                    Text("Tip: for things inside each result (ID, addresses, tags), tap the row under the first result — for example posts[0].id. The app removes the \"posts[0].\" part for you.")
                        .font(.caption).foregroundColor(.secondary)
                }

                if analyzed {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease")
                        TextField("Filter paths", text: $filter)
                            .textInputAutocapitalization(.never).disableAutocorrection(true)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.14)))
                    Text("\(filteredRows.count) paths").font(.caption).foregroundColor(.secondary)
                        .accessibilityIdentifier("pathCount")
                }

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredRows) { row in
                        PathRowView(row: row, config: config)
                        Divider()
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Field Mapper")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !input.isEmpty && !analyzed { analyze() } }
    }

    func analyze() {
        parseError = nil
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8) else { return }
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            rows = DottedPath.flatten(json)
            analyzed = true
            Haptics.success()
        } catch {
            rows = []
            analyzed = false
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            parseError = "That isn't valid JSON. Make sure you copied the whole answer, starting with { or [ . Details: \(detail)"
            Haptics.error()
        }
    }

    func fetchSample(_ cfg: AdapterConfig) async {
        let adapter = GenericAdapter(config: cfg)
        do {
            let url = try adapter.searchURL(tags: [], options: SearchOptions(), page: 1)
            await fetch(url, adapter: adapter)
        } catch {
            parseError = error.localizedDescription
        }
    }

    func fetchURL(_ path: String) async {
        guard let url = URL(string: MockServer.shared.baseURL.absoluteString + "/" + path) else { return }
        await fetch(url, adapter: nil)
    }

    func fetch(_ url: URL, adapter: GenericAdapter?) async {
        fetching = true
        defer { fetching = false }
        do {
            if let a = adapter, a.requiresAuth || a.config.authStyle != .none {
                try? await AuthManager.shared.ensureSession(for: a)
            }
            let client = adapter?.client ?? NetworkClient.shared
            let (data, _) = try await client.data(for: url)
            if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                input = String(decoding: pretty, as: UTF8.self)
            } else {
                input = String(decoding: data, as: UTF8.self)
            }
            analyze()
        } catch {
            parseError = "Couldn't fetch the sample: \(error.localizedDescription)"
        }
    }
}

struct PathRowView: View {
    let row: DottedPath.Row
    var config: Binding<AdapterConfig>?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.kind).font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(kindColor.opacity(0.2)))
                        .foregroundColor(kindColor)
                    Text(row.path).font(.caption.monospaced().weight(.semibold)).textSelection(.enabled)
                }
                Text(row.preview).font(.caption2.monospaced()).foregroundColor(.secondary).lineLimit(3)
            }
            .padding(.leading, CGFloat(min(row.depth, 8)) * 10)
            Spacer(minLength: 4)
            if !row.path.hasSuffix("[…]") {
                Button {
                    UIPasteboard.general.string = row.path
                    ToastCenter.shared.show("Copied \(row.path)")
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \(row.path)")
                if let binding = config {
                    Menu {
                        ForEach(AdapterConfig.mappableFields, id: \.key) { f in
                            Button {
                                assign(f.key, perPost: f.perPost, in: binding)
                            } label: {
                                Text("\(f.title)  (now: \(binding.wrappedValue[path: f.key]?.nonEmpty ?? "empty"))")
                            }
                        }
                    } label: { Text("Use as…").font(.caption.weight(.semibold)) }
                    .accessibilityLabel("Use as for \(row.path)")
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    var kindColor: Color {
        switch row.kind {
        case "object": return .purple
        case "array": return .orange
        case "string": return .green
        case "number": return .blue
        case "bool": return .pink
        default: return .gray
        }
    }

    func assign(_ key: AdapterConfig.CodingKeys, perPost: Bool, in binding: Binding<AdapterConfig>) {
        var cfg = binding.wrappedValue
        var value = row.path
        if key == .searchResultsPath {
            value = DottedPath.arrayRoot(row.path)
            if value == "[]" { value = "" }
        } else if perPost {
            value = DottedPath.relativize(row.path, toResults: cfg.searchResultsPath)
        }
        if key == .tagsPath, let r = value.range(of: #"\[(\d+|\*)?\]\.([A-Za-z0-9_\-]+)$"#, options: .regularExpression) {
            // "tag_list[0].name" → tags path "tag_list" + name key "name"
            let tail = String(value[r])
            cfg.tagsNameKey = tail.components(separatedBy: ".").last
            value = String(value[..<r.lowerBound])
        } else if key == .tagsPath {
            value = DottedPath.arrayRoot(value)
        }
        cfg[path: key] = value
        binding.wrappedValue = cfg
        let title = AdapterConfig.mappableFields.first { $0.key == key }?.title ?? key.rawValue
        ToastCenter.shared.show("\(title) = \(value.isEmpty ? "(the answer itself)" : value)", style: .success)
    }
}
