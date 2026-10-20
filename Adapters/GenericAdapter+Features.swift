import Foundation

/// Optional site features. Each is only offered in the UI when its address is configured.
extension GenericAdapter {
    struct TagWiki {
        let title: String
        let body: String
        let aliases: [String]
    }

    struct AccountSettings {
        var blacklist: [String] = []
        var sort: String?
        var rating: String?
    }

    var supportsRelated: Bool { config.relatedTagsPath?.nonEmpty != nil }
    var supportsWiki: Bool { config.wikiPath?.nonEmpty != nil }
    var supportsAliases: Bool { config.tagAliasesPath?.nonEmpty != nil }
    var supportsVoting: Bool { config.votePath?.nonEmpty != nil }
    var supportsAccountSync: Bool { config.accountSettingsPath?.nonEmpty != nil }

    func relatedTags(_ tag: String) async throws -> [String] {
        guard let p = config.relatedTagsPath?.nonEmpty else { return [] }
        let json = try await fetchJSON(try buildURL(path: p, vars: ["tag": Self.encode(prepareTag(tag))]))
        return Self.wordList(json).filter { $0.lowercased() != tag.lowercased() }
    }

    func aliases(_ tag: String) async throws -> [String] {
        guard let p = config.tagAliasesPath?.nonEmpty else { return [] }
        let json = try await fetchJSON(try buildURL(path: p, vars: ["tag": Self.encode(prepareTag(tag))]))
        return Self.wordList(json)
    }

    func wiki(_ tag: String) async throws -> TagWiki {
        guard let p = config.wikiPath?.nonEmpty else { throw AppError.message("This site has no tag descriptions set up.") }
        let json = try await fetchJSON(try buildURL(path: p, vars: ["tag": Self.encode(prepareTag(tag))]))
        let body = Self.firstString(in: json, keys: ["body", "text", "description", "content", "summary", "extract"]) ?? ""
        let title = Self.firstString(in: json, keys: ["title", "name"]) ?? tag
        let names = supportsAliases ? ((try? await aliases(tag)) ?? []) : []
        guard !body.isEmpty || !names.isEmpty else { throw AppError.message("The site has no description for \"\(tag)\" yet.") }
        return TagWiki(title: title, body: body, aliases: names)
    }

    /// Sends an up-vote (POST). Returns the server's own message.
    func vote(_ post: Post) async throws -> String {
        guard let p = config.votePath?.nonEmpty else { throw AppError.message("Voting isn't set up for this site.") }
        var request = URLRequest(url: try buildURL(path: p, vars: ["id": Self.encode(post.id)]))
        request.httpMethod = "POST"
        for (k, v) in config.headers { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in authHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await client.data(for: request)
        return ErrorParser.message(from: data, contentType: resp.value(forHTTPHeaderField: "Content-Type")) ?? "Vote sent."
    }

    /// The logged-in user's settings: blacklist, default sort and rating, wherever they sit.
    func fetchAccountSettings() async throws -> AccountSettings {
        guard let p = config.accountSettingsPath?.nonEmpty else { return AccountSettings() }
        let json = try await fetchJSON(try buildURL(path: p, vars: [:]))
        return Self.parseAccountSettings(json)
    }

    var registrationURL: URL? {
        guard let r = config.registerURL?.nonEmpty else { return nil }
        if r.lowercased().hasPrefix("http") { return URL(string: r) }
        return URL(string: Self.join(config.baseURL.absoluteString, r))
    }

    // MARK: Generic JSON readers

    static func parseAccountSettings(_ json: Any) -> AccountSettings {
        var out = AccountSettings()
        func walk(_ v: Any, depth: Int) {
            guard depth < 6, let d = v as? [String: Any] else { return }
            for (k, child) in d {
                let key = k.lowercased()
                if out.blacklist.isEmpty, ["blacklist", "blocked", "muted", "hidden_tags", "filtered_tags", "excluded_tags"].contains(where: { key.contains($0) }) {
                    if let s = child as? String {
                        out.blacklist = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," }).map(String.init)
                    } else if let a = child as? [Any] {
                        out.blacklist = a.compactMap { DottedPath.stringValue($0) ?? DottedPath.stringValue(($0 as? [String: Any])?["name"]) }
                    }
                } else if out.sort == nil, ["default_sort", "sort_order", "sort", "order"].contains(key), let s = child as? String {
                    out.sort = s
                } else if out.rating == nil, ["default_rating", "rating", "content_rating"].contains(key), let s = child as? String {
                    out.rating = s
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(json, depth: 0)
        out.blacklist = out.blacklist.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return out
    }

    /// A list of words: plain strings, or objects with a name-like key, anywhere sensible.
    static func wordList(_ json: Any) -> [String] {
        guard let found = AutoConfigurator.Builder.suggestionList(json) else { return [] }
        let list = DottedPath.evaluate(found.path, in: json) as? [Any] ?? []
        return list.compactMap { item in
            if let s = item as? String { return s }
            guard let d = item as? [String: Any] else { return nil }
            return DottedPath.stringValue(d[found.nameKey ?? "name"])
        }
    }

    static func firstString(in json: Any, keys: [String]) -> String? {
        var found: String?
        func walk(_ v: Any, depth: Int) {
            guard found == nil, depth < 5, let d = v as? [String: Any] else { return }
            for k in keys { if let s = d[k] as? String, !s.isEmpty { found = s; return } }
            for child in d.values { walk(child, depth: depth + 1) }
        }
        walk(json, depth: 0)
        return found
    }
}

/// Signs that a site shows guests less than members: results without media, "log in to see
/// more" notices, or hidden counts. Site-blind: only key names and shapes are used.
enum GuestLimits {
    static let loginWords = ["log in", "login", "sign in", "signin", "account", "member", "register", "subscribe"]

    static func check(json: Any, items: [Any], adapter: GenericAdapter, listPath: String) -> [String] {
        var notes: [String] = []
        let missing = items.filter { adapter.diagnose($0)[.mediaURLPath] != nil }.count
        if missing > 0 {
            notes.append("\(missing) of \(items.count) results have no picture or video address. The site may be hiding them from guests.")
        }
        func walk(_ v: Any, path: String, depth: Int) {
            guard depth < 4, let d = v as? [String: Any] else { return }
            for (k, child) in d {
                let p = path.isEmpty ? k : "\(path).\(k)"
                if p == listPath { continue }
                let key = k.lowercased()
                if let s = child as? String, loginWords.contains(where: { s.lowercased().contains($0) }) {
                    notes.append("The site says: \"\(s.prefix(160))\"")
                } else if let n = child as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.intValue > 0,
                          ["hidden", "censored", "restricted", "filtered"].contains(where: { key.contains($0) }) {
                    notes.append("The site reports \(n.intValue) hidden result\(n.intValue == 1 ? "" : "s") (\(k)).")
                } else if let b = child as? NSNumber, CFGetTypeID(b) == CFBooleanGetTypeID(), b.boolValue,
                          ["login_required", "restricted", "limited", "guest"].contains(where: { key.contains($0) }) {
                    notes.append("The site flags this answer as limited (\(k) = true).")
                } else if child is [String: Any] {
                    walk(child, path: p, depth: depth + 1)
                }
            }
        }
        walk(json, path: "", depth: 0)
        return notes
    }
}
