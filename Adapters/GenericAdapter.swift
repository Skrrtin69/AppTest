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

    /// One tag suggestion: its name and, when the site says, how many posts use it.
    struct TagSuggestion: Hashable {
        let name: String
        let count: Int?
        let category: String?
    }

    /// Keys looked for when the adapter has no tagCountPath.
    static let countKeys = ["post_count", "count", "posts", "postCount", "total", "use_count"]

    /// Tag suggestions for what's being typed, using autocompletePath. Empty when unsupported.
    func suggest(_ query: String) async throws -> [String] {
        try await suggestDetailed(query).map(\.name)
    }

    /// Suggestions with post counts (tagCountPath, else the usual count keys).
    func suggestDetailed(_ query: String) async throws -> [TagSuggestion] {
        guard let path = config.autocompletePath?.nonEmpty else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1 else { return [] }
        let url = try buildURL(path: path, vars: ["query": Self.encode(prepareTag(q))])
        let json = try await fetchJSON(url)
        let list = DottedPath.evaluate(config.autocompleteResultsPath ?? "", in: json) ?? json
        let namePath = config.tagNamePath?.nonEmpty ?? config.autocompleteNameKey?.nonEmpty ?? "name"
        var out: [TagSuggestion] = []
        for item in (list as? [Any]) ?? [] {
            if let s = item as? String { out.append(TagSuggestion(name: s, count: nil, category: nil)); continue }
            guard let d = item as? [String: Any], let name = DottedPath.string(namePath, in: d)?.nonEmpty else { continue }
            out.append(TagSuggestion(name: name, count: Self.count(in: d, path: config.tagCountPath?.nonEmpty),
                                     category: DottedPath.stringValue(d["category"] ?? d["type"])))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.name.lowercased()).inserted }
    }

    static func count(in item: [String: Any], path: String?) -> Int? {
        let paths = path.map { [$0] } ?? countKeys
        for p in paths {
            switch DottedPath.evaluate(p, in: item) {
            case let n as Int: return n
            case let n as Double: return Int(n)
            case let n as NSNumber: return n.intValue
            case let s as String: if let n = Int(s.replacingOccurrences(of: ",", with: "")) { return n }
            default: continue
            }
        }
        return nil
    }

    /// One tag's suggestion entry (exact name match), for its post count. nil when the
    /// site doesn't list it.
    func tagStats(_ tag: String) async throws -> TagSuggestion? {
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "_") }
        let want = norm(tag)
        return try await suggestDetailed(tag).first { norm($0.name) == want }
    }

    func postURL(id: String) throws -> URL {
        try buildURL(path: config.postPath, vars: ["id": Self.encode(id)])
    }

    func buildURL(path: String, vars: [String: String]) throws -> URL {
        var p = path
        for (k, v) in vars { p = p.replacingOccurrences(of: "{\(k)}", with: v) }
        let full: String
        if p.lowercased().hasPrefix("http://") || p.lowercased().hasPrefix("https://") {
            full = p
        } else {
            full = Self.join(config.baseURL.absoluteString, p)
        }
        guard var comps = URLComponents(string: Self.escapeQueryBrackets(full)) else { throw AppError.invalidURL(full) }
        // Built as text from encoded parts: assigning percentEncodedQueryItems traps on
        // characters like "&" in a user-typed key name.
        var extra: [String] = []
        if config.authStyle == .apiKeyQuery, let token = session?.token,
           let name = AdapterConfig.sanitizeParamName(config.authParamName) {
            extra.append(Self.encode(name) + "=" + Self.encode(token))
        }
        if let userParam = config.authUserParamName, let uid = session?.userID?.nonEmpty {
            extra.append(Self.encode(userParam) + "=" + Self.encode(uid))
        }
        if !extra.isEmpty {
            let pair = extra.joined(separator: "&")
            if let q = comps.percentEncodedQuery, !q.isEmpty {
                comps.percentEncodedQuery = q + "&" + pair
            } else {
                comps.percentEncodedQuery = pair
            }
        }
        guard let url = comps.url else { throw AppError.invalidURL(full) }
        return url
    }

    /// "search[name]=x" in a query: brackets percent-encoded, which older iOS versions require.
    static func escapeQueryBrackets(_ s: String) -> String {
        guard let q = s.firstIndex(of: "?") else { return s }
        let query = s[q...].replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
        return String(s[..<q]) + query
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

    var authHeaders: [String: String] {
        guard let token = session?.token else { return [:] }
        switch config.authStyle {
        case .basic: return ["Authorization": "Basic \(token)"]
        case .apiKeyHeader: return [AdapterConfig.sanitizeParamName(config.authParamName) ?? "Authorization": token]
        case .bearer: return ["Authorization": "Bearer \(token)"]
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
        var result = SearchResult(posts: posts, hasNextPage: hasNext, currentPage: page, nextCursor: nextCursor)
        if session == nil { result.notes = GuestLimits.check(json: json, items: items, adapter: self, listPath: config.searchResultsPath) }
        return result
    }

    func fetchPost(id: String) async throws -> Post {
        // No single-post address in the adapter: find the post through a normal search
        // for "id:N" (the tag most sites use for one post), keeping only that exact ID.
        guard config.postPath.nonEmpty != nil else {
            let r = try await search(tags: ["id:\(id)"], options: SearchOptions(), page: config.firstPageIndex)
            guard let p = r.posts.first(where: { $0.id == id }) else {
                throw AppError.message("Post \(id) wasn't found on \(config.displayName).")
            }
            return p
        }
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
        // Animation archive: remember the frame timings for when the archive is decoded.
        if let fp = config.zipFramesPath?.nonEmpty {
            let delays = ZipFrames.parse(DottedPath.evaluate(fp, in: node))
            if !delays.isEmpty { ZipFrames.register(media, delays: delays) }
        }
        return Post(id: id, siteID: config.id, thumbnailURL: thumb, mediaURL: media,
                    mediaType: Self.mediaType(typeStrings: typeStrings, url: media, config: config),
                    tags: tags, sourceURL: source, metadata: meta, sampleURL: sample,
                    tagCategories: tagCategories(node), pages: galleryPages(node))
    }

    static func isMP4(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    /// A multi-page post's page addresses (galleryPath / galleryURLKey).
    func galleryPages(_ node: Any) -> [URL]? {
        guard let p = config.galleryPath?.nonEmpty, let list = DottedPath.evaluate(p, in: node) as? [Any] else { return nil }
        let key = config.galleryURLKey?.nonEmpty ?? "url"
        let urls = list.compactMap { item -> URL? in
            if let s = item as? String { return resolve(s) }
            if let d = item as? [String: Any], let s = DottedPath.stringValue(d[key]) { return resolve(s) }
            return nil
        }
        return urls.isEmpty ? nil : urls
    }

    /// Tag → category, read from tag objects when tagCategoryKey is set.
    func tagCategories(_ node: Any) -> [String: String]? {
        guard let key = config.tagCategoryKey?.nonEmpty,
              let list = DottedPath.evaluate(config.tagsPath, in: node) as? [Any] else { return nil }
        let nameKey = config.tagsNameKey?.nonEmpty ?? "name"
        var out: [String: String] = [:]
        for case let d as [String: Any] in list {
            if let name = DottedPath.stringValue(d[nameKey]), let cat = DottedPath.stringValue(d[key]) { out[name] = cat }
        }
        return out.isEmpty ? nil : out
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
        if let u = URL(string: t), u.scheme != nil { return MediaURL.upgraded(u) }
        let joined = Self.join(config.mediaBaseURL.absoluteString, t)
        return URL(string: joined) ?? URL(string: joined.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? joined)
    }

    /// Lowercased type string(s) or the URL extension, checked against the configured lists.
    static func mediaType(typeStrings: [String], url: URL, config: AdapterConfig) -> MediaType {
        var candidates = typeStrings.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        // "video/mp4" style MIME types → also try the subtype
        candidates += candidates.compactMap { $0.split(separator: "/").last.map(String.init) }
        if candidates.isEmpty { candidates = [url.pathExtension.lowercased()] }
        // Extensions are compared without case (.MP4 = .mp4). HLS playlists are always video.
        let videos = Set(config.videoExtensions.map { $0.lowercased() } + ["m3u8"])
        let gifs = Set(config.gifExtensions.map { $0.lowercased() })
        let zips = Set(config.zipExtensions.map { $0.lowercased() })
        let urlExt = url.pathExtension.lowercased()
        if candidates.contains(where: { videos.contains($0) }) || urlExt == "m3u8" { return .video }
        // Frame-by-frame archives play like GIFs.
        if candidates.contains(where: { gifs.contains($0) || zips.contains($0) }) || zips.contains(urlExt) { return .gif }
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
        case .apiKeyQuery, .apiKeyHeader, .bearer:
            guard let key = credentials.apiKey?.nonEmpty ?? credentials.password?.nonEmpty else {
                throw AppError.authFailed("This adapter logs in with an API key, but none is saved.")
            }
            token = key
        }
        var candidate = AuthSession(siteID: id, token: token, expiresAt: Date().addingTimeInterval(3600))
        if config.authUserParamName != nil { candidate.userID = credentials.username.nonEmpty }
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
