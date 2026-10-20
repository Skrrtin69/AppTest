import Foundation

/// Demo "Vault" site for the log-in-and-find-my-key flow:
///   /v/posts.json?tags=&page=&api_key=&user_id=  → 401 without the key, demo results with it
///   /v/                                          → "Auth Required" page with a login form
///   /v/account?username=&password=               → account page: user ID, the API key in a
///                                                  read-only box, a session code (not a key)
///   /v/developer                                 → two keys (current and legacy), for the picker
enum MockVault {
    static let apiKey = "7f3a9c2e5b1d4086a9e2c7f15b3d8e64"
    static let legacySecret = "LGC4e81b07d2a9f356c"
    static let userID = "4821"
    static let sessionCode = "s3ss10n4b8c2d9e1f7a6"

    static func respond(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        switch sub {
        case "/posts.json":
            guard req.query["api_key"] == apiKey, req.query["user_id"] == userID else {
                return .json(["error": "Authentication required. Log in, then use your api_key and user_id."], status: 401)
            }
            return MockRoutes.siteA("/posts.json", req: req, origin: origin)
        case "", "/", "/login":
            return html("Auth Required", """
            <div style="background:#c62;color:#fff;padding:10px;border-radius:8px"><b>Auth Required</b> — log in to use the API.</div>
            <h1>Log in</h1>
            <form action="/v/account" method="get">
            <p><label>Username <input name="username" autocomplete="username"></label></p>
            <p><label>Password <input name="password" type="password" autocomplete="current-password"></label></p>
            <p><button type="submit">Log in</button></p></form>
            <p style="opacity:.6">Demo login: demo / demo</p>
            """)
        case "/account":
            guard req.query["username"] == MockRoutes.demoUser, req.query["password"] == MockRoutes.demoPassword else {
                return html("Log in failed", "<h1>Wrong username or password</h1><p><a href=\"/v/\">Try again</a></p>", status: 401)
            }
            return html("My account", """
            <h1>Welcome, \(MockRoutes.demoUser)</h1>
            <p>Session: \(sessionCode)</p>
            <h2>API access</h2>
            <dl><dt>User ID</dt><dd>\(userID)</dd></dl>
            <p><label for="key">API Key</label><br><input id="key" type="text" readonly value="\(apiKey)" style="width:100%"></p>
            <p>Example request: <code>/v/posts.json?tags=blue&amp;api_key=\(apiKey)&amp;user_id=\(userID)</code></p>
            <p><a href="/v/developer">Developer settings</a> · <a href="/v/combined">API credentials</a></p>
            """)
        case "/combined":
            // Key and user ID in one box, ready to paste after an address.
            return html("API credentials", """
            <h1>API credentials</h1>
            <p><label>Your credentials<br><input type="text" readonly value="&api_key=\(apiKey)&user_id=\(userID)" style="width:100%"></label></p>
            """)
        case "/developer":
            return html("Developer settings", """
            <h1>Developer settings</h1>
            <p>API Key: \(apiKey)</p>
            <p>Secret (legacy apps): \(legacySecret)</p>
            <p>User ID: \(userID)</p>
            """)
        default:
            return .json(["error": "not found"], status: 404)
        }
    }

    /// /legacy: an old-style board. /legacy/index.php?page=dapi… answers plain text
    /// "Missing authentication…" with 200 OK unless the Vault key and user ID are sent;
    /// /legacy/ is the Vault login page.
    static func legacy(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        switch sub {
        case "/index.php" where req.query["page"] == "dapi":
            guard req.query["api_key"] == apiKey, req.query["user_id"] == userID else {
                return .text("Missing authentication. Go to the account options page to get an API key and user ID.")
            }
            return MockRoutes.siteA("/posts.json", req: req, origin: origin)
        case "", "/":
            return respond("/", req: req, origin: origin)
        default:
            return .json(["error": "not found"], status: 404)
        }
    }

    /// New every launch, so the check can be tried again after a restart.
    static let clearance = "cf_clearance=demo-\(UUID().uuidString.prefix(8))"

    /// /cf: behaves like a site behind Cloudflare. Without the clearance cookie every page
    /// (API included) is a 403 check page with Cloudflare's headers; /cf/verify sets it.
    static func cloudflare(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        let passed = req.headers["cookie"]?.contains(clearance) == true
        if sub == "/verify" {
            var r = HTTPResponse.text(cfPage("Verified", "<h1>You're verified</h1><p>You can close this page.</p>"),
                                      type: "text/html; charset=utf-8")
            r.headers["Set-Cookie"] = "\(clearance); Path=/; Max-Age=86400"
            return r
        }
        guard passed else {
            var r = HTTPResponse.text(cfPage("Just a moment...", """
            <h1>Just a moment...</h1><p>Checking your browser before accessing this site.</p>
            <p><a href="/cf/verify" style="display:inline-block;padding:12px 18px;border:1px solid #888;border-radius:8px">Verify you are human</a></p>
            """), status: 403, type: "text/html; charset=utf-8")
            r.headers["cf-ray"] = "8f00demo0000-LAX"
            r.headers["Server"] = "cloudflare"
            return r
        }
        if sub == "/posts.json" { return MockRoutes.siteA("/posts.json", req: req, origin: origin) }
        if sub != "" && sub != "/" {
            return .text(cfPage("Page not found", "<h1>404 Page not found</h1><p><a href=\"/cf/\">Return to homepage</a></p>"),
                         status: 404, type: "text/html; charset=utf-8")
        }
        return .text(cfPage("Demo CF site", "<h1>Demo site behind a check</h1>"), type: "text/html; charset=utf-8")
    }

