import Foundation

/// URL routing for the demo server.
///
/// Site A (flat JSON, page numbers):
///   /a/posts.json?tags=&page=&sort=&rating=      → { "posts": [ {id, preview_url, file_url, file_ext, tags:[..]} ], "has_more" }
///   /a/post/{id}.json                            → the post object
///   /a/secure/...                                → same, but needs a login (user "demo", password "demo",
///                                                  or API key "demo-key" via ?api_key= or X-Api-Key header)
///   /a/secure/auth/check                         → 200 when logged in, 401 otherwise
/// Site B (nested JSON, cursors, relative media URLs):
///   /b/search?q=&cursor=&order=                  → { "data": { "items": [ { "post": { id, media:{thumb,full,kind}, tag_list:[{name}] } } ], "next_cursor", "has_next" } }
///   /b/item/{id}                                 → { "data": { "item": { "post": {...} } } }
/// Media (any path containing /media/): img, sample, thumb, vthumb, gif, video
enum MockRoutes {
    static let demoUser = "demo"
    static let demoPassword = "demo"
    static let demoAPIKey = "demo-key"

    static func respond(to req: HTTPRequest, port: UInt16) -> HTTPResponse {
        let p = req.path
        let origin0 = "http://127.0.0.1:\(port)"
        // Demo "hotlink-protected" site: its media only loads with a Referer from the site;
        // otherwise it answers 200 with an HTML page, like real hotlink protection does.
        if p.hasPrefix("/h/") {
            if let r = p.range(of: "/media/") {
                guard (req.headers["referer"] ?? "").hasPrefix(origin0 + "/h") else {
                    return .text("<!doctype html><html><head><title>Hotlinking is not allowed</title></head><body><h1>Hotlinking is not allowed</h1></body></html>",
                                 type: "text/html; charset=utf-8")
                }
                return MockMedia.serve(String(p[r.upperBound...]))
            }
            return siteA(String(p.dropFirst(2)), req: req, origin: origin0 + "/h")
        }
        if let r = p.range(of: "/media/") {
            return MockMedia.serve(String(p[r.upperBound...]))
        }
        let origin = "http://127.0.0.1:\(port)"
        switch true {
        case p == "/":
            return MockExtras.rootPage(port: port)
        case p == "/health":
            return .text("MediaDeck demo server OK")
        case p == "/a/secure/register":
            // A sign-up page never needs a login.
            return .text(MockExtras.signUpPage(title: "Create a demo account"), type: "text/html; charset=utf-8")
        case p.hasPrefix("/a/secure/"):
            guard isAuthorized(req) else {
                var r = HTTPResponse.json(["error": "login required"], status: 401)
                r.headers["WWW-Authenticate"] = "Basic realm=\"demo\""
                return r
            }
            let sub = String(p.dropFirst("/a/secure".count))
            return MockExtras.siteAExtra(sub, req: req, origin: origin, member: true) ?? siteA(sub, req: req, origin: origin)
        case p.hasPrefix("/a/members/"):
            // Works without a login, but guests get fewer files (guest-limit demo).
            let sub = String(p.dropFirst("/a/members".count))
            let member = isAuthorized(req)
            return MockExtras.siteAExtra(sub, req: req, origin: origin, member: member)
                ?? siteA(sub, req: req, origin: origin, guestLimited: !member)
        case p.hasPrefix("/a/"):
            let sub = String(p.dropFirst(2))
            return MockExtras.siteAExtra(sub, req: req, origin: origin, member: false) ?? siteA(sub, req: req, origin: origin)
        case p == "/index.php":
            return .text("<!doctype html><html><head><title>Demo home</title></head><body><h1>Demo home page</h1></body></html>",
                         type: "text/html; charset=utf-8")
        case p == "/api/v1/posts":
            return siteA("/posts.json", req: req, origin: origin)
        case p == "/legacy" || p.hasPrefix("/legacy/"):
            return MockVault.legacy(String(p.dropFirst("/legacy".count)), req: req, origin: origin)
        case p.hasPrefix("/h/"):
            return MockVault.headerSite(String(p.dropFirst(2)), req: req, origin: origin)
        case p == "/v" || p.hasPrefix("/v/"):
            return MockVault.respond(String(p.dropFirst(2)), req: req, origin: origin)
        case p.hasPrefix("/rs/"):
            return MockReverse.respond(req, origin: origin)
        case p.hasPrefix("/u/") || p == "/u":
            return MockFormats.respond(String(p.dropFirst(2)), req: req, origin: origin)
        case p.hasPrefix("/g/") || p == "/g":
            return MockGallery.respond(String(p.dropFirst(2)), req: req, origin: origin)
        case p.hasPrefix("/k"):
            return MockExtras.siteK(String(p.dropFirst(2)), req: req, origin: origin)
        case p.hasPrefix("/b/"):
            return siteB(String(p.dropFirst(2)), req: req, origin: origin)
        case p.hasPrefix("/c/"):
            return siteC(String(p.dropFirst(2)), req: req, origin: origin)
        case p.hasPrefix("/html/"):
            // A normal web page, so Auto-Configure's "not a JSON API" message can be seen.
            return .text("<!doctype html><html><head><title>Demo page</title></head><body><h1>Demo web page</h1><p>This is HTML for browsers, not a JSON API.</p></body></html>",
                         type: "text/html; charset=utf-8")
        default:
            return .json(["error": "not found", "path": p], status: 404)
        }
    }

