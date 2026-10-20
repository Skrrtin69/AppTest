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
    @State private var loginPage: LoginPage?
    /// Bumped after a key is found on the site, to run Analyze again.
    @State private var reanalyze = 0
    /// The site logs in with a username and password instead of a key.
    @State private var useLogin = false
    @State private var notice: Notice?

    enum Notice: Equatable {
        /// The resolver found nothing and filled in the usual address.
        case checkDefault
        /// Find Key on Page found nothing on this page.
        case keyNotFound(URL?)
        /// Every way of sending the key was refused.
        case keyRejected(tried: [String])
    }
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
                loginSection(proxy)
                Section {
                    Button {
                        Task { if hasLogin { await testConnection(proxy) } else { await analyze(proxy) } }
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
                if let n = notice { noticeSection(n).id("failure") }
                if let p = proposal { proposalSections(p) }
            }
            .safeAreaInset(edge: .bottom) { actionBar(proxy) }
            .onChange(of: reanalyze) { _ in Task { await testConnection(proxy) } }
        }
        .sheet(item: $loginPage) { page in
            ThemedWebPage(url: page.url, onFindKey: { key, user in useFound(key, user) },
                          onNothingFound: { url in
                              notice = .keyNotFound(url)
                              failure = nil
                              showAdvanced = true
                              DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { focused = .credentials }
                          })
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
    struct LoginPage: Identifiable { let id = UUID(); let url: URL }

    /// The site's home (the address up to its first folder), where its login usually starts.
    var siteHome: URL? {
        guard let parts = AutoConfigurator.splitTemplate(urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return URL(string: parts.base + "/")
    }

    /// Fills the login fields with what Find Key on Page picked, then tests the connection.
    func useFound(_ key: KeyFinder.Found, _ user: KeyFinder.Found?) {
        useLogin = false
        notice = nil
        if let name = key.paramName { authParamName = name }
        apiKey = key.value
        if let u = user {
            username = u.value
            if let name = u.paramName { authUserParam = name }
        }
        showAdvanced = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { reanalyze += 1 }
    }

    /// A key, or a username and password, has been entered.
    var hasLogin: Bool { useLogin ? (username.nonEmpty != nil && password.nonEmpty != nil) : apiKey.nonEmpty != nil }

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
                Button("Demo Formats (zip, webp, apng, stream…)") { urlText = "\(o)/u/posts.json?tags={tags}&page={page}"; sampleTag = "" }
                Button("Demo Vault (log in to find the key)") { urlText = "\(o)/v/posts.json?tags={tags}&page={page}"; sampleTag = "blue" }
                Button("Demo Header Key (X-Api-Key only)") { urlText = "\(o)/h/posts.json?tags={tags}&page={page}"; sampleTag = "blue" }
                Button("Demo Gallery (multi-page)") { urlText = "\(o)/g/posts.json?tags={tags}&page={page}"; sampleTag = "comic" }
            } label: { Label("Try a demo address", systemImage: "testtube.2") }
        } header: { Text("Search address") } footer: {
            Text("Paste the address the site's API uses for a search. Put {tags} where the search words go and {page} where the page number goes (or {cursor} if pages use a token). Analyze fills these in with your sample tag and page 1.")
        }
    }

    func loginSection(_ proxy: ScrollViewProxy) -> some View {
        Section {
            if case .keyNotFound(let page) = notice {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Key not found", systemImage: "key.slash").font(.headline).foregroundColor(.orange)
                    Text("We couldn't find your key automatically. You can find it in your Account Settings or Profile page under 'API' or 'Integrations'.")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("keyNotFoundHelp")
                    if let url = page ?? siteHome {
                        Button { loginPage = LoginPage(url: url) } label: {
                            Label("Take me to the settings page", systemImage: "safari").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("openSettingsPage")
                    }
                    Text("On that page, highlight the key and tap Copy Selection, then paste it into the API key field below and tap Test Connection.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            DisclosureGroup(isExpanded: $showAdvanced) {
                if useLogin {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                        .textContentType(.username)
                        .accessibilityIdentifier("autoUsername")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("autoPassword")
                } else {
                    TextField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                        .textContentType(.oneTimeCode)
                        .focused($focused, equals: .credentials)
                        .accessibilityIdentifier("autoApiKey")
                    TextField("User ID (only if the site gives you one)", text: $username)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("autoUserID")
                }
                Button {
                    Task { await testConnection(proxy) }
                } label: {
                    HStack {
                        if running { ProgressView() }
                        Text(running ? "Testing…" : "Test Connection").bold()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(running || !hasLogin || urlText.nonEmpty == nil)
                .accessibilityIdentifier("testConnection")
                Toggle("The site uses a username and password", isOn: $useLogin)
                    .font(.footnote)
                    .accessibilityIdentifier("useLoginToggle")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra headers (one per line, Name = value)").font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $headersText)
                        .font(.caption.monospaced()).frame(minHeight: 50)
                        .focused($focused, equals: .headers)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                }
            } label: {
                Label("Login (optional)", systemImage: "key")
            }
            .accessibilityIdentifier("autoAdvanced")
        } footer: {
            Text(useLogin ? "Test Connection logs in with these details and keeps the adapter if the site accepts them."
                          : "Paste your key and tap Test Connection. MediaDeck tries the usual ways of sending it (in the address, as a Bearer token, as an X-Api-Key header, with your user ID) and keeps the one the site accepts.")
        }
        .id("login")
    }

    // MARK: Notices

    @ViewBuilder
    func noticeSection(_ n: Notice) -> some View {
        switch n {
        case .checkDefault:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Check this address", systemImage: "questionmark.circle.fill").font(.headline).foregroundColor(.orange)
                    Text(AutoConfigurator.unresolvedMessage).font(.subheadline)
                        .accessibilityIdentifier("checkDefault")
                    Text("It's the most common API address. If the site's API lives somewhere else (look for \"API\" in its help pages), paste that address instead, then tap Analyze.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        case .keyRejected(let tried):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Key rejected", systemImage: "xmark.shield.fill").font(.headline).foregroundColor(.red)
                    Text("Key rejected. Check if it requires a User ID alongside it, or if the key has expired.")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("keyRejected")
                    if !tried.isEmpty {
                        Text("Tried: " + tried.joined(separator: " · ")).font(.footnote).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        case .keyNotFound:
            EmptyView()
        }
    }

    // MARK: Failure

    func failureSection(_ f: AutoConfigFailure) -> some View {
        Section {
            switch f {
            case .noList(let raw), .noMedia(let raw):
                ErrorCard(title: f.title, message: f.message, next: f.nextAction, actionTitle: "Open Field Mapper") { mapperRequest = MapperRequest(json: raw) }
            case .needsLogin:
                VStack(alignment: .leading, spacing: 10) {
                    Label("Requires Authentication", systemImage: "lock.fill")
                        .font(.headline).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange))
                        .accessibilityIdentifier("requiresAuth")
                    Text("The address is right, but the site only answers after you log in. Log in on the site and MediaDeck will read your API key from the page and fill in the fields below.")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    if let home = siteHome {
                        Button { loginPage = LoginPage(url: home) } label: {
                            Label("Log in to find my key", systemImage: "person.badge.key")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("loginFindKey")
                    }
                    Text("Or type the key in the API key field below.").font(.footnote).foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
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
        notice = nil
        defer { running = false }
        let normalized = AutoConfigurator.normalizeAddress(urlText)
        urlText = normalized.address
        authStyle = nil
        let input = AutoConfigInput(urlTemplate: urlText, sampleTag: sampleTag,
                                    headers: AdapterEditorView.parsePairs(headersText))
        let (result, resolved) = await AutoConfigurator(existingIDs: Set(registry.configs.map { $0.id })).resolveAndAnalyze(input, guessedScheme: normalized.guessed)
        // Only the site's address was pasted: show the API address that was found (or the usual one).
        if let resolved = resolved { urlText = resolved }
        if case .failure(.badAddress(let m)) = result, m == AutoConfigurator.unresolvedMessage {
            notice = .checkDefault
            Haptics.error()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo("failure", anchor: .top) } }
            return
        }
        switch result {
        case .success(let p):
            proposal = p
            Haptics.success()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo("proposal", anchor: .top) } }
        case .failure(let f):
            failure = f
            Haptics.error()
            // Show the key fields straight away.
            if case .needsLogin = f { showAdvanced = true }
            // The server's own words named its user ID parameter: use that name.
            if let param = AutoConfigurator.userIDParam(in: f.message) {
                showAdvanced = true
                authUserParam = param
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo("failure", anchor: .top) } }
        }
    }

    /// Tries the usual ways of sending the key (or the username and password) and keeps the
    /// first one the site accepts: the adapter is saved and the wizard closes.
    func testConnection(_ proxy: ScrollViewProxy) async {
        focused = nil
        Keyboard.dismiss()
        guard hasLogin else { return }
        running = true
        failure = nil
        proposal = nil
        notice = nil
        defer { running = false }
        let normalized = AutoConfigurator.normalizeAddress(urlText)
        urlText = normalized.address
        let keyParam = authParamName.nonEmpty ?? "api_key"
        let userParam = authUserParam.nonEmpty ?? "user_id"
        typealias Attempt = (label: String, style: AuthStyle, param: String?, userParam: String?)
        var attempts: [Attempt] = []
        if useLogin {
            attempts = [("username and password", .basic, nil, nil)]
        } else {
            attempts = [("\(keyParam)= in the address", .apiKeyQuery, keyParam, nil),
                        ("Authorization: Bearer", .bearer, nil, nil),
                        ("X-Api-Key header", .apiKeyHeader, "X-Api-Key", nil)]
            if username.nonEmpty != nil {
                attempts.append(("\(keyParam)= and \(userParam)= in the address", .apiKeyQuery, keyParam, userParam))
            }
        }
        let creds = useLogin ? Credentials(username: username, password: password.nonEmpty, apiKey: nil)
                             : Credentials(username: username, password: nil, apiKey: apiKey.nonEmpty)
        let configurator = AutoConfigurator(existingIDs: Set(registry.configs.map { $0.id }))
        var tried: [String] = []
        for a in attempts {
            tried.append(a.label)
            let input = AutoConfigInput(urlTemplate: urlText, sampleTag: sampleTag,
                                        headers: AdapterEditorView.parsePairs(headersText),
                                        authStyle: a.style, authParamName: a.param, authUserParamName: a.userParam,
                                        credentials: creds)
            let (result, resolved) = await configurator.resolveAndAnalyze(input, guessedScheme: normalized.guessed)
            DebugLog.log("AuthTester", "\(a.label): \(Self.describe(result))")
            switch result {
            case .success(var p):
                if let resolved = resolved { urlText = resolved }
                keep(a)
                p.report.insert("Connected using \(a.label).", at: 0)
                proposal = p
                Haptics.success()
                save(connectedWith: a.label)
                return
            case .failure(.needsLogin), .failure(.loginRejected), .failure(.http(401, _)), .failure(.http(403, _)):
                continue
            case .failure(.badAddress(let m)) where m == AutoConfigurator.unresolvedMessage:
                // A bare address where no API shape answered, even with the key.
                if let resolved = resolved { urlText = resolved }
                continue
            case .failure(let f):
                // The site answered with this login, but something else needs fixing
                // (or the address itself is wrong): show it.
                if let resolved = resolved { urlText = resolved }
                if Self.siteAnswered(f) { keep(a) }
                failure = f
                Haptics.error()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo("failure", anchor: .top) } }
                return
            }
        }
        notice = .keyRejected(tried: tried)
        Haptics.error()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo("failure", anchor: .top) } }
    }

    /// Remembers the way of logging in that worked (used by Test, Edit fields and Save).
    private func keep(_ a: (label: String, style: AuthStyle, param: String?, userParam: String?)) {
        authStyle = a.style
        authParamName = a.param ?? ""
        authUserParam = a.userParam ?? ""
    }

    /// JSON came back with this login; only the field mapping needs a look.
    private static func siteAnswered(_ f: AutoConfigFailure) -> Bool {
        switch f {
        case .noList, .noMedia, .emptyList: return true
        default: return false
        }
    }

    private static func describe(_ r: Result<AutoConfigProposal, AutoConfigFailure>) -> String {
        switch r {
        case .success: return "accepted"
        case .failure(let f): return f.title
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

    func save(connectedWith method: String? = nil) {
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
            let connected = method.map { "Connected (\($0)). " } ?? ""
            ToastCenter.shared.show(connected + (lows.isEmpty ? "Added \(name)." : "Added \(name). Tap the badge on its tile to review low-confidence fields."), style: .success)
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
