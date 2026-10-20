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
        let adapter = GenericAdapter(config: probe)
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
        if response.statusCode == 401 || response.statusCode == 403 {
            if input.authStyle != nil && input.authStyle != AuthStyle.none {
                let said = ErrorParser.message(from: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
                return .failure(.loginRejected(said.map { "The server said: \($0) (HTTP \(response.statusCode))" }
                                               ?? "The server still answered \(response.statusCode) with the login you entered."))
            }
            return .failure(.needsLogin(status: response.statusCode))
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
        "/posts.json?tags={tags}&page={page}",
        "/api/v1/posts?tags={tags}&page={page}",
    ]
    static let unresolvedMessage = "Couldn't automatically resolve the API address. Please paste the full JSON API URL manually."

    /// Just a site's address: no path, query or placeholders (e.g. https://example.org/).
    static func isBareAddress(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.contains("{"), !s.contains("?"), let parts = splitTemplate(s) else { return false }
        return parts.rest.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
    }

    /// Analyzes the address; a bare site address is first completed with each common API
    /// shape until one answers with JSON. Returns the address actually used when it changed.
    func resolveAndAnalyze(_ input: AutoConfigInput) async -> (result: Result<AutoConfigProposal, AutoConfigFailure>, resolved: String?) {
        guard Self.isBareAddress(input.urlTemplate) else { return (await analyze(input), nil) }
        var origin = input.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        while origin.hasSuffix("/") { origin.removeLast() }
        for t in Self.apiTemplates {
            var attempt = input
            attempt.urlTemplate = origin + t
            let r = await analyze(attempt)
            switch r {
            // A webpage, an error page (404…) or no answer: try the next shape.
            case .failure(.notJSON), .failure(.http), .failure(.network):
                continue
            // JSON (even if it needs a login or a manual field pick): this is the API.
            default:
                return (r, attempt.urlTemplate)
            }
        }
        return (.failure(.badAddress(Self.unresolvedMessage)), nil)
    }
}
