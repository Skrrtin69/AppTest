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
