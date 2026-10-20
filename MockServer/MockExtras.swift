import Foundation

/// Demo routes for account & capability features (Phase 7/8): discovery hints, related tags,
/// tag descriptions, aliases, voting, account settings, favorites sync, sign-up and the
/// key-plus-user-ID "Site K". All data is synthetic.
enum MockExtras {
    /// 64-hex demo API key used by Site K (shown on its account page).
    static let siteKKey = "9f2c5e8a7b1d4c3e6f0a2b5c8d1e4f7a9b2c5d8e1f4a7b0c3d6e9f2a5b8c1d4e"
    static let siteKUserID = "42"

    static let aliasTable: [String: [String]] = [
        "blue": ["navy", "azure"], "red": ["crimson"], "gray": ["grey"], "dots": ["polka_dots"],
        "stripes": ["striped"], "animated": ["gif"],
    ]

    // MARK: Root page with discovery hints

    static func rootPage(port: UInt16) -> HTTPResponse {
        let o = "http://127.0.0.1:\(port)"
        return .text("""
        <!doctype html><html><head><title>Demo server</title>
        <link rel="search" type="application/opensearchdescription+xml" title="Demo A" href="\(o)/a/opensearch.xml">
        </head><body><h1>MediaDeck demo server</h1><p>Synthetic content only.</p></body></html>
        """, type: "text/html; charset=utf-8")
    }

    static func openSearch(origin: String) -> HTTPResponse {
        .text("""
        <?xml version="1.0" encoding="UTF-8"?>
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <ShortName>Demo A</ShortName>
          <Url type="text/html" template="\(origin)/a/view?q={searchTerms}"/>
          <Url type="application/json" template="\(origin)/a/posts.json?tags={searchTerms}&amp;page={startPage?}"/>
        </OpenSearchDescription>
        """, type: "application/opensearchdescription+xml")
    }

    // MARK: Site A extras (shared by /a, /a/members and /a/secure)

    /// `member` = the request is logged in.
    static func siteAExtra(_ sub: String, req: HTTPRequest, origin: String, member: Bool) -> HTTPResponse? {
        if sub == "/opensearch.xml" { return openSearch(origin: origin) }
        if sub == "/tags/related.json" {
            let tag = (req.query["tag"] ?? "").lowercased()
            let with = MockCatalog.items.filter { $0.tags.contains(tag) }
            var counts: [String: Int] = [:]
            for i in with { for t in i.tags where t != tag { counts[t, default: 0] += 1 } }
            let list = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(8)
            return .json(["tag": tag, "related": list.map { ["name": $0.key, "count": $0.value] }])
        }
        if sub.hasPrefix("/wiki/") {
            let tag = String(sub.dropFirst(6)).replacingOccurrences(of: ".json", with: "").removingPercentEncoding ?? ""
            let count = MockCatalog.items.filter { $0.tags.contains(tag) }.count
            guard count > 0 else { return .json(["message": "No description for \"\(tag)\" yet."], status: 404) }
            return .json(["title": tag, "body": "Demo description: \(count) generated posts are tagged \"\(tag)\". Tags group posts by color, pattern, shape or kind.",
                          "updated_at": "2026-01-01"])
        }
        if sub == "/aliases.json" {
            return .json(["aliases": aliasTable[(req.query["tag"] ?? "").lowercased()] ?? []])
        }
        if sub.hasPrefix("/posts/"), sub.hasSuffix("/vote") {
            guard member else { return .json(["message": "Log in to vote."], status: 401) }
            return .json(["message": "Thanks! Your vote was counted.", "score": Int.random(in: 10...99)])
        }
        if sub == "/votes.json" || sub == "/favorites.json" {
            guard member else { return .json(["message": "Log in to see this."], status: 401) }
            return .json(["items": [], "count": 0])
        }
        if sub.hasPrefix("/favorites/") {
            guard member else { return .json(["message": "Log in to save favorites to your account."], status: 401) }
            return .json(["message": "Added to your account's favorites."])
        }
        if sub == "/account.json" {
            guard member else { return .json(["message": "Log in to see your account."], status: 401) }
            return .json(["user": ["name": "demo", "settings": ["blacklisted_tags": "gray stripes", "default_sort": "score", "default_rating": "general"]]])
        }
        if sub == "/register" {
            return .text(signUpPage(title: "Create a demo account"), type: "text/html; charset=utf-8")
        }
        return nil
    }

