import Foundation

/// How sure Auto-Configure is about one field.
enum Confidence: String, Codable, Comparable {
    case low, medium, high
    static func < (a: Confidence, b: Confidence) -> Bool {
        let order: [Confidence] = [.low, .medium, .high]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
    var label: String { rawValue.capitalized + " confidence" }
}

/// One field's guess: how sure, why, and the value it proposed (to notice later edits).
struct FieldGuess: Codable, Equatable {
    var level: Confidence
    var reason: String
    var value: String
}

typealias FieldGuesses = [AdapterConfig.CodingKeys: FieldGuess]

/// Everything the user typed on the Auto-Configure screen.
struct AutoConfigInput {
    var urlTemplate: String
    var sampleTag: String
    var headers: [String: String] = [:]
    var authStyle: AuthStyle? = nil
    var authParamName: String? = nil
    /// Name of the user-ID address parameter, for sites that want it next to the key.
    var authUserParamName: String? = nil
    var credentials: Credentials? = nil
    /// Probing several possible addresses: short timeout, no retries.
    var quickProbe = false
}

struct AutoConfigProposal {
    var config: AdapterConfig
    var guesses: FieldGuesses
    /// The first results as JSON objects, for the preview.
    var sampleNodes: [Any]
    /// Pretty-printed answer, so the Field Mapper can be opened on it.
    var rawJSON: String
    /// Plain-English access summary and guest-limit hints from the normal search answer.
    var report: [String] = []
}

/// Plain-English failure, each with exactly one next action.
enum AutoConfigFailure: Error, Equatable {
    case badAddress(String)
    case network(String)
    case http(status: Int, body: String)
    case needsLogin(status: Int)
    case loginRejected(String)
    case notJSON(snippet: String)
    case noList(rawJSON: String)
    case noMedia(rawJSON: String)
    case emptyList(path: String)
    /// A Cloudflare check page instead of the API (not a login problem).
    case cloudflare(url: String)

    var title: String {
        switch self {
        case .badAddress: return "That address can't be used"
        case .network: return "Couldn't reach the server"
        case .http(let s, _): return "HTTP \(s)"
        case .needsLogin(let s): return "This address needs a login (HTTP \(s))"
        case .loginRejected: return "The server refused the login"
        case .notJSON: return "This looks like a webpage, not a JSON API"
        case .noList: return "Couldn't find a list of results"
        case .noMedia: return "Found a list, but no picture or video addresses in it"
        case .emptyList: return "0 results"
        case .cloudflare: return "Protected by Cloudflare"
        }
    }

    var message: String {
        switch self {
        case .badAddress(let why): return why
        case .network(let why): return why
        case .http(_, let body): return body.isEmpty ? "The server sent no explanation." : "The server said: \(body)"
        case .needsLogin: return "The server won't answer without a login. MediaDeck doesn't guess which kind, so choose how this site wants it below, fill in your details, and tap Analyze again."
        case .loginRejected(let why): return why
        case .notJSON(let snippet): return "MediaDeck needs the site's data address (an API that answers in JSON), not a page meant for a browser. The answer started with: \(snippet)"
        case .noList: return "Couldn't find a list of results. Open the Field Mapper and pick the list manually."
        case .emptyList(let p): return "The answer has a list (\(p.isEmpty ? "the answer itself" : "'\(p)'")) but it's empty, so there's nothing to learn the fields from."
        case .cloudflare: return "This site is protected by Cloudflare. Tap to verify."
        case .noMedia: return "None of the results contain a web address (http…) or a file path ending in a picture/video type. Open the Field Mapper and pick the addresses manually."
        }
    }

