import Foundation

/// Demo reverse image search: accepts an uploaded picture (or a ?url=) and answers with a few
/// made-up matches that point at demo Site A posts, so tapping one opens it in the app.
enum MockReverse {
    static func respond(_ req: HTTPRequest, origin: String) -> HTTPResponse {
        guard req.path == "/rs/search" else { return .json(["error": "not found"], status: 404) }
        if req.query["api_key"] == "bad" {
            return .json(["header": ["status": -1, "message": "Invalid API key. Get one on your <a href=\"https://example.invalid/user\">account page</a> &amp; try again."]], status: 403)
        }
        // Something to search with: an uploaded file or an address.
        let seed: Int
        if req.method == "POST" {
            // Like real engines: the file must arrive as a multipart part named "file", it
            // must be a picture (JPEG/PNG, not a video), and no url parameter may compete.
            let head = String(decoding: req.body.prefix(600), as: UTF8.self)
            let isMultipart = (req.headers["content-type"] ?? "").contains("multipart/form-data; boundary=")
            let hasFile = head.contains("name=\"file\"")
            let isPicture = req.body.range(of: Data([0xFF, 0xD8, 0xFF])) != nil || req.body.range(of: Data([0x89, 0x50, 0x4E, 0x47])) != nil
            guard isMultipart, hasFile, isPicture, req.query["url"] == nil else {
                return .json(["header": ["status": -4, "message": "You need an <a href=\"https://example.invalid/help\">Image</a>!"]])
            }
            seed = req.body.count
        } else if let u = req.query["url"], !u.isEmpty {
            seed = u.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        } else {
            return .json(["header": ["status": -1, "message": "Send a picture: upload a file or give ?url=."]], status: 400)
        }
        let sims = [96.4, 81.2, 64.0, 41.5, 22.0]
        let results: [[String: Any]] = sims.enumerated().map { k, sim in
            let n = (abs(seed) + k * 7) % MockCatalog.count + 1
            let item = MockCatalog.items[n - 1]
            // The last match points at a post that no longer exists (dead-link demo).
            // Odd matches point outside the demo sites, so filtering by site can be seen.
            let link = k == sims.count - 1 ? "\(origin)/a/view/999" : (k % 2 == 1 ? "https://example.org/posts/\(n)" : "\(origin)/a/view/\(n)")
            return [
                "header": ["similarity": String(format: "%.1f", sim), "thumbnail": "\(origin)/media/\(item.thumbFile)"],
                "data": ["title": "Demo post #\(n)", "urls": [link],
                         "creator": [item.tags.first { MockCatalog.colors.contains($0) } ?? "gray"],
                         "material": item.tags.first { MockCatalog.patterns.contains($0) } ?? "grid"],
            ]
        }
        return .json(["header": ["status": 0, "results_returned": results.count], "results": results])
    }
}