    static func isAuthorized(_ req: HTTPRequest) -> Bool {
        if req.query["api_key"] == demoAPIKey || req.headers["x-api-key"] == demoAPIKey { return true }
        if let auth = req.headers["authorization"], auth.hasPrefix("Basic "),
           let data = Data(base64Encoded: String(auth.dropFirst(6))),
           String(decoding: data, as: UTF8.self) == "\(demoUser):\(demoPassword)" {
            return true
        }
        return false
    }

    // MARK: Site A

    static func siteA(_ sub: String, req: HTTPRequest, origin: String, guestLimited: Bool = false) -> HTTPResponse {
        if sub == "/auth/check" { return .json(["ok": true, "user": demoUser]) }
        if sub == "/tags/autocomplete.json" {
            let q = (req.query["q"] ?? "").lowercased()
            var list: [[String: Any]] = MockCatalog.suggestions(q).map {
                ["name": $0.tag, "post_count": $0.count,
                 "category": MockCatalog.colors.contains($0.tag) ? "color" : (MockCatalog.patterns.contains($0.tag) ? "pattern" : "general")]
            }
            // A tag nobody uses any more (0 posts), so the dimmed style can be seen.
            if !list.isEmpty || q.count >= 2 { list.append(["name": "\(q)_unused", "post_count": 0]) }
            return .json(list)
        }
        if sub == "/posts.json" {
            if let forced = forcedError(req.query["tags"] ?? "") { return forced }
            let all = MockCatalog.search(tagQuery: req.query["tags"] ?? "", sort: req.query["sort"], rating: req.query["rating"])
            let page = max(1, Int(req.query["page"] ?? "1") ?? 1)
            let start = (page - 1) * MockCatalog.pageSize
            let slice = start < all.count ? Array(all[start..<min(all.count, start + MockCatalog.pageSize)]) : []
            if guestLimited {
                // Guests don't get files for "sensitive" posts.
                let hidden = slice.filter { $0.rating == "sensitive" }.count
                return .json([
                    "posts": slice.map { i -> [String: Any] in
                        var d = siteAPost(i, origin: origin)
                        if i.rating == "sensitive" { d["file_url"] = NSNull(); d["sample_url"] = NSNull() }
                        return d
                    },
                    "page": page,
                    "has_more": start + MockCatalog.pageSize < all.count,
                    "notice": "Some files are only shown to members. Log in to see them.",
                    "hidden_count": hidden,
                ])
            }
            return .json([
                "posts": slice.map { siteAPost($0, origin: origin) },
                "page": page,
                "total": all.count,
                "has_more": start + MockCatalog.pageSize < all.count,
            ])
        }
        if sub.hasPrefix("/post/"), let n = Int(sub.dropFirst(6).replacingOccurrences(of: ".json", with: "")),
           (1...MockCatalog.count).contains(n) {
            return .json(siteAPost(MockCatalog.items[n - 1], origin: origin))
        }
        if sub == "/pools.json" {
            return .json(MockCatalog.pools(page: Int(req.query["page"] ?? "1") ?? 1, search: req.query["search"] ?? ""))
        }
        if sub.hasPrefix("/archive/") {
            let id = String(sub.dropFirst("/archive/".count))
            return .text("<!doctype html><html><head><meta name='viewport' content='width=device-width'><title>Demo archive</title></head><body style='font:18px -apple-system;padding:24px'><h1>Archive for post \(id)</h1><p>A real service would build a PDF, EPUB or CBZ here.</p><p><a href='#'>Download CBZ</a> · <a href='#'>Download PDF</a></p></body></html>",
                         type: "text/html; charset=utf-8")
        }
        if sub.hasPrefix("/view/") {
            // A post that doesn't exist (e.g. 999) acts like a deleted page.
            guard let n = Int(sub.dropFirst(6)), (1...MockCatalog.count).contains(n) else {
                return .text("<html><body><h1>This post was deleted.</h1></body></html>", status: 404, type: "text/html; charset=utf-8")
            }
            return .text("<html><body style='font:20px -apple-system;padding:40px'><h1>Demo post \(n)</h1><p>This is the demo server's \"source\" page.</p></body></html>",
                         type: "text/html; charset=utf-8")
        }
        return .json(["error": "not found"], status: 404)
    }

