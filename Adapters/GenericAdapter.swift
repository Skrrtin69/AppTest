import Foundation

/// The only SiteAdapter implementation. Templating and field mapping come from `AdapterConfig`.
final class GenericAdapter: SiteAdapter {
    let config: AdapterConfig
    let client: NetworkClient
    /// Set by AuthManager after a successful login; applied to every request.
    var session: AuthSession?

    init(config: AdapterConfig, client: NetworkClient? = nil) {
        self.config = config
        self.client = client ?? NetworkClient(adapter: config)
        if self.client.siteID == nil { self.client.siteID = config.id }
    }

    var id: String { config.id }
    var displayName: String { config.displayName }
    var requiresAuth: Bool { config.requiresAuth }
    var supportedMediaTypes: Set<MediaType> { [.image, .gif, .video] }

    // MARK: - URL templating

    /// Builds the search URL. Public so the Field Mapper can fetch a raw sample.
    func searchURL(tags: [String], options: SearchOptions, page: Int) throws -> URL {
        // "+" is inserted literally (it means space in a query string); anything else, such as a
        // plain space, is percent-encoded so the address stays valid.
        let sep = config.tagSeparator == "+" ? "+" : Self.encode(config.tagSeparator)
        let tagString = tags.map { Self.encode(prepareTag($0)) }.joined(separator: sep)
        var vars: [String: String] = [
            "tags": tagString,
            "page": String(page - 1 + config.firstPageIndex),
            "cursor": Self.encode(options.cursor ?? ""),
            "sort": Self.encode(options.sort ?? ""),
            "rating": Self.encode(options.rating ?? ""),
        ]
        for (k, v) in options.extra { vars[k] = Self.encode(v) }
        return try buildURL(path: config.searchPath, vars: vars)
    }

