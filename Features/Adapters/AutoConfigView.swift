import SwiftUI

enum AutoConfigMode {
    /// From the Adapters list: Save writes a new adapter and opens it in Browse.
    case standalone
    /// From inside the adapter form: the result fills that form in place.
    case fillForm(keepIdentity: Bool, apply: (AdapterConfig, FieldGuesses) -> Void)
}

/// One URL in, a full adapter proposal out — with a confidence dot and a specific reason per field.
struct AutoConfigView: View {
    let mode: AutoConfigMode

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = AdapterRegistry.shared
    @State private var urlText = ""
    @State private var sampleTag = ""
    @State private var showAdvanced = false
    @State private var headersText = ""
    @State private var authStyle: AuthStyle?
    @State private var authParamName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    /// Revealed when the server's error asks for a user ID next to the key.
    @State private var showUserID = false
    @State private var authUserParam = ""
    @State private var running = false
    @State private var failure: AutoConfigFailure?
    @State private var proposal: AutoConfigProposal?
    @State private var testTrigger = 0
    @State private var showEditor = false
    /// Stored (not rebuilt on each render): a fresh Identifiable item per render made SwiftUI
    /// dismiss and re-present the sheet forever.
    @State private var mapperRequest: MapperRequest?
    @FocusState private var focused: Field?

    enum Field: Hashable { case url, tag, headers, keyName, credentials }

    var isFillForm: Bool { if case .fillForm = mode { return true } else { return false } }

