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
    var credentials: Credentials? = nil
}

struct AutoConfigProposal {
    var config: AdapterConfig
    var guesses: FieldGuesses
    /// The first results as JSON objects, for the preview.
    var sampleNodes: [Any]
    /// Pretty-printed answer, so the Field Mapper can be opened on it.
    var rawJSON: String
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

    var title: String {
        switch self {
        case .badAddress: return "That address can't be used"
        case .network: return "Couldn't reach the server"
        case .http(let s, _): return "The server answered with error \(s)"
        case .needsLogin(let s): return "This address needs a login (HTTP \(s))"
        case .loginRejected: return "The server refused the login"
        case .notJSON: return "This looks like a webpage, not a JSON API"
        case .noList: return "Couldn't find a list of results"
        case .noMedia: return "Found a list, but no picture or video addresses in it"
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
        var probe = AdapterConfig.blank()
        probe.baseURL = URL(string: parts.origin)!
        probe.mediaBaseURL = URL(string: parts.origin + "/")!
        probe.searchPath = template
        probe.timeoutSeconds = 30
        probe.headers = input.headers
        probe.tagSeparator = " "
        probe.authStyle = input.authStyle ?? .none
        probe.authParamName = input.authParamName
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
                return .failure(.loginRejected("The server still answered \(response.statusCode) with the login you entered."))
            }
            return .failure(.needsLogin(status: response.statusCode))
        }
        guard (200...299).contains(response.statusCode) else {
            return .failure(.http(status: response.statusCode, body: bodyText))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              json is [String: Any] || json is [Any] else {
            return .failure(.notJSON(snippet: String(bodyText.prefix(160))))
        }
        let raw = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? bodyText

        guard let list = Self.findResultArray(json) else { return .failure(.noList(rawJSON: raw)) }
        guard let items = DottedPath.evaluate(list.path, in: json) as? [Any] else { return .failure(.noList(rawJSON: raw)) }

        var builder = Builder(input: input, parts: parts, json: json, list: list, items: items,
                              loggedIn: input.authStyle != nil && input.authStyle != AuthStyle.none,
                              existingIDs: existingIDs)
        guard builder.build() else { return .failure(.noMedia(rawJSON: raw)) }
        await builder.chooseMediaBase(adapter: adapter)
        builder.finish()
        return .success(AutoConfigProposal(config: builder.config, guesses: builder.guesses,
                                           sampleNodes: Array(items.prefix(5)), rawJSON: raw))
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
        let path = String(after[hostEnd...])
        let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let segments = pathOnly.split(separator: "/").map(String.init)
        if segments.count >= 2, !segments[0].contains("{") {
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
