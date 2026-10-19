import SwiftUI

/// Runs a search with the config currently on screen and shows the first 5 results.
struct AdapterTestSection: View {
    let makeConfig: () -> (AdapterConfig?, [String])
    /// Optional login step run before searching (Auto-Configure logs in with typed credentials
    /// instead of the Keychain). When nil, stored credentials are used.
    var prepare: ((GenericAdapter) async throws -> Void)? = nil
    /// Changing this value runs the test (lets an outside button trigger it).
    var trigger: Int = 0
    var initialTag: String = ""

    @State private var tag = ""
    @State private var running = false
    @State private var results: [Post] = []
    @State private var error: String?
    @State private var summary: String?
    @State private var rateResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Tag to search (optional)", text: $tag)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("testTagField")
                Button {
                    Task { await run() }
                } label: {
                    if running { ProgressView() } else { Text("Test adapter").bold() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
                .accessibilityIdentifier("runTest")
            }
            if let e = error {
                Label(e, systemImage: "xmark.octagon.fill").foregroundColor(.red).font(.footnote)
                    .accessibilityIdentifier("testError")
            }
            if let s = summary {
                Label(s, systemImage: "checkmark.seal.fill").foregroundColor(.green).font(.footnote)
                    .accessibilityIdentifier("testSummary")
            }
            ForEach(results.prefix(5)) { p in ResultPreviewRow(post: p) }
            Button {
                Task { await rateTest() }
            } label: { Label("Check rate limit (6 quick requests)", systemImage: "speedometer") }
            .buttonStyle(.borderless)
            .disabled(running)
            if let r = rateResult {
                Text(r).font(.footnote).foregroundColor(.secondary).accessibilityIdentifier("rateResult")
            }
        }
        .padding(.vertical, 4)
        .onAppear { if tag.isEmpty { tag = initialTag } }
        .onChange(of: trigger) { _ in Task { await run() } }
    }

    func adapterOrError() -> GenericAdapter? {
        let (cfg, issues) = makeConfig()
        guard let c = cfg else {
            error = "Fix the form first: " + issues.joined(separator: " ")
            return nil
        }
        return GenericAdapter(config: c)
    }

    func run() async {
        error = nil; summary = nil; results = []
        guard let adapter = adapterOrError() else { Haptics.error(); return }
        running = true
        defer { running = false }
        do {
            if let prepare = prepare {
                try await prepare(adapter)
            } else if adapter.requiresAuth || adapter.config.authStyle != .none {
                try await AuthManager.shared.ensureSession(for: adapter)
            }
            let tags = tag.split(separator: " ").map(String.init)
            let r = try await adapter.search(tags: tags, options: SearchOptions(), page: 1)
            results = r.posts
            if r.posts.isEmpty {
                error = "The search worked, but returned no results. Try a different tag, or check 'List of results'."
                Haptics.error()
            } else {
                let types = Dictionary(grouping: r.posts, by: { $0.mediaType }).map { "\($0.value.count) \($0.key.label)" }.joined(separator: ", ")
                summary = "Works! Got \(r.posts.count) results (\(types)). More pages: \(r.hasNextPage ? "yes" : "no")."
                Haptics.success()
            }
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    /// Fires 6 requests at once through the adapter's client and reports how long they took,
    /// which shows the token bucket spacing them out.
    func rateTest() async {
        guard let adapter = adapterOrError() else { return }
        running = true
        defer { running = false }
        let start = Date()
        let rate = adapter.config.rateLimitPerSecond
        var failures = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    do {
                        _ = try await adapter.search(tags: [], options: SearchOptions(), page: 1)
                        return true
                    } catch { return false }
                }
            }
            for await ok in group where !ok { failures += 1 }
        }
        let elapsed = Date().timeIntervalSince(start)
        rateResult = String(format: "6 requests took %.1f s at a limit of %@/s%@.", elapsed,
                            AdapterEditorView.num(rate), failures > 0 ? " (\(failures) failed)" : "")
    }
}

/// Username / password / API key for one adapter, saved in the Keychain.
struct AccountView: View {
    let adapterID: String
    let displayName: String
    let authStyle: AuthStyle
    /// The (possibly unsaved) config from the editor, so logging in works before saving.
    var draft: (() -> AdapterConfig?)? = nil

    @ObservedObject private var auth = AuthManager.shared
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var loaded = false
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Text("Saved securely in the iPhone Keychain, only for \(displayName). The login style (\(authStyle.rawValue)) decides which of these is used.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("Account") {
                CredentialFields(username: $username, password: $password, apiKey: $apiKey)
            }
            Section {
                Button("Save") { save() }.accessibilityIdentifier("acct-save")
                Button {
                    save()
                    Task { await login() }
                } label: { busy ? AnyView(ProgressView()) : AnyView(Text("Save & Log In Now")) }
                .accessibilityIdentifier("acct-login")
                Button("Remove Account", role: .destructive) {
                    do {
                        try auth.saveCredentials(nil, for: adapterID)
                        username = ""; password = ""; apiKey = ""
                        ToastCenter.shared.show("Account removed")
                    } catch { ToastCenter.shared.error(error) }
                }
            }
            Section("Status") {
                Text(statusText).accessibilityIdentifier("acct-status")
            }
        }
        .keyboardDoneButton()
        .navigationTitle("Account")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let c = auth.credentials(for: adapterID) {
                username = c.username; password = c.password ?? ""; apiKey = c.apiKey ?? ""
            }
        }
    }

    func save() {
        do {
            let c = Credentials(username: username, password: password.nonEmpty, apiKey: apiKey.nonEmpty)
            try auth.saveCredentials(c, for: adapterID)
            ToastCenter.shared.show("Account saved", style: .success)
        } catch {
            ToastCenter.shared.error(error, prefix: "Couldn't save account")
        }
    }

    var statusText: String {
        if let s = auth.statuses[adapterID] { return s.label }
        if let cfg = draft?() ?? AdapterRegistry.shared.config(for: adapterID) { return auth.status(for: cfg).label }
        return "Not logged in"
    }

    func login() async {
        let saved = AdapterRegistry.shared.adapter(for: adapterID)
        guard let a = saved ?? draft?().map({ GenericAdapter(config: $0) }) else {
            ToastCenter.shared.show("Fix the adapter's form first, then log in.", style: .error)
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await auth.login(adapter: a)
            ToastCenter.shared.show("Logged in to \(displayName)", style: .success)
        } catch {
            ToastCenter.shared.error(error)
        }
    }
}