    /// Applies tagSpaceReplacement to spaces inside one tag ("blue sky" → "blue_sky").
    func prepareTag(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespaces)
        guard let r = config.tagSpaceReplacement, !r.isEmpty else { return t }
        return t.split(separator: " ").joined(separator: r)
    }

    // MARK: - Suggestions

    var supportsAutocomplete: Bool { config.autocompletePath?.nonEmpty != nil }

    /// Tag suggestions for what's being typed, using autocompletePath. Empty when unsupported.
    func suggest(_ query: String) async throws -> [String] {
        guard let path = config.autocompletePath?.nonEmpty else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1 else { return [] }
        let url = try buildURL(path: path, vars: ["query": Self.encode(prepareTag(q))])
        let json = try await fetchJSON(url)
        let list = DottedPath.evaluate(config.autocompleteResultsPath ?? "", in: json) ?? json
        let key = config.autocompleteNameKey?.nonEmpty ?? "name"
        var out: [String] = []
        for item in (list as? [Any]) ?? [] {
            if let s = item as? String { out.append(s) }
            else if let d = item as? [String: Any], let s = DottedPath.stringValue(d[key]) { out.append(s) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    func postURL(id: String) throws -> URL {
        try buildURL(path: config.postPath, vars: ["id": Self.encode(id)])
    }

    private func buildURL(path: String, vars: [String: String]) throws -> URL {
        var p = path
        for (k, v) in vars { p = p.replacingOccurrences(of: "{\(k)}", with: v) }
        let full: String
        if p.lowercased().hasPrefix("http://") || p.lowercased().hasPrefix("https://") {
            full = p
        } else {
            full = Self.join(config.baseURL.absoluteString, p)
        }
        guard var comps = URLComponents(string: full) else { throw AppError.invalidURL(full) }
        if config.authStyle == .apiKeyQuery, let token = session?.token,
           let name = AdapterConfig.sanitizeParamName(config.authParamName) {
            // Built as text from encoded parts: assigning percentEncodedQueryItems traps on
            // characters like "&" in a user-typed key name.
            let pair = Self.encode(name) + "=" + Self.encode(token)
            if let q = comps.percentEncodedQuery, !q.isEmpty {
                comps.percentEncodedQuery = q + "&" + pair
            } else {
                comps.percentEncodedQuery = pair
            }
        }
        guard let url = comps.url else { throw AppError.invalidURL(full) }
        return url
    }

    static func join(_ base: String, _ path: String) -> String {
        if path.isEmpty { return base }
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return p.hasPrefix("?") ? b + p : b + "/" + p
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private var authHeaders: [String: String] {
        guard let token = session?.token else { return [:] }
        switch config.authStyle {
        case .basic: return ["Authorization": "Basic \(token)"]
        case .apiKeyHeader: return [AdapterConfig.sanitizeParamName(config.authParamName) ?? "Authorization": token]
        default: return [:]
        }
    }

    // MARK: - Requests

    /// Raw response with this adapter's auth and headers, without throwing on 4xx/5xx.
    func fetchRaw(_ url: URL, rateLimited: Bool = true) async throws -> (Data, HTTPURLResponse) {
        try await client.data(for: url, headers: authHeaders, rateLimited: rateLimited, acceptAnyStatus: true)
    }

    /// Fetches and parses JSON from a URL with this adapter's auth and limits.
    func fetchJSON(_ url: URL) async throws -> Any {
        let (data, _) = try await client.data(for: url, headers: authHeaders)
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let snippet = String(decoding: data.prefix(120), as: UTF8.self)
            throw AppError.notJSON(snippet)
        }
    }

    func search(tags: [String], options: SearchOptions, page: Int) async throws -> SearchResult {
        let url = try searchURL(tags: tags, options: options, page: page)
        let json = try await fetchJSON(url)
        guard let list = DottedPath.evaluate(config.searchResultsPath, in: json) else {
            throw AppError.pathNotFound(field: "List of results (searchResultsPath)", path: config.searchResultsPath)
        }
        guard let items = list as? [Any] else {
            throw AppError.badResponse("'searchResultsPath' (\(config.searchResultsPath)) points at something that is not a list.")
        }
        let posts = items.compactMap { mapPost($0) }
        if !items.isEmpty && posts.isEmpty {
            throw AppError.pathNotFound(field: "Post ID / Media URL (postIDPath, mediaURLPath)", path: "\(config.postIDPath), \(config.mediaURLPath)")
        }

        var nextCursor: String?
        if let cp = config.cursorPath?.nonEmpty { nextCursor = DottedPath.string(cp, in: json) }
        let hasNext: Bool
        if let hp = config.hasNextPagePath?.nonEmpty, let b = DottedPath.bool(hp, in: json) {
            hasNext = b
        } else if config.paginationStyle == .cursor {
            hasNext = nextCursor?.nonEmpty != nil
        } else {
            hasNext = !items.isEmpty
        }
        return SearchResult(posts: posts, hasNextPage: hasNext, currentPage: page, nextCursor: nextCursor)
    }

    func fetchPost(id: String) async throws -> Post {
        let json = try await fetchJSON(try postURL(id: id))
        let node = DottedPath.evaluate(config.postResultPath ?? "", in: json) ?? json
        guard let post = mapPost(node) else {
            throw AppError.pathNotFound(field: "Post ID / Media URL", path: "\(config.postIDPath), \(config.mediaURLPath)")
        }
        return post
    }

    func fetchMediaURL(for post: Post, quality: MediaQuality) async throws -> URL {
        switch quality {
        case .original: return post.mediaURL
        case .preview: return post.sampleURL ?? post.thumbnailURL
        }
    }

    /// Builds a Post from one element of the results list. Returns nil if the ID or media URL is missing.
    func mapPost(_ node: Any) -> Post? {
        guard let id = DottedPath.string(config.postIDPath, in: node)?.nonEmpty,
              let mediaString = DottedPath.string(config.mediaURLPath, in: node)?.nonEmpty,
              let original = resolve(mediaString) else { return nil }
        var meta: [String: String] = [:]
        // Prefer an MP4 version when the adapter lists alternates: AVPlayer plays it natively,
        // with sound, while WebM needs the slower web player.
        var media = original
        if !Self.isMP4(original) {
            let alternates = config.alternateMediaURLPaths.compactMap { DottedPath.string($0, in: node)?.nonEmpty }.compactMap { resolve($0) }
            if let mp4 = alternates.first(where: Self.isMP4) {
                media = mp4
                meta["format"] = "\(mp4.pathExtension.uppercased()) (chosen over \(original.pathExtension.uppercased()))"
            }
        }
        let thumb = DottedPath.string(config.thumbnailURLPath, in: node).flatMap { resolve($0) } ?? media
        let sample = config.sampleURLPath.flatMap { DottedPath.string($0, in: node) }.flatMap { resolve($0) }
        let typeStrings = DottedPath.strings(config.mediaTypePath, in: node)
        let tags = DottedPath.strings(config.tagsPath, in: node, nameKey: config.tagsNameKey)
        let source = config.sourceURLPath.flatMap { DottedPath.string($0, in: node) }.flatMap { URL(string: $0) }
        for (name, path) in config.metadataPaths {
            if let v = DottedPath.string(path, in: node) { meta[name] = v }
        }
        return Post(id: id, siteID: config.id, thumbnailURL: thumb, mediaURL: media,
                    mediaType: Self.mediaType(typeStrings: typeStrings, url: media, config: config),
                    tags: tags, sourceURL: source, metadata: meta, sampleURL: sample)
    }

    static func isMP4(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    /// Plain-English problems with mapping one result, keyed by the field at fault.
    /// Empty when `mapPost` would produce a complete post.
    func diagnose(_ node: Any) -> [AdapterConfig.CodingKeys: String] {
        var out: [AdapterConfig.CodingKeys: String] = [:]
        if DottedPath.string(config.postIDPath, in: node)?.nonEmpty == nil {
            out[.postIDPath] = "postIDPath returned nothing"
        }
        if let m = DottedPath.string(config.mediaURLPath, in: node)?.nonEmpty {
            if resolve(m) == nil { out[.mediaURLPath] = "mediaURLPath is not a valid URL (\(m.prefix(60)))" }
        } else {
            out[.mediaURLPath] = "mediaURLPath returned nothing"
        }
        if config.thumbnailURLPath.nonEmpty != nil {
            if let t = DottedPath.string(config.thumbnailURLPath, in: node)?.nonEmpty {
                if resolve(t) == nil { out[.thumbnailURLPath] = "thumbnailURLPath is not a valid URL (\(t.prefix(60)))" }
            } else {
                out[.thumbnailURLPath] = "thumbnailURLPath returned nothing"
            }
        }
        if config.tagsPath.nonEmpty != nil, DottedPath.strings(config.tagsPath, in: node, nameKey: config.tagsNameKey).isEmpty {
            out[.tagsPath] = "tagsPath returned no tags"
        }
        return out
    }

    /// Absolute URLs pass through; relative ones are joined to mediaBaseURL.
    func resolve(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if t.hasPrefix("//") { return URL(string: "https:" + t) }
        if let u = URL(string: t), u.scheme != nil { return u }
        let joined = Self.join(config.mediaBaseURL.absoluteString, t)
        return URL(string: joined) ?? URL(string: joined.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? joined)
    }

    /// Lowercased type string(s) or the URL extension, checked against the configured lists.
    static func mediaType(typeStrings: [String], url: URL, config: AdapterConfig) -> MediaType {
        var candidates = typeStrings.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        // "video/mp4" style MIME types → also try the subtype
        candidates += candidates.compactMap { $0.split(separator: "/").last.map(String.init) }
        if candidates.isEmpty { candidates = [url.pathExtension.lowercased()] }
        let videos = Set(config.videoExtensions.map { $0.lowercased() })
        let gifs = Set(config.gifExtensions.map { $0.lowercased() })
        if candidates.contains(where: { videos.contains($0) }) { return .video }
        if candidates.contains(where: { gifs.contains($0) }) { return .gif }
        return .image
    }

    // MARK: - Auth

    func authenticate(credentials: Credentials) async throws -> AuthSession {
        let token: String
        switch config.authStyle {
        case .none:
            return AuthSession(siteID: id, token: "", expiresAt: nil)
        case .basic:
            let raw = "\(credentials.username):\(credentials.password ?? "")"
            token = Data(raw.utf8).base64EncodedString()
        case .apiKeyQuery, .apiKeyHeader:
            guard let key = credentials.apiKey?.nonEmpty ?? credentials.password?.nonEmpty else {
                throw AppError.authFailed("This adapter logs in with an API key, but none is saved.")
            }
            token = key
        }
        let candidate = AuthSession(siteID: id, token: token, expiresAt: Date().addingTimeInterval(3600))
        guard await validateSession(candidate) else {
            throw AppError.authFailed("The server rejected the saved username/password/key.")
        }
        return candidate
    }

    /// With `authCheckPath` set, asks the server; otherwise trusts a non-expired token.
    func validateSession(_ s: AuthSession) async -> Bool {
        if let exp = s.expiresAt, exp < Date() { return false }
        guard let check = config.authCheckPath?.nonEmpty else { return config.authStyle == .none || !s.token.isEmpty }
        let previous = session
        session = s
        defer { session = previous }
        guard let url = try? buildURL(path: check, vars: [:]) else { return false }
        do {
            _ = try await client.data(for: url, headers: authHeaders)
            return true
        } catch {
            return false
        }
    }
}
