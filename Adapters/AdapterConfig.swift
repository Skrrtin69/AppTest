import Foundation

enum AuthStyle: String, Codable, CaseIterable { case none, basic, apiKeyQuery, apiKeyHeader, bearer }
enum PaginationStyle: String, Codable, CaseIterable { case pageNumber, cursor }

/// One entry in adapters.json. Every site-specific behavior lives here.
/// Fields after `cursorPath` are optional extras; missing ones get sensible defaults so a
/// hand-written file only needs the core fields.
struct AdapterConfig: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
    var baseURL: URL
    var searchPath: String
    var postPath: String
    var mediaBaseURL: URL
    var requiresAuth: Bool
    var rateLimitPerSecond: Double

    var searchResultsPath: String
    var postIDPath: String
    var thumbnailURLPath: String
    var mediaURLPath: String
    var mediaTypePath: String
    var tagsPath: String
    var tagsNameKey: String?
    var sourceURLPath: String?

    var videoExtensions: [String]
    var gifExtensions: [String]

    var authStyle: AuthStyle
    var authParamName: String?

    var paginationStyle: PaginationStyle
    var hasNextPagePath: String?
    var cursorPath: String?

    // ---- Optional extras ----
    var sampleURLPath: String?
    var postResultPath: String?
    var metadataPaths: [String: String]
    var authCheckPath: String?
    var tagSeparator: String
    var firstPageIndex: Int
    var sortOptions: [String]
    var ratingOptions: [String]
    var userAgent: String?
    var proxyHost: String?
    var proxyPort: Int?
    var timeoutSeconds: Double
    var headers: [String: String]

    // ---- Phase 1 extras ----
    /// Other versions of the media (e.g. an MP4 next to a WebM). An MP4 always wins, so
    /// AVPlayer can play it with sound.
    var alternateMediaURLPaths: [String]
    /// Replaces spaces inside one tag before searching (e.g. "blue sky" → "blue_sky").
    var tagSpaceReplacement: String?
    /// Address (added to baseURL) for tag suggestions; {query} is what's being typed.
    var autocompletePath: String?
    /// Where the suggestion list is in that answer (empty = the answer itself).
    var autocompleteResultsPath: String?
    /// For suggestion objects: which key holds the tag name (default "name").
    var autocompleteNameKey: String?
    /// For suggestion objects: path to the tag name (overrides autocompleteNameKey).
    var tagNamePath: String? = nil
    /// For suggestion objects: path to the tag's post count (e.g. post_count, count).
    /// Empty = the usual keys are looked for.
    var tagCountPath: String? = nil
    /// Tag that asks the site for random order, for sites without a "random" sort choice.
    var randomTag: String?

    // ---- Phase 7: account & capabilities (all optional; UI only appears when set) ----
    /// Related tags for {tag}.
    var relatedTagsPath: String?
    /// Description ("wiki") of {tag}.
    var wikiPath: String?
    /// Other names of {tag}.
    var tagAliasesPath: String?
    /// Sends an up-vote for post {id} (POST). Never probed automatically: it changes data.
    var votePath: String?
    /// The logged-in user's own settings (blacklist, default sort/rating).
    var accountSettingsPath: String?
    /// Web page for creating an account.
    var registerURL: String?
    /// Some sites want a user ID next to the API key (e.g. user_id): this is that address
    /// parameter's name. The ID itself is the account's username field.
    var authUserParamName: String?
    /// Page where a logged-in user can see their API key (for guided key retrieval).
    var apiKeyPageURL: String?
    /// Adds (POST) / removes (DELETE) post {id} from the account's favorites. Needs a login.
    var favoritePath: String?
    /// When tags are objects: which key holds the tag's category (e.g. category, type).
    var tagCategoryKey: String?
    /// Inside one result: the list of pages of a multi-page post.
    var galleryPath: String?
    /// If gallery pages are objects, which key holds each page's address.
    var galleryURLKey: String?
    /// Address endings of frame-by-frame animation archives (played as animations).
    var zipExtensions: [String] = ["zip"]
    /// Inside one result: the list of animation frames with their delays,
    /// e.g. [{"file": "000.jpg", "delay": 80}] (delay in milliseconds).
    var zipFramesPath: String?
    /// A page that builds an archive of a gallery for you; {id} becomes the post ID.
    var externalArchiveURL: String?
    /// Address of the site's pool list ({page}, {query}); pools appear in the Pools tab.
    var poolsPath: String?
    /// Where the list of pools is in that answer (empty = the answer itself).
    var poolsResultsPath: String?
    /// Inside one pool: its ID (default "id").
    var poolIDPath: String?
    /// Inside one pool: its name (default "name").
    var poolNamePath: String?
    /// Inside one pool: how many posts it has.
    var poolCountPath: String?
    /// Inside one pool: its post IDs in reading order.
    var poolPostIDsPath: String?
    /// If pools don't list post IDs: the search that shows a pool, e.g. pool:{id}.
    var poolSearchTemplate: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, displayName, baseURL, searchPath, postPath, mediaBaseURL, requiresAuth, rateLimitPerSecond
        case searchResultsPath, postIDPath, thumbnailURLPath, mediaURLPath, mediaTypePath, tagsPath, tagsNameKey, sourceURLPath
        case videoExtensions, gifExtensions, authStyle, authParamName, paginationStyle, hasNextPagePath, cursorPath
        case sampleURLPath, postResultPath, metadataPaths, authCheckPath, tagSeparator, firstPageIndex
        case sortOptions, ratingOptions, userAgent, proxyHost, proxyPort, timeoutSeconds, headers
        case alternateMediaURLPaths, tagSpaceReplacement, autocompletePath, autocompleteResultsPath, autocompleteNameKey, tagNamePath, tagCountPath, randomTag
        case relatedTagsPath, wikiPath, tagAliasesPath, votePath, accountSettingsPath, registerURL
        case authUserParamName, apiKeyPageURL, favoritePath, tagCategoryKey, galleryPath, galleryURLKey, zipExtensions, zipFramesPath, externalArchiveURL, poolsPath, poolsResultsPath, poolIDPath, poolNamePath, poolCountPath, poolPostIDsPath, poolSearchTemplate
    }

    init(id: String, displayName: String, baseURL: URL, searchPath: String, postPath: String,
         mediaBaseURL: URL, requiresAuth: Bool = false, rateLimitPerSecond: Double = 2,
         searchResultsPath: String, postIDPath: String, thumbnailURLPath: String, mediaURLPath: String,
         mediaTypePath: String, tagsPath: String, tagsNameKey: String? = nil, sourceURLPath: String? = nil,
         videoExtensions: [String] = ["mp4", "webm", "mov", "m4v", "m3u8"], gifExtensions: [String] = ["gif"],
         authStyle: AuthStyle = .none, authParamName: String? = nil,
         paginationStyle: PaginationStyle = .pageNumber, hasNextPagePath: String? = nil, cursorPath: String? = nil) {
        self.id = id; self.displayName = displayName; self.baseURL = baseURL
        self.searchPath = searchPath; self.postPath = postPath; self.mediaBaseURL = mediaBaseURL
        self.requiresAuth = requiresAuth; self.rateLimitPerSecond = rateLimitPerSecond
        self.searchResultsPath = searchResultsPath; self.postIDPath = postIDPath
        self.thumbnailURLPath = thumbnailURLPath; self.mediaURLPath = mediaURLPath
        self.mediaTypePath = mediaTypePath; self.tagsPath = tagsPath; self.tagsNameKey = tagsNameKey
        self.sourceURLPath = sourceURLPath; self.videoExtensions = videoExtensions
        self.gifExtensions = gifExtensions; self.authStyle = authStyle; self.authParamName = authParamName
        self.paginationStyle = paginationStyle; self.hasNextPagePath = hasNextPagePath; self.cursorPath = cursorPath
        self.metadataPaths = [:]; self.tagSeparator = "+"; self.firstPageIndex = 1
        self.sortOptions = []; self.ratingOptions = []; self.timeoutSeconds = 20; self.headers = [:]
        self.alternateMediaURLPaths = []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        searchPath = try c.decode(String.self, forKey: .searchPath)
        postPath = try c.decodeIfPresent(String.self, forKey: .postPath) ?? ""
        mediaBaseURL = try c.decodeIfPresent(URL.self, forKey: .mediaBaseURL) ?? baseURL
        requiresAuth = try c.decodeIfPresent(Bool.self, forKey: .requiresAuth) ?? false
        rateLimitPerSecond = try c.decodeIfPresent(Double.self, forKey: .rateLimitPerSecond) ?? 2
        searchResultsPath = try c.decode(String.self, forKey: .searchResultsPath)
        postIDPath = try c.decode(String.self, forKey: .postIDPath)
        thumbnailURLPath = try c.decode(String.self, forKey: .thumbnailURLPath)
        mediaURLPath = try c.decode(String.self, forKey: .mediaURLPath)
        mediaTypePath = try c.decodeIfPresent(String.self, forKey: .mediaTypePath) ?? ""
        tagsPath = try c.decodeIfPresent(String.self, forKey: .tagsPath) ?? ""
        tagsNameKey = try c.decodeIfPresent(String.self, forKey: .tagsNameKey)
        sourceURLPath = try c.decodeIfPresent(String.self, forKey: .sourceURLPath)
        videoExtensions = try c.decodeIfPresent([String].self, forKey: .videoExtensions) ?? ["mp4", "webm", "mov", "m4v", "m3u8"]
        gifExtensions = try c.decodeIfPresent([String].self, forKey: .gifExtensions) ?? ["gif"]
        authStyle = try c.decodeIfPresent(AuthStyle.self, forKey: .authStyle) ?? .none
        authParamName = Self.sanitizeParamName(try c.decodeIfPresent(String.self, forKey: .authParamName))
        paginationStyle = try c.decodeIfPresent(PaginationStyle.self, forKey: .paginationStyle) ?? .pageNumber
        hasNextPagePath = try c.decodeIfPresent(String.self, forKey: .hasNextPagePath)
        cursorPath = try c.decodeIfPresent(String.self, forKey: .cursorPath)
        sampleURLPath = try c.decodeIfPresent(String.self, forKey: .sampleURLPath)
        postResultPath = try c.decodeIfPresent(String.self, forKey: .postResultPath)
        metadataPaths = try c.decodeIfPresent([String: String].self, forKey: .metadataPaths) ?? [:]
        authCheckPath = try c.decodeIfPresent(String.self, forKey: .authCheckPath)
        tagSeparator = try c.decodeIfPresent(String.self, forKey: .tagSeparator) ?? "+"
        firstPageIndex = try c.decodeIfPresent(Int.self, forKey: .firstPageIndex) ?? 1
        sortOptions = try c.decodeIfPresent([String].self, forKey: .sortOptions) ?? []
        ratingOptions = try c.decodeIfPresent([String].self, forKey: .ratingOptions) ?? []
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost)
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort)
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 20
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        alternateMediaURLPaths = try c.decodeIfPresent([String].self, forKey: .alternateMediaURLPaths) ?? []
        tagSpaceReplacement = try c.decodeIfPresent(String.self, forKey: .tagSpaceReplacement)
        autocompletePath = try c.decodeIfPresent(String.self, forKey: .autocompletePath)
        autocompleteResultsPath = try c.decodeIfPresent(String.self, forKey: .autocompleteResultsPath)
        autocompleteNameKey = try c.decodeIfPresent(String.self, forKey: .autocompleteNameKey)
        tagNamePath = try c.decodeIfPresent(String.self, forKey: .tagNamePath)
        tagCountPath = try c.decodeIfPresent(String.self, forKey: .tagCountPath)
        randomTag = try c.decodeIfPresent(String.self, forKey: .randomTag)
        relatedTagsPath = try c.decodeIfPresent(String.self, forKey: .relatedTagsPath)
        wikiPath = try c.decodeIfPresent(String.self, forKey: .wikiPath)
        tagAliasesPath = try c.decodeIfPresent(String.self, forKey: .tagAliasesPath)
        votePath = try c.decodeIfPresent(String.self, forKey: .votePath)
        accountSettingsPath = try c.decodeIfPresent(String.self, forKey: .accountSettingsPath)
        registerURL = try c.decodeIfPresent(String.self, forKey: .registerURL)
        authUserParamName = Self.sanitizeParamName(try c.decodeIfPresent(String.self, forKey: .authUserParamName))
        apiKeyPageURL = try c.decodeIfPresent(String.self, forKey: .apiKeyPageURL)
        favoritePath = try c.decodeIfPresent(String.self, forKey: .favoritePath)
        tagCategoryKey = try c.decodeIfPresent(String.self, forKey: .tagCategoryKey)
        galleryPath = try c.decodeIfPresent(String.self, forKey: .galleryPath)
        galleryURLKey = try c.decodeIfPresent(String.self, forKey: .galleryURLKey)
        zipExtensions = try c.decodeIfPresent([String].self, forKey: .zipExtensions) ?? ["zip"]
        zipFramesPath = try c.decodeIfPresent(String.self, forKey: .zipFramesPath)
        externalArchiveURL = try c.decodeIfPresent(String.self, forKey: .externalArchiveURL)
        poolsPath = try c.decodeIfPresent(String.self, forKey: .poolsPath)
        poolsResultsPath = try c.decodeIfPresent(String.self, forKey: .poolsResultsPath)
        poolIDPath = try c.decodeIfPresent(String.self, forKey: .poolIDPath)
        poolNamePath = try c.decodeIfPresent(String.self, forKey: .poolNamePath)
        poolCountPath = try c.decodeIfPresent(String.self, forKey: .poolCountPath)
        poolPostIDsPath = try c.decodeIfPresent(String.self, forKey: .poolPostIDsPath)
        poolSearchTemplate = try c.decodeIfPresent(String.self, forKey: .poolSearchTemplate)
    }

    /// Writes every key, including empty ones as null, so an exported file shows all fields.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(displayName, forKey: .displayName)
        try c.encode(baseURL, forKey: .baseURL); try c.encode(searchPath, forKey: .searchPath)
        try c.encode(postPath, forKey: .postPath); try c.encode(mediaBaseURL, forKey: .mediaBaseURL)
        try c.encode(requiresAuth, forKey: .requiresAuth); try c.encode(rateLimitPerSecond, forKey: .rateLimitPerSecond)
        try c.encode(searchResultsPath, forKey: .searchResultsPath); try c.encode(postIDPath, forKey: .postIDPath)
        try c.encode(thumbnailURLPath, forKey: .thumbnailURLPath); try c.encode(mediaURLPath, forKey: .mediaURLPath)
        try c.encode(mediaTypePath, forKey: .mediaTypePath); try c.encode(tagsPath, forKey: .tagsPath)
        try c.encode(tagsNameKey, forKey: .tagsNameKey); try c.encode(sourceURLPath, forKey: .sourceURLPath)
        try c.encode(videoExtensions, forKey: .videoExtensions); try c.encode(gifExtensions, forKey: .gifExtensions)
        try c.encode(authStyle, forKey: .authStyle); try c.encode(authParamName, forKey: .authParamName)
        try c.encode(paginationStyle, forKey: .paginationStyle); try c.encode(hasNextPagePath, forKey: .hasNextPagePath)
        try c.encode(cursorPath, forKey: .cursorPath); try c.encode(sampleURLPath, forKey: .sampleURLPath)
        try c.encode(postResultPath, forKey: .postResultPath); try c.encode(metadataPaths, forKey: .metadataPaths)
        try c.encode(authCheckPath, forKey: .authCheckPath); try c.encode(tagSeparator, forKey: .tagSeparator)
        try c.encode(firstPageIndex, forKey: .firstPageIndex); try c.encode(sortOptions, forKey: .sortOptions)
        try c.encode(ratingOptions, forKey: .ratingOptions); try c.encode(userAgent, forKey: .userAgent)
        try c.encode(proxyHost, forKey: .proxyHost); try c.encode(proxyPort, forKey: .proxyPort)
        try c.encode(timeoutSeconds, forKey: .timeoutSeconds); try c.encode(headers, forKey: .headers)
        try c.encode(alternateMediaURLPaths, forKey: .alternateMediaURLPaths)
        try c.encode(tagSpaceReplacement, forKey: .tagSpaceReplacement)
        try c.encode(autocompletePath, forKey: .autocompletePath)
        try c.encode(autocompleteResultsPath, forKey: .autocompleteResultsPath)
        try c.encode(autocompleteNameKey, forKey: .autocompleteNameKey)
        try c.encode(tagNamePath, forKey: .tagNamePath)
        try c.encode(tagCountPath, forKey: .tagCountPath)
        try c.encode(randomTag, forKey: .randomTag)
        try c.encode(relatedTagsPath, forKey: .relatedTagsPath)
        try c.encode(wikiPath, forKey: .wikiPath)
        try c.encode(tagAliasesPath, forKey: .tagAliasesPath)
        try c.encode(votePath, forKey: .votePath)
        try c.encode(accountSettingsPath, forKey: .accountSettingsPath)
        try c.encode(registerURL, forKey: .registerURL)
        try c.encode(authUserParamName, forKey: .authUserParamName)
        try c.encode(apiKeyPageURL, forKey: .apiKeyPageURL)
        try c.encode(favoritePath, forKey: .favoritePath)
        try c.encode(tagCategoryKey, forKey: .tagCategoryKey)
        try c.encode(galleryPath, forKey: .galleryPath)
        try c.encode(galleryURLKey, forKey: .galleryURLKey)
        try c.encode(zipExtensions, forKey: .zipExtensions)
        try c.encode(zipFramesPath, forKey: .zipFramesPath)
        try c.encode(externalArchiveURL, forKey: .externalArchiveURL)
        try c.encode(poolsPath, forKey: .poolsPath)
        try c.encode(poolsResultsPath, forKey: .poolsResultsPath)
        try c.encode(poolIDPath, forKey: .poolIDPath)
        try c.encode(poolNamePath, forKey: .poolNamePath)
        try c.encode(poolCountPath, forKey: .poolCountPath)
        try c.encode(poolPostIDsPath, forKey: .poolPostIDsPath)
        try c.encode(poolSearchTemplate, forKey: .poolSearchTemplate)
    }

    /// Starting point for the "Add adapter" form.
    static func blank() -> AdapterConfig {
        let base = URL(string: "http://127.0.0.1:\(MockServer.defaultPort)/")!
        return AdapterConfig(id: "new-site-\(Int.random(in: 100...999))", displayName: "New Site",
                             baseURL: base, searchPath: "", postPath: "", mediaBaseURL: base,
                             searchResultsPath: "", postIDPath: "", thumbnailURLPath: "", mediaURLPath: "",
                             mediaTypePath: "", tagsPath: "")
    }

    /// A complete, working example that points at the built-in demo server's login-protected area.
    static func mockSecureExample(port: UInt16) -> AdapterConfig {
        let base = URL(string: "http://127.0.0.1:\(port)/a/secure")!
        var c = AdapterConfig(id: "demo-secure", displayName: "Demo Secure", baseURL: base,
                              searchPath: "posts.json?tags={tags}&page={page}&sort={sort}",
                              postPath: "post/{id}.json", mediaBaseURL: URL(string: "http://127.0.0.1:\(port)/")!,
                              requiresAuth: true, rateLimitPerSecond: 4,
                              searchResultsPath: "posts", postIDPath: "id", thumbnailURLPath: "preview_url",
                              mediaURLPath: "file_url", mediaTypePath: "file_ext", tagsPath: "tags",
                              sourceURLPath: "source", authStyle: .basic,
                              paginationStyle: .pageNumber, hasNextPagePath: "has_more")
        c.authCheckPath = "auth/check"
        c.accountSettingsPath = "account.json"
        c.registerURL = "register"
        c.votePath = "posts/{id}/vote"
        c.favoritePath = "favorites/{id}"
        c.sortOptions = ["newest", "oldest", "random"]
        return c
    }

    /// Cleans a user-typed key/header name: drops leading "&", "?" and trailing "=", ":" and
    /// spaces, so "&api_key=" becomes "api_key". Returns nil when nothing usable is left.
    static func sanitizeParamName(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let junk = CharacterSet(charactersIn: "&?=: ").union(.whitespacesAndNewlines)
        let cleaned = raw.trimmingCharacters(in: junk)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Any field's value as compact JSON text (e.g. `"file_url"`, `2`, `["gif"]`, `null`).
    /// Used to notice when the user has changed a field away from an Auto-Configure guess.
    func jsonValue(for key: CodingKeys) -> String {
        guard let data = try? JSONEncoder().encode(self),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let value = dict[key.rawValue] ?? NSNull()
        guard let v = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: v, as: UTF8.self)
    }

    /// Fields the Field Mapper's "Use as…" menu can fill in.
    struct MappableField {
        let key: CodingKeys
        let title: String
        /// Per-post fields are relative to one element of the results list.
        let perPost: Bool
    }

    static let mappableFields: [MappableField] = [
        MappableField(key: .searchResultsPath, title: "List of results", perPost: false),
        MappableField(key: .postIDPath, title: "Post ID", perPost: true),
        MappableField(key: .thumbnailURLPath, title: "Thumbnail URL", perPost: true),
        MappableField(key: .mediaURLPath, title: "Full media URL", perPost: true),
        MappableField(key: .sampleURLPath, title: "Medium-size URL", perPost: true),
        MappableField(key: .mediaTypePath, title: "Media type / extension", perPost: true),
        MappableField(key: .tagsPath, title: "Tags", perPost: true),
        MappableField(key: .sourceURLPath, title: "Source URL", perPost: true),
        MappableField(key: .hasNextPagePath, title: "Has next page", perPost: false),
        MappableField(key: .cursorPath, title: "Next-page cursor", perPost: false),
    ]

    /// Read/write a string-valued path field by key (used by the Field Mapper).
    subscript(path key: CodingKeys) -> String? {
        get {
            switch key {
            case .searchResultsPath: return searchResultsPath
            case .postIDPath: return postIDPath
            case .thumbnailURLPath: return thumbnailURLPath
            case .mediaURLPath: return mediaURLPath
            case .sampleURLPath: return sampleURLPath
            case .mediaTypePath: return mediaTypePath
            case .tagsPath: return tagsPath
            case .sourceURLPath: return sourceURLPath
            case .hasNextPagePath: return hasNextPagePath
            case .cursorPath: return cursorPath
            default: return nil
            }
        }
        set {
            let v = newValue ?? ""
            switch key {
            case .searchResultsPath: searchResultsPath = v
            case .postIDPath: postIDPath = v
            case .thumbnailURLPath: thumbnailURLPath = v
            case .mediaURLPath: mediaURLPath = v
            case .sampleURLPath: sampleURLPath = v.isEmpty ? nil : v
            case .mediaTypePath: mediaTypePath = v
            case .tagsPath: tagsPath = v
            case .sourceURLPath: sourceURLPath = v.isEmpty ? nil : v
            case .hasNextPagePath: hasNextPagePath = v.isEmpty ? nil : v
            case .cursorPath: cursorPath = v.isEmpty ? nil : v
            default: break
            }
        }
    }
}