    private static func cfPage(_ title: String, _ body: String) -> String {
        "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\(title)</title></head><body style=\"font:17px -apple-system;padding:24px\">\(body)</body></html>"
    }

    /// /mv: a site behind Cloudflare whose old API paths answer 403 text/plain
    /// "Use new API…" (with cf-ray and Server: cloudflare, but no challenge); the
    /// working API is /mv/api/v2/search, which needs no login.
    static func movedAPI(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        var r: HTTPResponse
        if sub == "/api/v2/search" {
            var q = req
            q.query["tags"] = req.query["query"]
            r = MockRoutes.siteA("/posts.json", req: q, origin: origin)
        } else if sub.hasPrefix("/api/") {
            r = .text("Use new API \(origin)/mv/api/v2/docs", status: 403)
        } else if sub == "" || sub == "/" {
            r = .text(cfPage("Demo moved API", "<h1>Demo site</h1><p>Normal home page, no check.</p>"), type: "text/html; charset=utf-8")
        } else {
            r = .text(cfPage("Not found", "<h1>404</h1>"), status: 404, type: "text/html; charset=utf-8")
        }
        r.headers["cf-ray"] = "8f00demo0001-LAX"
        r.headers["Server"] = "cloudflare"
        return r
    }

    /// /lb1 and /lb2: open legacy boards. /lb1 suggests at index.php?page=autocomplete2&term=
    /// (counts as strings; q= gets an empty list). /lb2 redirects public/autocomplete.php to
    /// /lb2/ac/autocomplete.php, which sends JSON as text/html with the count in the label.
    static func legacyBoard(_ name: String, _ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        func tags(_ q: String) -> [(tag: String, count: Int)] { MockCatalog.suggestions(q.lowercased()).map { ($0.tag, $0.count) } }
        switch sub {
        case "/index.php" where req.query["page"] == "dapi":
            return MockRoutes.siteA("/posts.json", req: req, origin: origin)
        case "/index.php" where req.query["page"] == "autocomplete2" && name == "lb1":
            guard let term = req.query["term"] else { return .json([]) }
            return .json(tags(term).map { ["type": "tag", "label": $0.tag.replacingOccurrences(of: "_", with: " "), "value": $0.tag,
                                           "post_count": String($0.count), "category": "tag"] })
        case "/public/autocomplete.php" where name == "lb2":
            var r = HTTPResponse.text("<html><body>302 Found</body></html>", status: 302, type: "text/html")
            r.headers["Location"] = "\(origin)/lb2/ac/autocomplete.php?q=\(req.query["q"] ?? "")"
            return r
        case "/ac/autocomplete.php" where name == "lb2":
            let list = tags(req.query["q"] ?? "").map { ["label": "\($0.tag) (\($0.count))", "value": $0.tag, "type": "general"] }
            let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
            return .text(String(decoding: data, as: UTF8.self), type: "text/html; charset=UTF-8")
        default:
            return .text("<html><body><h1>404</h1></body></html>", status: 404, type: "text/html")
        }
    }

    /// /hk/posts.json: only "Authorization: Key <key>" is accepted.
    static func keyHeaderSite(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        guard sub == "/posts.json" else { return .json(["error": "not found"], status: 404) }
        guard req.headers["authorization"] == "Key \(apiKey)" else {
            return .json(["error": "Send your key as: Authorization: Key <your key>"], status: 401)
        }
        return MockRoutes.siteA("/posts.json", req: req, origin: origin)
    }

    /// /h/posts.json: the same key, but only accepted in an X-Api-Key header.
    static func headerSite(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        guard sub == "/posts.json" else { return .json(["error": "not found"], status: 404) }
        guard req.headers["x-api-key"] == apiKey else {
            return .json(["error": "Missing or wrong X-Api-Key header."], status: 401)
        }
        return MockRoutes.siteA("/posts.json", req: req, origin: origin)
    }

    private static func html(_ title: String, _ body: String, status: Int = 200) -> HTTPResponse {
        .text("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(title)</title></head>
        <body style="padding:16px"><header class="site-header">Demo Vault</header>\(body)<footer>Demo Vault footer</footer></body></html>
        """, status: status, type: "text/html; charset=utf-8")
    }
}
