import SwiftUI

/// Form for every AdapterConfig field, with plain-English help under each one.
struct AdapterEditorView: View {
    typealias Key = AdapterConfig.CodingKeys
    let originalID: String?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = AdapterRegistry.shared
    @State private var c: AdapterConfig
    @State private var baseURLText: String
    @State private var mediaBaseURLText: String
    @State private var rateText: String
    @State private var timeoutText: String
    @State private var firstPageText: String
    @State private var proxyPortText: String
    @State private var videoExtText: String
    @State private var gifExtText: String
    @State private var sortText: String
    @State private var ratingText: String
    @State private var metadataText: String
    @State private var headersText: String
    @State private var altMediaText: String
    @State private var problems: [String] = []
    @State private var showProblems = false
    @State private var confirmDelete = false
    /// Auto-Configure's guesses: shown as a dot + reason under each field while unchanged.
    @State private var guesses: FieldGuesses
    /// Field to scroll to and highlight on open (from the Browse review badge).
    let focus: Key?
    /// When set, Save hands the config back instead of writing adapters.json
    /// (used by Auto-Configure's "Edit fields").
    let onSubmit: ((AdapterConfig) -> Void)?

    init(config: AdapterConfig, isNew: Bool, guesses: FieldGuesses? = nil, focus: Key? = nil,
         onSubmit: ((AdapterConfig) -> Void)? = nil) {
        originalID = isNew ? nil : config.id
        self.focus = focus
        self.onSubmit = onSubmit
        _guesses = State(initialValue: guesses ?? (isNew ? [:] : AdapterReviewStore.shared.guesses(for: config.id)))
        _c = State(initialValue: config)
        _baseURLText = State(initialValue: config.baseURL.absoluteString)
        _mediaBaseURLText = State(initialValue: config.mediaBaseURL.absoluteString)
        _rateText = State(initialValue: Self.num(config.rateLimitPerSecond))
        _timeoutText = State(initialValue: Self.num(config.timeoutSeconds))
        _firstPageText = State(initialValue: String(config.firstPageIndex))
        _proxyPortText = State(initialValue: config.proxyPort.map(String.init) ?? "")
        _videoExtText = State(initialValue: config.videoExtensions.joined(separator: "\n"))
        _gifExtText = State(initialValue: config.gifExtensions.joined(separator: "\n"))
        _sortText = State(initialValue: config.sortOptions.joined(separator: "\n"))
        _ratingText = State(initialValue: config.ratingOptions.joined(separator: "\n"))
        _metadataText = State(initialValue: config.metadataPaths.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n"))
        _headersText = State(initialValue: config.headers.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n"))
        _altMediaText = State(initialValue: config.alternateMediaURLPaths.joined(separator: "\n"))
    }

    static func num(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    var body: some View {
        let current = build().0 ?? c
        let pendingLow = FieldGuide.sections.flatMap { $0.fields }.filter { k in
            guard let g = guesses[k] else { return false }
            return g.level == .low && current.jsonValue(for: k) == g.value
        }
        return ScrollViewReader { proxy in
        Form {
            if !pendingLow.isEmpty {
                Section {
                    ForEach(pendingLow, id: \.self) { k in
                        Button {
                            withAnimation { proxy.scrollTo(k.rawValue, anchor: .top) }
                        } label: {
                            HStack { ConfidenceDot(level: .low); Text(FieldGuide.entry(k).title); Spacer(); Image(systemName: "arrow.down.circle") }
                        }
                        .accessibilityLabel("Review \(FieldGuide.entry(k).title)")
                    }
                    Button("Mark all as reviewed") {
                        for k in pendingLow { guesses[k]?.level = .medium; guesses[k]?.reason = "You reviewed this guess." }
                        if let id = originalID { AdapterReviewStore.shared.set(guesses, for: id) }
                        ToastCenter.shared.show("Marked as reviewed", style: .success)
                    }
                } header: { Text("Needs review") } footer: {
                    Text("Auto-Configure wasn't sure about these. Check each one (the red line explains why); changing a value also clears it.")
                }
            }
            Section {
                AdapterTestSection(makeConfig: { build() })
            } header: { Text("Test adapter") } footer: {
                Text("Runs a real search with the values on this screen (even before saving) and shows the first 5 results.")
            }
            Section("Helpers") {
                NavigationLink(destination: AutoConfigView(mode: .fillForm(keepIdentity: originalID != nil) { cfg, g in apply(cfg, g) })) {
                    Label("Auto-configure from URL", systemImage: "sparkles")
                }
                .accessibilityIdentifier("autoConfigureInForm")
                NavigationLink(destination: FieldMapperView(config: $c)) { Label("Field Mapper — find paths in a sample answer", systemImage: "list.bullet.indent") }
                NavigationLink(destination: AccountView(adapterID: c.id, displayName: c.displayName, authStyle: c.authStyle, draft: { build().0 })) { Label("Account (username / password / key)", systemImage: "person.crop.circle") }
                Menu {
                    ForEach(registry.configs.filter { $0.id.hasPrefix("demo-") }) { ex in
                        Button("Copy settings from \(ex.displayName)") { loadExample(ex) }
                    }
                    Button("Demo Secure (login-protected demo)") { loadExample(.mockSecureExample(port: MockServer.shared.port)) }
                } label: { Label("Fill in from an example…", systemImage: "wand.and.stars") }
            }
            ForEach(FieldGuide.sections, id: \.title) { section in
                Section {
                    ForEach(section.fields, id: \.self) { key in
                        fieldRow(key, current: current) { control(key) }
                            .id(key.rawValue)
                            .listRowBackground(key == focus ? Color.orange.opacity(0.15) : nil)
                    }
                } header: { Text(section.title) } footer: { Text(section.intro) }
            }
            if originalID != nil {
                Section {
                    Button("Delete This Adapter", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .keyboardDoneButton()
        .navigationTitle(originalID == nil ? "Add Adapter" : c.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.accessibilityIdentifier("saveAdapter") }
        }
        .alert("Please fix these first", isPresented: $showProblems) {
            Button("OK", role: .cancel) {}
        } message: { Text(problems.map { "• \($0)" }.joined(separator: "\n")) }
        .confirmationDialog("Delete \(c.displayName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try registry.delete(id: originalID ?? c.id)
                    AdapterReviewStore.shared.clear(originalID ?? c.id)
                    dismiss()
                } catch { ToastCenter.shared.error(error) }
            }
        }
        .onAppear {
            guard let f = focus else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { withAnimation { proxy.scrollTo(f.rawValue, anchor: .top) } }
        }
        }
    }

    // MARK: Rows

    @ViewBuilder
    func fieldRow<Content: View>(_ key: Key, current: AdapterConfig, @ViewBuilder content: () -> Content) -> some View {
        let e = FieldGuide.entry(key)
        let guess = guesses[key].flatMap { current.jsonValue(for: key) == $0.value ? $0 : nil }
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if let g = guess { ConfidenceDot(level: g.level) }
                Text(e.title).font(.subheadline.weight(.semibold))
                if e.required { Text("required").font(.caption2.weight(.bold)).foregroundColor(.orange) }
                Spacer()
                Text(key.rawValue).font(.caption2.monospaced()).foregroundColor(.secondary)
            }
            if let g = guess {
                Text("Auto-Configure (\(g.level.rawValue)): \(g.reason)")
                    .font(.caption).foregroundColor(g.level == .low ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("guess-\(key.rawValue)")
            }
            content()
            Text(e.help).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if !e.example.isEmpty {
                Text("Example: \(e.example.replacingOccurrences(of: "\n", with: " · "))")
                    .font(.caption2.monospaced()).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    func control(_ key: Key) -> some View {
        switch key {
        case .id: plain($c.id, "my-site", id: "field-id")
        case .displayName: plain($c.displayName, "My Site", id: "field-displayName")
        case .baseURL: urlField($baseURLText, id: "field-baseURL") { c.baseURL = $0 }
        case .mediaBaseURL: urlField($mediaBaseURLText, id: "field-mediaBaseURL") { c.mediaBaseURL = $0 }
        case .requiresAuth: Toggle("Requires login", isOn: $c.requiresAuth)
        case .rateLimitPerSecond: number($rateText, "2", id: "field-rate")
        case .searchPath: plain($c.searchPath, "posts.json?tags={tags}&page={page}", id: "field-searchPath")
        case .postPath: plain($c.postPath, "post/{id}.json", id: "field-postPath")
        case .tagSeparator: plain($c.tagSeparator, "+", id: "field-tagSeparator")
        case .firstPageIndex: number($firstPageText, "1", id: "field-firstPage")
        case .sortOptions: lines($sortText)
        case .ratingOptions: lines($ratingText)
        case .searchResultsPath: plain($c.searchResultsPath, "posts", id: "field-searchResultsPath")
        case .postIDPath: plain($c.postIDPath, "id", id: "field-postIDPath")
        case .thumbnailURLPath: plain($c.thumbnailURLPath, "preview_url", id: "field-thumbnailURLPath")
        case .mediaURLPath: plain($c.mediaURLPath, "file_url", id: "field-mediaURLPath")
        case .sampleURLPath: plain(opt(\.sampleURLPath), "sample_url", id: "field-sampleURLPath")
        case .mediaTypePath: plain($c.mediaTypePath, "file_ext", id: "field-mediaTypePath")
        case .tagsPath: plain($c.tagsPath, "tags", id: "field-tagsPath")
        case .tagsNameKey: plain(opt(\.tagsNameKey), "name", id: "field-tagsNameKey")
        case .sourceURLPath: plain(opt(\.sourceURLPath), "source", id: "field-sourceURLPath")
        case .postResultPath: plain(opt(\.postResultPath), "(empty)", id: "field-postResultPath")
        case .metadataPaths: lines($metadataText)
        case .videoExtensions: lines($videoExtText)
        case .gifExtensions: lines($gifExtText)
        case .paginationStyle:
            Picker("Page style", selection: $c.paginationStyle) {
                ForEach(PaginationStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
        case .hasNextPagePath: plain(opt(\.hasNextPagePath), "has_more", id: "field-hasNextPagePath")
        case .cursorPath: plain(opt(\.cursorPath), "next_cursor", id: "field-cursorPath")
        case .authStyle:
            AuthStylePicker(selection: Binding(get: { c.authStyle }, set: { c.authStyle = $0 ?? .none }))
        case .authParamName: plain(opt(\.authParamName), "api_key", id: "field-authParamName")
        case .authCheckPath: plain(opt(\.authCheckPath), "auth/check", id: "field-authCheckPath")
        case .userAgent: plain(opt(\.userAgent), NetworkClient.defaultUserAgent, id: "field-userAgent")
        case .proxyHost: plain(opt(\.proxyHost), "(none)", id: "field-proxyHost")
        case .proxyPort: number($proxyPortText, "(none)", id: "field-proxyPort")
        case .timeoutSeconds: number($timeoutText, "20", id: "field-timeout")
        case .headers: lines($headersText)
        case .alternateMediaURLPaths: lines($altMediaText)
        case .tagSpaceReplacement: plain(opt(\.tagSpaceReplacement), "_", id: "field-tagSpaceReplacement")
        case .autocompletePath: plain(opt(\.autocompletePath), "tags/autocomplete.json?q={query}", id: "field-autocompletePath")
        case .autocompleteResultsPath: plain(opt(\.autocompleteResultsPath), "(the answer itself)", id: "field-autocompleteResultsPath")
        case .autocompleteNameKey: plain(opt(\.autocompleteNameKey), "name", id: "field-autocompleteNameKey")
        case .randomTag: plain(opt(\.randomTag), "order:random", id: "field-randomTag")
        case .relatedTagsPath: plain(opt(\.relatedTagsPath), "tags/related.json?tag={tag}", id: "field-relatedTagsPath")
        case .wikiPath: plain(opt(\.wikiPath), "wiki/{tag}.json", id: "field-wikiPath")
        case .tagAliasesPath: plain(opt(\.tagAliasesPath), "aliases.json?tag={tag}", id: "field-tagAliasesPath")
        case .votePath: plain(opt(\.votePath), "posts/{id}/vote", id: "field-votePath")
        case .accountSettingsPath: plain(opt(\.accountSettingsPath), "account.json", id: "field-accountSettingsPath")
        case .registerURL: plain(opt(\.registerURL), "register", id: "field-registerURL")
        }
    }

    func plain(_ b: Binding<String>, _ placeholder: String, id: String) -> some View {
        TextField(placeholder, text: b)
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .accessibilityIdentifier(id)
    }

    func number(_ b: Binding<String>, _ placeholder: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: b).keyboardType(.decimalPad).accessibilityIdentifier(id)
            if !b.wrappedValue.isEmpty && Double(b.wrappedValue) == nil {
                Text("⚠︎ Must be a number").font(.caption).foregroundColor(.red)
            }
        }
    }

    func lines(_ b: Binding<String>) -> some View {
        TextEditor(text: b)
            .font(.body.monospaced())
            .frame(minHeight: 70)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
    }

    func urlField(_ b: Binding<String>, id: String, apply: @escaping (URL) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("http://…", text: b)
                .font(.body.monospaced())
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .accessibilityIdentifier(id)
                .onChange(of: b.wrappedValue) { v in if let u = Self.validURL(v) { apply(u) } }
            if Self.validURL(b.wrappedValue) == nil {
                Text("⚠︎ Must be a full address starting with http:// or https://").font(.caption).foregroundColor(.red)
            } else {
                Text("✓ Valid address").font(.caption).foregroundColor(.green)
            }
        }
    }

    func opt(_ kp: WritableKeyPath<AdapterConfig, String?>) -> Binding<String> {
        Binding(get: { c[keyPath: kp] ?? "" }, set: { c[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    static func validURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = u.host, !host.isEmpty else { return nil }
        return u
    }

    static func parseLines(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func parsePairs(_ s: String) -> [String: String] {
        var d: [String: String] = [:]
        for line in s.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { d[parts[0]] = parts[1] }
        }
        return d
    }

    // MARK: Build / save

    /// Combines the form into a config and lists anything that must be fixed.
    func build() -> (AdapterConfig?, [String]) {
        var out = c
        var issues: [String] = []
        out.id = c.id.trimmingCharacters(in: .whitespaces)
        if out.id.isEmpty { issues.append("ID is empty.") }
        if out.id.contains(" ") { issues.append("ID can't contain spaces.") }
        if out.displayName.nonEmpty == nil { issues.append("Display name is empty.") }
        if let u = Self.validURL(baseURLText) { out.baseURL = u } else { issues.append("Base address isn't a valid http:// or https:// address.") }
        if let u = Self.validURL(mediaBaseURLText) { out.mediaBaseURL = u } else { issues.append("Media base address isn't a valid address.") }
        if out.searchPath.nonEmpty == nil { issues.append("Search path is empty.") }
        if out.postIDPath.nonEmpty == nil { issues.append("Post ID path is empty.") }
        if out.mediaURLPath.nonEmpty == nil { issues.append("Full media address path is empty.") }
        if let r = Double(rateText), r > 0 { out.rateLimitPerSecond = r } else { issues.append("Requests per second must be a number above 0.") }
        if let t = Double(timeoutText), t > 0 { out.timeoutSeconds = t } else { issues.append("Timeout must be a number above 0.") }
        if let f = Int(firstPageText) { out.firstPageIndex = f } else { issues.append("First page number must be a whole number.") }
        out.authParamName = AdapterConfig.sanitizeParamName(out.authParamName)
        if proxyPortText.nonEmpty == nil { out.proxyPort = nil } else if let p = Int(proxyPortText) { out.proxyPort = p } else { issues.append("Proxy port must be a whole number.") }
        out.videoExtensions = Self.parseLines(videoExtText)
        out.gifExtensions = Self.parseLines(gifExtText)
        out.sortOptions = Self.parseLines(sortText)
        out.ratingOptions = Self.parseLines(ratingText)
        out.metadataPaths = Self.parsePairs(metadataText)
        out.headers = Self.parsePairs(headersText)
        out.alternateMediaURLPaths = Self.parseLines(altMediaText)
        if out.paginationStyle == .cursor && out.cursorPath?.nonEmpty == nil {
            issues.append("Page style is \"cursor\", so the Next-page token path is needed.")
        }
        if (out.authStyle == .apiKeyQuery || out.authStyle == .apiKeyHeader) && out.authParamName?.nonEmpty == nil {
            issues.append("This login style needs a Key name.")
        }
        if originalID != out.id && registry.configs.contains(where: { $0.id == out.id }) {
            issues.append("Another adapter already uses the ID \"\(out.id)\".")
        }
        return (issues.isEmpty ? out : nil, issues)
    }

    func save() {
        let (cfg, issues) = build()
        guard let cfg = cfg else {
            problems = issues
            showProblems = true
            Haptics.error()
            return
        }
        if let submit = onSubmit {
            submit(cfg)
            dismiss()
            return
        }
        do {
            try registry.upsert(cfg, replacing: originalID)
            if let old = originalID, old != cfg.id { AdapterReviewStore.shared.clear(old) }
            if !guesses.isEmpty { AdapterReviewStore.shared.set(guesses, for: cfg.id) }
            ToastCenter.shared.show("Saved \(cfg.displayName)", style: .success)
            dismiss()
        } catch {
            problems = [error.localizedDescription]
            showProblems = true
        }
    }

    /// Auto-Configure "fills the form in place": every field, plus its confidence notes.
    func apply(_ proposal: AdapterConfig, _ g: FieldGuesses) {
        let keepID = c.id, keepName = c.displayName
        setFormFields(from: proposal)
        guesses = g
        if originalID != nil {
            c.id = keepID; c.displayName = keepName
            guesses[.id] = nil; guesses[.displayName] = nil
        }
        ToastCenter.shared.show("Filled in from Auto-Configure. Check any red dots.")
    }

    func setFormFields(from ex: AdapterConfig) {
        c = ex
        baseURLText = ex.baseURL.absoluteString
        mediaBaseURLText = ex.mediaBaseURL.absoluteString
        rateText = Self.num(ex.rateLimitPerSecond)
        timeoutText = Self.num(ex.timeoutSeconds)
        firstPageText = String(ex.firstPageIndex)
        proxyPortText = ex.proxyPort.map(String.init) ?? ""
        videoExtText = ex.videoExtensions.joined(separator: "\n")
        gifExtText = ex.gifExtensions.joined(separator: "\n")
        sortText = ex.sortOptions.joined(separator: "\n")
        ratingText = ex.ratingOptions.joined(separator: "\n")
        metadataText = ex.metadataPaths.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
        headersText = ex.headers.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
        altMediaText = ex.alternateMediaURLPaths.joined(separator: "\n")
    }

    func loadExample(_ ex: AdapterConfig) {
        let keepID = c.id
        let keepName = c.displayName
        setFormFields(from: ex)
        if originalID != nil || !keepID.hasPrefix("new-site") { c.id = keepID; c.displayName = keepName } else {
            c.id = ex.id + "-copy"
            c.displayName = ex.displayName + " Copy"
        }
        ToastCenter.shared.show("Filled in from \(ex.displayName)")
    }
}
