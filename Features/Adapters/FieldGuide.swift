import Foundation

/// Plain-English help for every adapters.json field. Drives the editor form and the Field Guide screen.
enum FieldGuide {
    struct Entry: Identifiable {
        let key: AdapterConfig.CodingKeys
        let title: String
        let help: String
        let example: String
        let required: Bool
        var id: String { key.rawValue }
    }

    struct Section {
        let title: String
        let intro: String
        let fields: [AdapterConfig.CodingKeys]
        init(_ title: String, _ intro: String, _ fields: [AdapterConfig.CodingKeys]) {
            self.title = title; self.intro = intro; self.fields = fields
        }
    }

    static let sections: [Section] = [
        Section("Basics", "What this site is called and where it lives.",
         [.id, .displayName, .baseURL, .mediaBaseURL, .requiresAuth, .rateLimitPerSecond]),
        Section("Web addresses", "How to build the address for a search and for a single post. Words in {curly braces} are filled in by the app.",
         [.searchPath, .postPath, .tagSeparator, .tagSpaceReplacement, .firstPageIndex, .sortOptions, .ratingOptions, .randomTag]),
        Section("Finding things in the answer", "Where each piece of information sits inside the site's JSON answer. Use the Field Mapper to discover these — paste an answer, tap a row, choose \"Use as…\".",
         [.searchResultsPath, .postIDPath, .thumbnailURLPath, .mediaURLPath, .sampleURLPath, .alternateMediaURLPaths, .mediaTypePath, .tagsPath, .tagsNameKey, .tagCategoryKey, .galleryPath, .galleryURLKey, .sourceURLPath, .postResultPath, .metadataPaths]),
        Section("Tag suggestions", "Optional. Lets the search bar suggest tags while you type.",
         [.autocompletePath, .autocompleteResultsPath, .autocompleteNameKey]),
        Section("Media types", "How the app decides if something is a video, a GIF, or a picture.",
         [.videoExtensions, .gifExtensions, .zipExtensions, .zipFramesPath]),
        Section("Pages", "How to get the next page of results.",
         [.paginationStyle, .hasNextPagePath, .cursorPath]),
        Section("Login", "Only needed if the site wants an account or key. Your actual username/password/key is saved separately and securely under Account.",
         [.authStyle, .authParamName, .authUserParamName, .authCheckPath, .accountSettingsPath, .apiKeyPageURL, .registerURL]),
        Section("Extra features", "Optional. Each button or panel only appears in the app when its address is filled in.",
         [.relatedTagsPath, .wikiPath, .tagAliasesPath, .votePath, .favoritePath]),
        Section("Network", "Optional fine-tuning.",
         [.userAgent, .proxyHost, .proxyPort, .timeoutSeconds, .headers]),
    ]