    var nextAction: String {
        switch self {
        case .badAddress: return "Fix the address above, then tap Analyze."
        case .network: return "Check the address and your connection, then tap Analyze again."
        case .http(let s, _): return s == 404 ? "Check the path part of the address, then tap Analyze." : "Check the address, then tap Analyze again."
        case .needsLogin: return "Choose a login style below, enter your details, then tap Analyze."
        case .loginRejected: return "Check the username/password/key below, then tap Analyze."
        case .notJSON: return "Find the site's API address (often contains /api/ or ends in .json) and paste that instead."
        case .noList, .noMedia: return "Open the Field Mapper"
        case .emptyList: return "Use a sample tag that has results (or leave it empty), then tap Analyze."
        case .cloudflare: return "Tap Verify, finish the check on the page, and MediaDeck tries again on its own."
        }
    }
}

/// Turns one search URL into a full AdapterConfig proposal. Site-blind: it only looks at the
/// shape of the JSON and the names of its keys.
struct AutoConfigurator {
    typealias Key = AdapterConfig.CodingKeys
    var existingIDs: Set<String>

    static let mediaExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "webm", "mp4", "mov", "m4v", "avif", "bmp"]
    static let listNames: Set<String> = ["posts", "items", "results", "data", "hits", "entries", "list", "records", "rows", "content", "media", "images", "videos"]
    static let placeholders: Set<String> = ["tags", "page", "cursor", "sort", "rating"]

    // MARK: - Run

    func analyze(_ input: AutoConfigInput) async -> Result<AutoConfigProposal, AutoConfigFailure> {
        let template = input.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = Self.splitTemplate(template) else {
            return .failure(.badAddress("Paste a full address that starts with http:// or https://, for example http://127.0.0.1:8765/a/posts.json?tags={tags}&page={page}"))
        }
        if let unknown = Self.unknownPlaceholders(template).first {
            return .failure(.badAddress("The address contains {\(unknown)}, which MediaDeck doesn't fill in. Allowed: {tags}, {page}, {cursor}, {sort}, {rating}."))
        }

        // Temporary adapter: reuses GenericAdapter's templating, auth headers and NetworkClient.
        guard let originURL = URL(string: parts.origin), let rootURL = URL(string: parts.origin + "/") else {
            return .failure(.badAddress("The host part of the address isn't valid."))
        }
        var probe = AdapterConfig.blank()
        probe.baseURL = originURL
        probe.mediaBaseURL = rootURL
        probe.searchPath = template
        probe.timeoutSeconds = 30
        probe.headers = input.headers
        probe.tagSeparator = " "
        probe.authStyle = input.authStyle ?? .none
        probe.authParamName = AdapterConfig.sanitizeParamName(input.authParamName)
        probe.authUserParamName = AdapterConfig.sanitizeParamName(input.authUserParamName)
        if (input.authStyle == .apiKeyQuery || input.authStyle == .apiKeyHeader), probe.authParamName == nil {
            return .failure(.badAddress("This login style needs the key's name (for example api_key or X-Api-Key). Fill in the Key name field."))
        }
        let adapter: GenericAdapter
        if input.quickProbe {
            let quick = NetworkClient.Config(timeout: Self.probeTimeout, headers: probe.headers, ratePerSecond: 10, retries: 0)
            adapter = GenericAdapter(config: probe, client: NetworkClient(config: quick))
        } else {
            adapter = GenericAdapter(config: probe)
        }
        if let style = input.authStyle, style != .none, let creds = input.credentials {
            do { adapter.session = try await adapter.authenticate(credentials: creds) } catch {
                return .failure(.loginRejected(error.localizedDescription))
            }
        }

        let url: URL
        do {
            let tags = input.sampleTag.split(separator: " ").map(String.init)
            url = try adapter.searchURL(tags: tags, options: SearchOptions(), page: 1)
        } catch {
            return .failure(.badAddress("The address isn't valid once the placeholders are filled in: \(error.localizedDescription)"))
        }

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await adapter.fetchRaw(url)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        let bodyText = String(decoding: data.prefix(500), as: UTF8.self)
        DebugLog.log("Probe", Self.trace(url, response, data))
        // Cloudflare's check page (403/503 + its headers, HTML): not a login problem.
        if Self.isCloudflareCheck(response, data: data) {
            return .failure(.cloudflare(url: url.absoluteString))
        }
        // A 403 that says something else ("Use new API…", a plain 403 page from a
        // proxy) is just an error: the resolver moves on to the next API shape.
        if response.statusCode == 403, !Self.forbiddenMeansLogin(data) {
            return .failure(.http(status: 403,
                                  body: ErrorParser.message(from: data, contentType: response.value(forHTTPHeaderField: "Content-Type")) ?? String(bodyText.prefix(300))))
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            if input.authStyle != nil && input.authStyle != AuthStyle.none {
                let said = ErrorParser.message(from: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
                return .failure(.loginRejected(said.map { "The server said: \($0) (HTTP \(response.statusCode))" }
                                               ?? "The server still answered \(response.statusCode) with the login you entered."))
            }
            return .failure(.needsLogin(status: response.statusCode))
        }
        // Legacy APIs often answer "Missing authentication" as text or HTML, even with 200 OK.
        let isJSONBody = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) is [String: Any]
            || (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) is [Any]
        if !isJSONBody, Self.mentionsAuth(data) {
            return Self.authFailure(input: input, status: response.statusCode, data: data)
        }
        guard (200...299).contains(response.statusCode) else {
            return .failure(.http(status: response.statusCode,
                                  body: ErrorParser.message(from: data, contentType: response.value(forHTTPHeaderField: "Content-Type")) ?? String(bodyText.prefix(500))))
        }
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/html") || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            return .failure(.notJSON(snippet: String(bodyText.prefix(160))))
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .failure(.notJSON(snippet: String(bodyText.prefix(160))))
        }
        guard json is [String: Any] || json is [Any] else {
            return .failure(.notJSON(snippet: String(bodyText.prefix(160))))
        }
        let raw = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? bodyText