    static func siteAPost(_ i: MockItem, origin: String) -> [String: Any] {
        [
            "id": i.n,
            "preview_url": "\(origin)/media/\(i.thumbFile)",
            "sample_url": "\(origin)/media/\(i.sampleFile)",
            "file_url": "\(origin)/media/\(i.mediaFile)",
            "file_ext": i.kind,
            "width": i.width,
            "height": i.height,
            "tags": i.tags,
            "rating": i.rating,
            "score": i.score,
            "created_at": i.created,
            "source": "\(origin)/a/view/\(i.n)",
            "uploader": MockCatalog.uploaders[i.n % MockCatalog.uploaders.count],
            "file_url_mp4": i.mp4Alternate.map { "\(origin)/media/\($0)" as Any } ?? NSNull(),
        ]
    }

    /// Demo of real-world error answers, each in a different shape, so the app's generic
    /// ErrorParser can be seen working. Triggered by search words.
    static func forcedError(_ tagQuery: String) -> HTTPResponse? {
        let words = tagQuery.replacingOccurrences(of: "+", with: " ").split(separator: " ").map { String($0).lowercased() }
        if words.count > 6 {
            return .json(["success": false, "message": "You can search for at most 6 tags at a time."], status: 422)
        }
        if words.contains("slowdown") {
            return .json(["error": ["code": "rate_limited", "message": "Too many requests. Please wait a moment and try again."]], status: 429)
        }
        if words.contains("boom") {
            return .text("<!doctype html><html><head><title>Down for maintenance</title></head><body><h1>Down for maintenance</h1><p>Back soon.</p></body></html>",
                         status: 503, type: "text/html; charset=utf-8")
        }
        return nil
    }

    // MARK: Site B

    static func siteB(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        if sub == "/suggest" {
            let list = MockCatalog.suggestions(req.query["q"] ?? "").map { ["label": $0.tag, "posts": $0.count] }
            return .json(["data": ["suggestions": list]])
        }
        if sub == "/search" {
            if let words = req.query["q"]?.lowercased(), words.contains("offline") {
                // Demo of one site failing inside a merged search (Site A ignores "-offline").
                return .json(["detail": "Demo Site B is offline for this search."], status: 400)
            }
            if let words = req.query["q"]?.lowercased(), words.contains("slowdown") {
                return .json(["errors": [["status": "429", "detail": "Rate limit exceeded: 3 searches per second."]]], status: 429)
            }
            let all = MockCatalog.search(tagQuery: req.query["q"] ?? "", sort: req.query["order"], rating: req.query["rating"])
            // Cursor is an opaque-looking token encoding the offset.
            let offset = decodeCursor(req.query["cursor"])
            let end = min(all.count, offset + MockCatalog.pageSize)
            let slice = offset < all.count ? Array(all[offset..<end]) : []
            let hasNext = end < all.count
            return .json([
                "data": [
                    "items": slice.map { ["post": siteBPost($0, origin: origin)] },
                    "has_next": hasNext,
                    "next_cursor": hasNext ? encodeCursor(end) as Any : NSNull() as Any,
                ],
                "meta": ["count": slice.count, "total": all.count],
            ])
        }
        if sub.hasPrefix("/item/"), let n = Int(sub.dropFirst(6).replacingOccurrences(of: "b-", with: "")),
           (1...MockCatalog.count).contains(n) {
            return .json(["data": ["item": ["post": siteBPost(MockCatalog.items[n - 1], origin: origin)]]])
        }
        if sub.hasPrefix("/view/") {
            guard let n = Int(sub.dropFirst(6)), (1...MockCatalog.count).contains(n) else {
                return .text("<html><body><h1>This item was deleted.</h1></body></html>", status: 404, type: "text/html; charset=utf-8")
            }
            return .text("<html><body style='font:20px -apple-system;padding:40px'><h1>Demo B item \(sub.dropFirst(6))</h1></body></html>",
                         type: "text/html; charset=utf-8")
        }
        return .json(["error": "not found"], status: 404)
    }