    static let entries: [AdapterConfig.CodingKeys: Entry] = {
        var d: [AdapterConfig.CodingKeys: Entry] = [:]
        func e(_ k: AdapterConfig.CodingKeys, _ title: String, _ help: String, _ example: String, required: Bool = false) {
            d[k] = Entry(key: k, title: title, help: help, example: example, required: required)
        }
        e(.id, "ID", "A short unique name for this adapter, with no spaces. Only used inside the app (for example in download file names).", "my-site", required: true)
        e(.displayName, "Display name", "The name shown in the site switcher.", "My Site", required: true)
        e(.baseURL, "Base address", "The start of every address the site's API uses. Must begin with http:// or https://.", "http://127.0.0.1:8765/a", required: true)
        e(.mediaBaseURL, "Media base address", "If the site gives picture addresses that don't start with http (like \"media/123.png\"), they're added onto this. Usually the same as the base address.", "http://127.0.0.1:8765/b/", required: true)
        e(.requiresAuth, "Requires login", "Turn on if the site refuses to answer without a login or key. The app will log in automatically before searching.", "false")
        e(.rateLimitPerSecond, "Requests per second", "The most requests the app may send to this site each second. Lower it if the site complains about too many requests.", "2")
        e(.searchPath, "Search path", "Added to the base address to search. Placeholders: {tags} = what you typed, {page} = page number, {cursor} = next-page token, {sort} and {rating} = what you picked in the menus.", "posts.json?tags={tags}&page={page}", required: true)
        e(.postPath, "Post path", "Added to the base address to load a single post. {id} is replaced by the post's ID.", "post/{id}.json")
        e(.tagSeparator, "Tag separator", "What goes between tags in {tags}. Most sites use + (a plus sign).", "+")
        e(.firstPageIndex, "First page number", "The number the site uses for the first page — usually 1, sometimes 0.", "1")
        e(.sortOptions, "Sort choices", "One per line. These appear in the Sort menu and are put into {sort}.", "newest\noldest")
        e(.ratingOptions, "Rating choices", "One per line. These appear in the Rating menu and are put into {rating}.", "general")
        e(.searchResultsPath, "List of results", "Where the list of posts is inside the search answer. Leave empty if the answer itself is the list.", "posts   or   data.items", required: true)
        e(.postIDPath, "Post ID", "Inside one result: where the post's ID is.", "id   or   post.id", required: true)
        e(.thumbnailURLPath, "Thumbnail address", "Inside one result: where the small preview picture's address is.", "preview_url", required: true)
        e(.mediaURLPath, "Full media address", "Inside one result: where the full-size picture/GIF/video address is.", "file_url", required: true)
        e(.sampleURLPath, "Medium-size address", "Optional. Inside one result: a medium-size version. Used when download quality is set to Preview.", "sample_url")
        e(.mediaTypePath, "Media type", "Inside one result: where the file type is (like \"png\", \"gif\", \"webm\"). Leave empty to guess from the address's ending.", "file_ext")
        e(.tagsPath, "Tags", "Inside one result: where the tags are. Can be a list of words, a list of objects, or one space-separated text.", "tags   or   post.tag_list")
        e(.tagsNameKey, "Tag name key", "Only if the tags are objects (like {\"name\": \"blue\"}): which key holds the tag's name.", "name")
        e(.sourceURLPath, "Source address", "Optional. Inside one result: a web page for the post.", "source")
        e(.postResultPath, "Single post location", "Optional. In the single-post answer, where the post object is. Leave empty if the answer is the post itself.", "data.item")
        e(.metadataPaths, "Extra info", "Optional. One per line as  name = path . Shown in the Info panel. Use width and height to show dimensions before loading.", "width = width\nheight = height")
        e(.videoExtensions, "Video types", "One per line. Files whose type (or address ending) is in this list are played as video.", "mp4\nwebm")
        e(.gifExtensions, "GIF types", "One per line. Files whose type is in this list are played as animated GIFs.", "gif")
        e(.paginationStyle, "Page style", "pageNumber: the site uses page=1, 2, 3…  cursor: each answer contains a token for the next page.", "pageNumber")
        e(.hasNextPagePath, "Has next page", "Optional. Where the answer says true/false for \"there are more pages\". If empty, the app keeps going until a page comes back empty.", "has_more")
        e(.cursorPath, "Next-page token", "For cursor style: where the next-page token is in the answer. It's put into {cursor} on the next request.", "data.next_cursor")
        e(.authStyle, "Login style", "none: no login. basic: username + password. apiKeyQuery: key added to the address. apiKeyHeader: key sent as a header.", "none")
        e(.authParamName, "Key name", "For apiKeyQuery: the address parameter name (like api_key). For apiKeyHeader: the header name (like X-Api-Key).", "api_key")
        e(.authCheckPath, "Login check path", "Optional. An address (added to the base) that only works when logged in. Used to check a login is still valid.", "auth/check")
        e(.userAgent, "User-Agent", "Optional. How the app introduces itself to this site. Leave empty for the default.", "MyBrowser/1.0")
        e(.proxyHost, "Proxy host", "Optional. Send this site's traffic through a proxy server at this address.", "192.168.1.10")
        e(.proxyPort, "Proxy port", "Optional. The proxy server's port number.", "8080")
        e(.timeoutSeconds, "Timeout (seconds)", "How long to wait for an answer before giving up (the app retries 3 times on timeouts and server errors).", "20")
        e(.headers, "Extra headers", "Optional. One per line as  Name = value . Sent with every request to this site.", "Accept = application/json")
        e(.alternateMediaURLPaths, "Other media versions", "Optional. One per line: paths to other versions of the same media inside one result (for example an MP4 next to a WebM). If any is an MP4, it's used, so videos play natively with sound.", "file_url_mp4")
        e(.tagSpaceReplacement, "Space inside a tag", "Optional. Many sites write multi-word tags with _ (blue_sky). Type a multi-word tag in \"quotes\" in the search bar and its spaces become this.", "_")
        e(.randomTag, "Random tag", "Optional. For the dice button: a tag that makes the site return random results (used only when no Sort choice contains 'random').", "order:random")
        e(.authUserParamName, "User ID name", "Optional. If the site wants your user ID next to the API key, the address parameter's name (like user_id). Your ID goes in the Account screen's Username field.", "user_id")
        e(.apiKeyPageURL, "API key page", "Optional. Full address (or a path added to the base address) of the page that shows your API key once logged in. Used by 'Log in to get my key'.", "account/api")
        e(.tagCategoryKey, "Tag category key", "Optional. If each tag is an object with a category (like artist or character), which key holds it. Tags are then colored by category in the Info panel.", "category")
        e(.galleryPath, "Gallery pages", "Optional. Inside one result: the list of pages of a multi-page post (comic, album). Those posts open as a scrolling reader with a page counter.", "pages")
        e(.zipExtensions, "Animation archive types", "Address endings of ZIP files that hold an animation frame by frame (e.g. zip). They play like a GIF.", "zip")
        e(.zipFramesPath, "Animation frames", "Optional. Inside one result: the list of frames with their delays, like [{\"file\": \"000.jpg\", \"delay\": 80}] (milliseconds). Without it, an animation.json inside the archive is used, or 100 ms per frame.", "frames")
        e(.galleryURLKey, "Gallery page key", "If each page is an object, which key holds the page's address.", "url")
        e(.favoritePath, "Account favorites address", "Optional. Added to the base address; {id} is the post ID. When set and you're logged in, favoriting also saves to your account (POST), and unfavoriting removes it (DELETE).", "favorites/{id}")
        e(.relatedTagsPath, "Related tags address", "Optional. Added to the base address; {tag} is replaced by a tag. When set, the Info panel shows tags that often appear with it.", "tags/related.json?tag={tag}")
        e(.wikiPath, "Tag description address", "Optional. Added to the base address; {tag} is replaced by a tag. When set, holding a tag in the Info panel shows its description.", "wiki/{tag}.json")
        e(.tagAliasesPath, "Tag aliases address", "Optional. Added to the base address; {tag} is replaced by a tag. Shows the tag's other names in its description.", "aliases.json?tag={tag}")
        e(.votePath, "Vote address", "Optional. Added to the base address; {id} is replaced by the post ID. When set, the viewer shows a vote button (sent as POST, usually needs a login). MediaDeck never tries this on its own because voting changes data on the site.", "posts/{id}/vote")
        e(.accountSettingsPath, "Account settings address", "Optional. Added to the base address; answers with your account's settings when logged in. After logging in, MediaDeck offers to import your site blacklist and default sort/rating from it.", "account.json")
        e(.registerURL, "Sign-up page", "Optional. Full address (or a path added to the base address) of the site's sign-up page. The Account screen then shows 'Create an account'.", "register")
        e(.autocompletePath, "Suggestions address", "Optional. Added to the base address to get tag suggestions. {query} is replaced by what you're typing.", "tags/autocomplete.json?q={query}")
        e(.autocompleteResultsPath, "Suggestions list", "Where the list of suggestions is in that answer. Leave empty if the answer itself is the list.", "results")
        e(.autocompleteNameKey, "Suggestion name key", "If suggestions are objects, which key holds the tag text. Defaults to name.", "name")
        return d
    }()

    static func entry(_ k: AdapterConfig.CodingKeys) -> Entry {
        entries[k] ?? Entry(key: k, title: k.rawValue, help: "", example: "", required: false)
    }

    static let howItWorks = """
    An "adapter" teaches MediaDeck how to talk to one site. Every adapter is a block of settings in a file called adapters.json — you never need to write code.

    1. Export adapters.json (button below) and save it to Files.
    2. Open it in any text editor. Copy one of the existing blocks between { and } and change the values. Every field is explained in the Field Guide.
    3. To find the right "paths", open the Field Mapper, paste an answer from the site, and tap Analyze. Every piece of the answer is listed with its path. Tap "Use as…" to put it in the right field, or "Copy" to paste it into your file.
    4. Import the file back, then open the adapter and tap "Test adapter" to check it works.

    You can also skip the file completely: tap "Add Adapter" and fill in the form.
    The file also lives in the Files app under On My iPhone › MediaDeck › adapters.json; changes there are picked up automatically.
    """
}