    var credentials: Credentials? {
        guard username.nonEmpty != nil || password.nonEmpty != nil || apiKey.nonEmpty != nil else { return nil }
        return Credentials(username: username, password: password.nonEmpty, apiKey: apiKey.nonEmpty)
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                inputSection
                loginSection
                Section {
                    Button {
                        Task { await analyze(proxy) }
                    } label: {
                        HStack {
                            if running { ProgressView() }
                            Text(running ? "Analyzing…" : "Analyze").bold()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || urlText.nonEmpty == nil)
                    .accessibilityIdentifier("autoAnalyze")
                }
                if let f = failure { failureSection(f).id("failure") }
                if let p = proposal { proposalSections(p) }
            }
            .safeAreaInset(edge: .bottom) { actionBar(proxy) }
        }
        .navigationTitle("Auto-Configure")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) {
            if let p = proposal {
                NavigationView {
                    AdapterEditorView(config: p.config, isNew: true, guesses: p.guesses) { edited in applyEdits(edited) }
                }
                .interactiveDismissDisabled(true)
            }
        }
        .sheet(item: $mapperRequest) { req in
            NavigationView {
                FieldMapperView(initialJSON: req.json)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { mapperRequest = nil } } }
            }
        }
        .keyboardDoneButton()
    }

    struct MapperRequest: Identifiable { let id = UUID(); let json: String }

    // MARK: Inputs

    var inputSection: some View {
        Section {
            TextField("http://…/search?tags={tags}&page={page}", text: $urlText)
                .font(.callout.monospaced())
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focused, equals: .url)
                .accessibilityIdentifier("autoURL")
            TextField("Sample tag (a word that has results)", text: $sampleTag)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focused, equals: .tag)
                .submitLabel(.done)
                .accessibilityIdentifier("autoTag")
            Menu {
                let o = MockServer.shared.baseURL.absoluteString
                Button("Demo Site A (flat, page numbers)") { urlText = "\(o)/a/posts.json?tags={tags}&page={page}"; sampleTag = "blue" }
                Button("Demo Site B (nested, cursor)") { urlText = "\(o)/b/search?q={tags}&cursor={cursor}"; sampleTag = "red" }
                Button("Demo Secure (needs a login)") { urlText = "\(o)/a/secure/posts.json?tags={tags}&page={page}"; sampleTag = "green" }
                Button("Demo Site C (unclear field names)") { urlText = "\(o)/c/list.json?tags={tags}&page={page}"; sampleTag = "dots" }
                Button("Demo Site K (key + user ID)") { urlText = "\(o)/k/posts.json?tags={tags}&page={page}"; sampleTag = "red" }
                Button("Demo Members (guest limits)") { urlText = "\(o)/a/members/posts.json?tags={tags}&page={page}"; sampleTag = "red" }
                Button("Demo Gallery (multi-page)") { urlText = "\(o)/g/posts.json?tags={tags}&page={page}"; sampleTag = "comic" }
            } label: { Label("Try a demo address", systemImage: "testtube.2") }
        } header: { Text("Search address") } footer: {
            Text("Paste the address the site's API uses for a search. Put {tags} where the search words go and {page} where the page number goes (or {cursor} if pages use a token). Analyze fills these in with your sample tag and page 1.")
        }
    }

    var loginSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra headers (one per line, Name = value)").font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $headersText)
                        .font(.caption.monospaced()).frame(minHeight: 50)
                        .focused($focused, equals: .headers)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                }
                Text("Login style — MediaDeck never guesses this").font(.caption).foregroundColor(.secondary)
                AuthStylePicker(selection: $authStyle)
                if authStyle == .apiKeyQuery || authStyle == .apiKeyHeader {
                    TextField(authStyle == .apiKeyQuery ? "Key name in the address (e.g. api_key)" : "Header name (e.g. X-Api-Key)", text: $authParamName)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                        .focused($focused, equals: .keyName)
                        .accessibilityIdentifier("autoAuthParam")
                }
                if authStyle == .basic {
                    CredentialFields(username: $username, password: $password, apiKey: $apiKey)
                } else if let s = authStyle, s != .none {
                    TextField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("autoApiKey")
                    if showUserID || !authUserParam.isEmpty {
                        TextField("User ID", text: $username)
                            .textInputAutocapitalization(.never).disableAutocorrection(true)
                            .textContentType(.oneTimeCode)
                            .accessibilityIdentifier("autoUserID")
                        TextField("User ID name in the address (e.g. user_id)", text: $authUserParam)
                            .textInputAutocapitalization(.never).disableAutocorrection(true)
                            .accessibilityIdentifier("autoUserParam")
                    } else {
                        Button("The site also needs a user ID") { showUserID = true; if authUserParam.isEmpty { authUserParam = "user_id" } }
                            .font(.footnote)
                    }
                }
            } label: {
                Label("Headers & login (optional)", systemImage: "key")
            }
            .accessibilityIdentifier("autoAdvanced")
        }
        .id("login")
    }

    // MARK: Failure

    func failureSection(_ f: AutoConfigFailure) -> some View {
        Section {
            switch f {
            case .noList(let raw), .noMedia(let raw):
                ErrorCard(title: f.title, message: f.message, next: f.nextAction, actionTitle: "Open Field Mapper") { mapperRequest = MapperRequest(json: raw) }
            case .needsLogin:
                ErrorCard(title: f.title, message: f.message, next: f.nextAction, actionTitle: "Show login options") { showAdvanced = true }
            default:
                ErrorCard(title: f.title, message: f.message, next: f.nextAction)
            }
            ForEach(AutoConfigurator.hints(for: f.message), id: \.self) { hint in
                Label(hint, systemImage: "lightbulb").font(.footnote)
            }
        }
    }

    // MARK: Proposal

    @ViewBuilder
    func proposalSections(_ p: AutoConfigProposal) -> some View {
        let counts = Dictionary(grouping: p.guesses.values, by: { $0.level }).mapValues { $0.count }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(p.config.displayName)").font(.headline)
                HStack(spacing: 14) {
                    HStack(spacing: 4) { ConfidenceDot(level: .high); Text("\(counts[.high] ?? 0) sure") }
                    HStack(spacing: 4) { ConfidenceDot(level: .medium); Text("\(counts[.medium] ?? 0) likely") }
                    HStack(spacing: 4) { ConfidenceDot(level: .low); Text("\(counts[.low] ?? 0) need a look") }
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("autoSummary")
            }
            ForEach(p.report, id: \.self) { line in
                Label(line, systemImage: line.hasPrefix("Public") || line.hasPrefix("Requires auth") ? "person.crop.circle.badge.checkmark" : "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundColor(line.hasPrefix("Public") || line.hasPrefix("Requires auth") ? .primary : .orange)
            }
            .accessibilityIdentifier("accessReport")
        } header: { Text("Proposal") } footer: {
            Text("Every field says why it was chosen. Red dots are guesses you should check — tap Edit fields to change anything.")
        }
        .id("proposal")

        ForEach(FieldGuide.sections, id: \.title) { section in
            Section(section.title) {
                ForEach(section.fields, id: \.self) { key in
                    GuessRow(key: key, value: p.config.jsonValue(for: key), guess: p.guesses[key])
                }
            }
        }

        Section {
            let adapter = GenericAdapter(config: p.config)
            ForEach(Array(p.sampleNodes.enumerated()), id: \.offset) { i, node in
                let problems = adapter.diagnose(node)
                if problems[.postIDPath] == nil, problems[.mediaURLPath] == nil, let post = adapter.mapPost(node) {
                    ResultPreviewRow(post: post, warnings: problems.values.sorted())
                } else {
                    FailedResultRow(index: i, problems: problems)
                }
            }
        } header: { Text("Preview — first \(p.sampleNodes.count) results") } footer: {
            Text("Built from the answer Analyze downloaded, using the proposal above.")
        }

        Section {
            AdapterTestSection(makeConfig: { (proposal?.config, []) }, prepare: prepare, trigger: testTrigger, initialTag: sampleTag)
        } header: { Text("Test adapter") } footer: {
            Text("Runs a real search with the proposal, exactly like the adapter form's test.")
        }
        .id("test")
    }

    // MARK: Action bar

    func actionBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Button(isFillForm ? "Use in form" : "Save adapter") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(proposal == nil)
                .accessibilityIdentifier("autoSave")
            Button("Test") {
                testTrigger += 1
                withAnimation { proxy.scrollTo("test", anchor: .top) }
            }
            .buttonStyle(.bordered)
            .disabled(proposal == nil)
            .accessibilityIdentifier("autoTest")
            Button("Edit fields") { showEditor = true }
                .buttonStyle(.bordered)
                .disabled(proposal == nil)
                .accessibilityIdentifier("autoEdit")
            Spacer(minLength: 0)
            // No Cancel here: Back already leaves, and a Cancel next to the keyboard wiped forms.
            Button("Done") { focused = nil; Keyboard.dismiss() }
                .accessibilityIdentifier("autoDone")
        }
        .font(.subheadline)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Actions

    func analyze(_ proxy: ScrollViewProxy) async {
        focused = nil
        Keyboard.dismiss()
        running = true
        failure = nil
        proposal = nil
        defer { running = false }
        let input = AutoConfigInput(urlTemplate: urlText, sampleTag: sampleTag,
                                    headers: AdapterEditorView.parsePairs(headersText),
                                    authStyle: authStyle, authParamName: authParamName.nonEmpty,
                                    authUserParamName: (showUserID || !authUserParam.isEmpty) ? authUserParam.nonEmpty : nil,
                                    credentials: credentials)
        let result = await AutoConfigurator(existingIDs: Set(registry.configs.map { $0.id })).analyze(input)
        switch result {
        case .success(let p):
            proposal = p
            Haptics.success()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo("proposal", anchor: .top) } }
        case .failure(let f):
            failure = f
            Haptics.error()
            if case .needsLogin = f { showAdvanced = true }
            // The server's own words asked for a user ID: show that field, named as the server said.
            if let param = AutoConfigurator.userIDParam(in: f.message) {
                showUserID = true
                showAdvanced = true
                if authUserParam.isEmpty { authUserParam = param }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo("failure", anchor: .top) } }
        }
    }

    /// Logs the temporary adapter in with the typed credentials (nothing is saved yet).
    func prepare(_ adapter: GenericAdapter) async throws {
        guard let style = authStyle, style != .none else { return }
        guard let creds = credentials else { throw AppError.missingCredentials(adapter.displayName) }
        adapter.session = try await adapter.authenticate(credentials: creds)
    }

    /// Fields changed in "Edit fields" become the user's own choice.
    func applyEdits(_ edited: AdapterConfig) {
        guard var p = proposal else { return }
        for k in AdapterConfig.CodingKeys.allCases {
            let v = edited.jsonValue(for: k)
            if p.guesses[k]?.value != v {
                p.guesses[k] = FieldGuess(level: .high, reason: "You set this yourself in Edit fields.", value: v)
            }
        }
        p.config = edited
        proposal = p
        ToastCenter.shared.show("Proposal updated", style: .success)
    }

    func save() {
        guard var p = proposal else { return }
        if case .fillForm(_, let apply) = mode {
            apply(p.config, p.guesses)
            dismiss()
            return
        }
        // Another adapter may have taken the id since Analyze ran.
        let base = p.config.id
        var n = 2
        while registry.configs.contains(where: { $0.id == p.config.id }) { p.config.id = "\(base)-\(n)"; n += 1 }
        p.guesses[.id] = FieldGuess(level: p.guesses[.id]?.level ?? .high, reason: p.guesses[.id]?.reason ?? "", value: p.config.jsonValue(for: .id))
        do {
            try registry.upsert(p.config)
        } catch {
            ToastCenter.shared.error(error, prefix: "Couldn't save")
            return
        }
        if p.config.authStyle != .none, let creds = credentials {
            do { try AuthManager.shared.saveCredentials(creds, for: p.config.id) } catch {
                ToastCenter.shared.error(error, prefix: "Saved the adapter, but not the login")
            }
        }
        AdapterReviewStore.shared.set(p.guesses, for: p.config.id)
        let lows = AdapterReviewStore.shared.pendingLowFields(for: p.config)
        let name = p.config.displayName
        let id = p.config.id
        dismiss()
        // Switch tabs only after the pop finishes: doing both at once crashed SwiftUI's
        // navigation controller on iOS 16 (seen on device).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            AppRouter.shared.tab = .browse
            BrowseModel.shared.openTab(siteID: id, query: "")
            ToastCenter.shared.show(lows.isEmpty ? "Added \(name)." : "Added \(name). Tap the badge on its tile to review low-confidence fields.", style: .success)
        }
    }
}

/// One proposed field: dot, name, value and the specific reason.
struct GuessRow: View {
    let key: AdapterConfig.CodingKeys
    let value: String
    let guess: FieldGuess?

    var shownValue: String {
        if value == "null" || value == "\"\"" || value == "[]" || value == "{}" { return "(empty)" }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { return String(value.dropFirst().dropLast()) }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if let g = guess { ConfidenceDot(level: g.level) }
                Text(FieldGuide.entry(key).title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(shownValue).font(.caption.monospaced()).lineLimit(2).multilineTextAlignment(.trailing)
            }
            if let g = guess {
                Text(g.reason).font(.caption).foregroundColor(g.level == .low ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(guess?.level == .low ? Color.red.opacity(0.08) : nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(FieldGuide.entry(key).title): \(shownValue). \(guess?.level.label ?? ""). \(guess?.reason ?? "")")
        .accessibilityIdentifier("guess-\(key.rawValue)")
    }
}