        guard let list = Self.findResultArray(json) else {
            // {"success": false, "message": "Missing authentication"} and the like.
            if Self.mentionsAuth(data) { return Self.authFailure(input: input, status: response.statusCode, data: data) }
            if let empty = Self.findEmptyList(json) { return .failure(.emptyList(path: empty)) }
            return .failure(.noList(rawJSON: raw))
        }
        guard let items = DottedPath.evaluate(list.path, in: json) as? [Any] else { return .failure(.noList(rawJSON: raw)) }

        var builder = Builder(input: input, parts: parts, json: json, list: list, items: items,
                              loggedIn: input.authStyle != nil && input.authStyle != AuthStyle.none,
                              existingIDs: existingIDs)
        guard builder.build() else { return .failure(.noMedia(rawJSON: raw)) }
        await builder.chooseMediaBase(adapter: adapter)
        await builder.probeAutocomplete(adapter: adapter)
        await builder.probeFirstPage(adapter: adapter)
        builder.finish()
        return .success(AutoConfigProposal(config: builder.config, guesses: builder.guesses,
                                           sampleNodes: Array(items.prefix(5)), rawJSON: raw,
                                           report: Self.accessReport(loggedIn: input.authStyle != nil && input.authStyle != AuthStyle.none,
                                                                     style: input.authStyle, json: json, items: items,
                                                                     config: builder.config)))
    }

    /// One normal search, read for: public vs login, and guest-limit hints (the site's own words).
    static func accessReport(loggedIn: Bool, style: AuthStyle?, json: Any, items: [Any], config: AdapterConfig) -> [String] {
        var lines: [String] = []
        if loggedIn {
            lines.append("Requires auth: searching worked with your login (\(AuthStylePicker.title(style ?? .none))).")
        } else {
            lines.append("Public: searching works without a login.")
            lines += GuestLimits.check(json: json, items: items, adapter: GenericAdapter(config: config), listPath: config.searchResultsPath)
        }
        return lines
    }

    /// Friendly hints from a server error message (tag limits, user ID requests).
    static func hints(for message: String) -> [String] {
        let m = message.lowercased()
        var out: [String] = []
        if m.contains("tag") && (m.contains("limit") || m.contains("at most") || m.contains("up to") || m.contains("maximum")) {
            out.append("This site limits how many tags you can search at once. Use fewer tags (logging in may raise the limit).")
        }
        if userIDParam(in: message) != nil {
            out.append("The site wants your user ID together with the key. Fill in the User ID field below.")
        }
        if m.contains("rate") || m.contains("too many") || m.contains("slow down") {
            out.append("The site is limiting how fast you can search. Lower Requests per second for this adapter.")
        }
        return out
    }

    /// e.g. "user_id is required" → "user_id".
    static func userIDParam(in message: String) -> String? {
        guard let r = message.range(of: #"\b[a-z]*_?(user_?id|uid)\b"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(message[r]).lowercased()
    }

    // MARK: - Address parts

    struct TemplateParts { let scheme: String; let host: String; let origin: String; let base: String; let rest: String; let firstSegment: String? }

    /// Splits "http://host/seg/more?x={tags}" into origin, base (origin + first segment when the
    /// path has two or more segments) and the rest with placeholders intact. Done on text because
    /// URL() rejects the braces.
    static func splitTemplate(_ t: String) -> TemplateParts? {
        guard let r = t.range(of: "://") else { return nil }
        let scheme = t[..<r.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let after = t[r.upperBound...]
        let hostEnd = after.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? after.endIndex
        let host = String(after[..<hostEnd])
        guard !host.isEmpty, !host.contains(" "), !host.contains("{") else { return nil }
        let origin = "\(scheme)://\(host)"
        guard URL(string: origin) != nil else { return nil }
        let path = String(after[hostEnd...])
        let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let segments = pathOnly.split(separator: "/").map(String.init)
        if segments.count >= 2, !segments[0].contains("{"), URL(string: origin + "/" + segments[0]) != nil {
            let rest = String(path.dropFirst(1 + segments[0].count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return TemplateParts(scheme: scheme, host: host, origin: origin, base: origin + "/" + segments[0], rest: rest, firstSegment: segments[0])
        }
        let rest = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return TemplateParts(scheme: scheme, host: host, origin: origin, base: origin, rest: rest, firstSegment: nil)
    }

    static func unknownPlaceholders(_ t: String) -> [String] {
        var out: [String] = []
        var rest = t[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let name = String(rest[rest.index(after: open)..<close])
            if !placeholders.contains(name) { out.append(name) }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    // MARK: - Finding the result list

    struct ListCandidate { let path: String; let score: Int; let count: Int; let nameMatched: Bool; let sharedKeys: Bool }

    /// Scores every array of objects reachable through objects (not inside other arrays).
    static func findResultArray(_ json: Any) -> ListCandidate? {
        var best: ListCandidate?
        func consider(_ arr: [Any], path: String, key: String, depth: Int) {
            let objects = arr.compactMap { $0 as? [String: Any] }
            guard !objects.isEmpty, objects.count == arr.count else { return }
            var score = 0
            if arr.count >= 3 { score += 3 }
            let shared = Set(objects.prefix(50).map { Set($0.keys) }).count == 1
            if shared { score += 2 }
            let named = listNames.contains(key.lowercased())
            if named { score += 2 }
            if objects.prefix(10).contains(where: { containsURL($0, depth: 0) }) { score += 1 }
            if depth <= 1 { score += 1 }
            let c = ListCandidate(path: path, score: score, count: arr.count, nameMatched: named, sharedKeys: shared)
            if score > 0, score > (best?.score ?? 0) { best = c }
        }
        func walk(_ v: Any, path: String, key: String, depth: Int) {
            if let arr = v as? [Any] {
                consider(arr, path: path, key: key, depth: depth)
            } else if let d = v as? [String: Any], depth < 8 {
                for (k, child) in d {
                    walk(child, path: path.isEmpty ? k : "\(path).\(k)", key: k, depth: depth + 1)
                }
            }
        }
        walk(json, path: "", key: "", depth: 0)
        return best
    }

    /// An empty array with a list-like name (or an empty top-level array): "0 results".
    static func findEmptyList(_ json: Any) -> String? {
        if let a = json as? [Any], a.isEmpty { return "" }
        var found: String?
        func walk(_ v: Any, path: String, depth: Int) {
            guard found == nil, let d = v as? [String: Any], depth < 6 else { return }
            for (k, child) in d {
                let p = path.isEmpty ? k : "\(path).\(k)"
                if let a = child as? [Any], a.isEmpty, listNames.contains(k.lowercased()) { found = p; return }
                walk(child, path: p, depth: depth + 1)
            }
        }
        walk(json, path: "", depth: 0)
        return found
    }

    static func containsURL(_ v: Any, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        switch v {
        case let s as String: return isURLString(s)
        case let d as [String: Any]: return d.values.contains { containsURL($0, depth: depth + 1) }
        case let a as [Any]: return a.prefix(5).contains { containsURL($0, depth: depth + 1) }
        default: return false
        }
    }

    // MARK: - Value tests

    static func isHTTP(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.hasPrefix("http://") || l.hasPrefix("https://") || l.hasPrefix("//")
    }

    static func hasMediaExtension(_ s: String) -> Bool {
        let path = s.split(separator: "?").first.map(String.init) ?? s
        return mediaExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// http(s) address, or a relative path ending in a media extension.
    static func isURLString(_ s: String) -> Bool {
        if isHTTP(s) { return !s.contains(" ") }
        return !s.contains(" ") && s.contains("/") && hasMediaExtension(s)
    }

    static func isExtensionValue(_ s: String) -> Bool {
        let l = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if mediaExtensions.contains(l) { return true }
        return l.range(of: #"^(image|video)/[a-z0-9.+\-]+$"#, options: .regularExpression) != nil
    }

    static func lastKey(_ path: String) -> String {
        (path.split(separator: ".").last.map(String.init) ?? path).lowercased()
    }

    /// Leaf values of an object by dotted path. Arrays are leaves (tags live in arrays).
    static func leaves(_ v: Any, prefix: String = "", depth: Int = 0) -> [String: Any] {
        guard let d = v as? [String: Any], depth < 6 else { return prefix.isEmpty ? [:] : [prefix: v] }
        var out: [String: Any] = [:]
        for (k, child) in d {
            let p = prefix.isEmpty ? k : "\(prefix).\(k)"
            if child is [String: Any] {
                out.merge(leaves(child, prefix: p, depth: depth + 1)) { a, _ in a }
            } else if !(child is NSNull) {
                out[p] = child
            }
        }
        return out
    }

    static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = s.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }
}

// MARK: Smart address resolver

extension AutoConfigurator {
    /// Common API shapes tried, in order, when only a site's address is pasted.
    static let apiTemplates = [
        "/index.php?page=dapi&s=post&q=index&json=1&tags={tags}&pid={page}",
        // Same API in its standard (XML) form: only used if the site answers it with JSON.
        "/index.php?page=dapi&s=post&q=index&tags={tags}&pid={page}",
        "/posts.json?tags={tags}&page={page}",
        "/api/v1/posts?tags={tags}&page={page}",
        "/post.json?tags={tags}&page={page}",
        "/post/index.json?tags={tags}&page={page}",
        "/api/posts?tags={tags}&page={page}",
        // Versioned APIs that replaced the older paths above.
        "/api/v2/search?query={tags}&page={page}",
        "/api/v2/posts?tags={tags}&page={page}",
        // Gallery/album style sites (single galleries at /api/gallery/{id}).
        "/api/galleries/search?query={tags}&page={page}",
    ]
    /// Filled in when nothing answered, for the user to check.
    static let defaultTemplate = "/posts.json?tags={tags}&page={page}"
    static let unresolvedMessage = "Couldn't auto-resolve. Please check this default address."

    static func verdict(_ r: Result<AutoConfigProposal, AutoConfigFailure>) -> String {
        switch r {
        case .success: return "API found"
        case .failure(let f): return f.title
        }
    }

    /// Seconds each address gets while probing.
    static let probeTimeout: Double = 5

    /// "example.org" → "https://example.org"; local addresses ("127.0.0.1:8765",
    /// "192.168.1.5", "localhost") → "http://…". `guessed` is true when https was only
    /// assumed, so http can be tried if the secure connection fails.
    static func normalizeAddress(_ t: String) -> (address: String, guessed: Bool) {
        var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return (s, false) }
        let lower = s.lowercased()
        if lower.contains("://") { return (s, false) }   // has a scheme (others are reported later)
        while s.hasPrefix("/") { s.removeFirst() }
        let host = s.lowercased()
        let local = ["127.", "192.168.", "10.", "localhost"].contains { host.hasPrefix($0) }
        return local ? ("http://" + s, false) : ("https://" + s, true)
    }

    /// The same address over plain http.
    static func httpVersion(_ t: String) -> String? {
        t.lowercased().hasPrefix("https://") ? "http://" + t.dropFirst("https://".count) : nil
    }

    private static func isNetworkFailure(_ r: Result<AutoConfigProposal, AutoConfigFailure>) -> Bool {
        if case .failure(.network) = r { return true }
        return false
    }

    /// Just a site's address: no path, query or placeholders (e.g. https://example.org/).
    static func isBareAddress(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.contains("{"), !s.contains("?"), let parts = splitTemplate(s) else { return false }
        let rest = parts.rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // The site itself, or a folder it lives in (example.org/board): no file name at the end.
        return rest.isEmpty || !(rest.split(separator: "/").last ?? "").contains(".")
    }

    /// A Cloudflare challenge. Every answer from a site behind Cloudflare carries its
    /// headers (Server: cloudflare, cf-ray), even ordinary 403/404 pages, so those alone
    /// mean nothing: it takes `cf-mitigated: challenge`, or a 403/503/429 webpage that is
    /// Cloudflare's own check page.
    static func isCloudflareCheck(_ r: HTTPURLResponse, data: Data) -> Bool {
        if (r.value(forHTTPHeaderField: "cf-mitigated") ?? "").lowercased().contains("challenge") { return true }
        guard [403, 503, 429].contains(r.statusCode) else { return false }
        let server = (r.value(forHTTPHeaderField: "Server") ?? "").lowercased()
        guard r.value(forHTTPHeaderField: "cf-ray") != nil || server.contains("cloudflare") else { return false }
        let html = String(decoding: data.prefix(30_000), as: UTF8.self).lowercased()
        return challengeMarkers.contains { html.contains($0) }
    }

    /// Text found only on Cloudflare's check pages.
    static let challengeMarkers = ["just a moment", "challenge-platform", "cf_chl_", "cf-chl-", "checking your browser",
                                   "verify you are human", "cf-browser-verification", "attention required! | cloudflare",
                                   "captcha"]

    /// A 403 is a login problem when it says so, is JSON (an API's own error), or says nothing.
    static func forbiddenMeansLogin(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(3000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || mentionsAuth(data) { return true }
        if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) is [String: Any] { return true }
        let visible = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression).lowercased()
        return visible.count < 300 && (visible.contains("forbidden") || visible.contains("permission"))
    }

    /// One line for the debug console: status, type, the Cloudflare headers, and the body.
    static func trace(_ url: URL, _ r: HTTPURLResponse, _ data: Data) -> String {
        let h = { (k: String) in r.value(forHTTPHeaderField: k) ?? "–" }
        let body = String(decoding: data.prefix(400), as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(160)
        return "GET \(DebugLog.redact(url)) → \(r.statusCode) \(h("Content-Type")) · server=\(h("Server")) cf-ray=\(r.value(forHTTPHeaderField: "cf-ray") == nil ? "no" : "yes") cf-mitigated=\(h("cf-mitigated")) · \(data.count) bytes: \(body)"
    }

    /// Phrases servers use when a request needs a login or key.
    static let authPhrases = [
        "missing authentication", "authentication required", "requires authentication", "authentication failed",
        "not authenticated", "unauthorized", "unauthorised", "api key required", "api_key required",
        "missing api key", "missing api_key", "invalid api key", "api key is invalid", "login required",
        "log in required", "must be logged in", "please log in", "403 forbidden", "access denied",
    ]

    /// A short answer (an error message, not a whole webpage) that asks for a login.
    static func mentionsAuth(_ data: Data) -> Bool {
        var text = String(decoding: data.prefix(20_000), as: UTF8.self)
        text = text.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let visible = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !visible.isEmpty, visible.count <= 3000 else { return false }
        let lower = visible.lowercased()
        return authPhrases.contains { lower.contains($0) }
    }

    static func authFailure(input: AutoConfigInput, status: Int, data: Data) -> Result<AutoConfigProposal, AutoConfigFailure> {
        if let style = input.authStyle, style != AuthStyle.none {
            let said = String(decoding: data.prefix(300), as: UTF8.self)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.loginRejected("The server said: \(said) (HTTP \(status))"))
        }
        return .failure(.needsLogin(status: status))
    }

    /// Analyzes the address; a bare site address is first completed with each common API
    /// shape until one answers with JSON. Returns the address actually used when it changed.
    func resolveAndAnalyze(_ input: AutoConfigInput, guessedScheme: Bool = false) async -> (result: Result<AutoConfigProposal, AutoConfigFailure>, resolved: String?) {
        guard Self.isBareAddress(input.urlTemplate) else {
            guard guessedScheme, let http = Self.httpVersion(input.urlTemplate) else { return (await analyze(input), nil) }
            // https was only assumed: a quick try, then plain http if it can't connect.
            var quick = input
            quick.quickProbe = true
            let r = await analyze(quick)
            guard Self.isNetworkFailure(r) else { return (r, nil) }
            var plain = input
            plain.urlTemplate = http
            let r2 = await analyze(plain)
            return Self.isNetworkFailure(r2) ? (r, nil) : (r2, http)
        }
        var origin = input.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        while origin.hasSuffix("/") { origin.removeLast() }
        // A folder address (example.org/api) may itself be the API: try it first.
        if let parts = Self.splitTemplate(origin), !parts.rest.isEmpty {
            var asIs = input
            asIs.quickProbe = true
            asIs.urlTemplate = origin
            let r = await analyze(asIs)
            switch r {
            case .failure(.notJSON), .failure(.http), .failure(.network): break
            default: return (r, origin)
            }
        }
        var httpsMayFail = guessedScheme
        for t in Self.apiTemplates {
            var attempt = input
            attempt.quickProbe = true
            attempt.urlTemplate = origin + t
            var r = await analyze(attempt)
            // https was only assumed and couldn't connect: same path over http.
            if httpsMayFail, Self.isNetworkFailure(r), let httpOrigin = Self.httpVersion(origin) {
                attempt.urlTemplate = httpOrigin + t
                let r2 = await analyze(attempt)
                if !Self.isNetworkFailure(r2) {
                    // The site speaks plain http: use it for the remaining paths too.
                    origin = httpOrigin
                    httpsMayFail = false
                    r = r2
                }
            }
            DebugLog.log("Probe", "\(t) → \(Self.verdict(r))")
            switch r {
            // A webpage, an error page (404…) or no answer: try the next shape.
            case .failure(.notJSON), .failure(.http), .failure(.network):
                continue
            // JSON (even if it needs a login or a manual field pick): this is the API.
            default:
                // Gallery-style search: single galleries live next to it.
                if t.hasPrefix("/api/galleries/search"), case .success(var p) = r, p.config.postPath.isEmpty {
                    p.config.postPath = "gallery/{id}"
                    p.guesses[.postPath] = FieldGuess(level: .medium, reason: "Gallery-style API: single galleries are usually at /api/gallery/{id}.",
                                                      value: p.config.jsonValue(for: .postPath))
                    return (.success(p), attempt.urlTemplate)
                }
                return (r, attempt.urlTemplate)
            }
        }
        return (.failure(.badAddress(Self.unresolvedMessage)), origin + Self.defaultTemplate)
    }
}