    static func signUpPage(title: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title></head><body><header class="site-header">Demo header</header>
        <h1>\(title)</h1><form><label>Username <input name="username"></label><br>
        <label>Email <input name="email" type="email"></label><br>
        <label>Password <input name="password" type="password"></label><br>
        <button type="button">Sign up (demo)</button></form><footer>Demo footer</footer></body></html>
        """
    }

    // MARK: Site K: key + user ID in the address, guests limited

    enum KAuth { case guest, missingUser, ok, bad }

    static func kAuth(_ req: HTTPRequest) -> KAuth {
        guard let key = req.query["api_key"], !key.isEmpty else { return .guest }
        guard key == siteKKey else { return .bad }
        guard let uid = req.query["user_id"], !uid.isEmpty else { return .missingUser }
        return uid == siteKUserID ? .ok : .bad
    }

    static func siteK(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        let auth = kAuth(req)
        switch auth {
        case .missingUser:
            return .json(["error": "Invalid credentials: user_id is required together with api_key."], status: 401)
        case .bad:
            return .json(["error": "Invalid credentials: wrong api_key or user_id."], status: 401)
        default: break
        }
        let member = auth == .ok
        switch sub {
        case "", "/":
            return .text("<!doctype html><html><head><title>Demo K</title><link rel=\"alternate\" type=\"application/json\" href=\"\(origin)/k/posts.json\"></head><body><h1>Demo K</h1></body></html>",
                         type: "text/html; charset=utf-8")
        case "/posts.json":
            let words = (req.query["tags"] ?? "").replacingOccurrences(of: "+", with: " ").split(separator: " ")
            if !member && words.count > 2 {
                return .json(["message": "Guests can search up to 2 tags at once. Log in for more."], status: 422)
            }
            let all = MockCatalog.search(tagQuery: req.query["tags"] ?? "", sort: nil, rating: nil)
            let page = max(1, Int(req.query["page"] ?? "1") ?? 1)
            let start = (page - 1) * MockCatalog.pageSize
            let slice = start < all.count ? Array(all[start..<min(all.count, start + MockCatalog.pageSize)]) : []
            var body: [String: Any] = [
                "posts": slice.map { i -> [String: Any] in
                    [
                        "id": i.n, "tags": i.tags, "file_ext": i.kind,
                        "preview_url": "\(origin)/media/\(i.thumbFile)",
                        "file_url": member ? "\(origin)/media/\(i.mediaFile)" as Any : NSNull(),
                    ]
                },
                "has_more": start + MockCatalog.pageSize < all.count,
            ]
            if !member { body["notice"] = "Preview only: log in to see full-size files." }
            return .json(body)
        case "/favorites.json", "/votes.json":
            guard member else { return .json(["message": "Log in to use this."], status: 401) }
            return .json(["items": []])
        case "/account.json":
            guard member else { return .json(["message": "Log in to see your account."], status: 401) }
            return .json(["user": ["id": 42, "blacklisted_tags": ["gray", "stripes"], "default_sort": "score"]])
        case "/login":
            return .text("""
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Log in</title></head>
            <body><header class="site-header">Demo K header</header><div class="ad-banner">Advertisement</div>
            <h1>Log in</h1><form action="/k/account" method="get">
            <label>Username <input name="username"></label><br><label>Password <input name="password" type="password"></label><br>
            <button type="submit">Log in</button></form><footer>Demo K footer</footer></body></html>
            """, type: "text/html; charset=utf-8")
        case "/account":
            return .text("""
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>My account</title></head>
            <body><header class="site-header">Demo K header</header><h1>My account</h1>
            <dl><dt>User ID</dt><dd>\(siteKUserID)</dd><dt>API key</dt><dd><code>\(siteKKey)</code></dd></dl>
            <p>Use these with the API: <code>&amp;api_key=…&amp;user_id=…</code></p><footer>Demo K footer</footer></body></html>
            """, type: "text/html; charset=utf-8")
        case "/register":
            return .text(signUpPage(title: "Create a Demo K account"), type: "text/html; charset=utf-8")
        default:
            return .json(["error": "not found"], status: 404)
        }
    }
}