    static func siteBPost(_ i: MockItem, origin: String) -> [String: Any] {
        [
            "id": "b-\(i.n)",
            "media": [
                // Relative on purpose: the adapter joins these to its mediaBaseURL.
                "thumb": "media/\(i.thumbFile)",
                "full": "media/\(i.mediaFile)",
                "kind": i.kind,
                "alt_mp4": i.mp4Alternate.map { "media/\($0)" as Any } ?? NSNull(),
                "w": i.width,
                "h": i.height,
            ],
            "tag_list": i.tags.map { ["name": $0, "count": 1, "category": MockCatalog.colors.contains($0) ? "color" : (MockCatalog.patterns.contains($0) ? "pattern" : "general")] },
            "author": ["name": "generator-\(i.n % 5)"],
            "links": ["source": "\(origin)/b/view/\(i.n)"],
            "stats": ["score": i.score],
        ]
    }

    // MARK: Site C (deliberately unclear: one address field with a non-descriptive name)

    static func siteC(_ sub: String, req: HTTPRequest, origin: String) -> HTTPResponse {
        guard sub == "/list.json" else { return .json(["error": "not found"], status: 404) }
        // Site C writes tags as "kind_word" (color_blue, pattern_dots); accept either form.
        let query = (req.query["tags"] ?? "").replacingOccurrences(of: "+", with: " ")
            .split(separator: " ").map { w -> String in
                let s = String(w)
                let neg = s.hasPrefix("-")
                let body = neg ? String(s.dropFirst()) : s
                let plain = body.split(separator: "_", maxSplits: 1).count == 2 && siteCPrefixes.contains(String(body.split(separator: "_")[0]))
                    ? String(body.split(separator: "_", maxSplits: 1)[1]) : body
                return (neg ? "-" : "") + plain
            }.joined(separator: " ")
        let all = MockCatalog.search(tagQuery: query, sort: nil, rating: nil)
        let page = max(1, Int(req.query["page"] ?? "1") ?? 1)
        let start = (page - 1) * MockCatalog.pageSize
        let slice = start < all.count ? Array(all[start..<min(all.count, start + MockCatalog.pageSize)]) : []
        return .json([
            "entries": slice.map { ["ref": "c-\($0.n)", "link": "\(origin)/media/img/\($0.n).png", "labels": $0.tags.map(siteCLabel)] },
            "has_more": start + MockCatalog.pageSize < all.count,
        ])
    }

    static let siteCPrefixes = ["color", "pattern", "shape", "kind", "extra"]

    static func siteCLabel(_ tag: String) -> String {
        if tag.contains("_") { return tag }
        if MockCatalog.colors.contains(tag) { return "color_" + tag }
        if MockCatalog.patterns.contains(tag) { return "pattern_" + tag }
        if ["landscape", "portrait", "square"].contains(tag) { return "shape_" + tag }
        if ["still", "animated", "video", "webm", "mp4"].contains(tag) { return "kind_" + tag }
        return "extra_" + tag
    }

    static func encodeCursor(_ offset: Int) -> String {
        Data("off:\(offset)".utf8).base64EncodedString()
    }

    static func decodeCursor(_ c: String?) -> Int {
        guard let c = c?.nonEmpty, let d = Data(base64Encoded: c) else { return 0 }
        let s = String(decoding: d, as: UTF8.self)
        return Int(s.replacingOccurrences(of: "off:", with: "")) ?? 0
    }
}
