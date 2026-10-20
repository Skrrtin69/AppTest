import Foundation

/// Demo reverse image search: accepts an uploaded picture (or a ?url=) and answers with a few
/// made-up matches that point at demo Site A posts, so tapping one opens it in the app.
enum MockReverse {
    static func respond(_ req: HTTPRequest, origin: String) -> HTTPResponse {
        guard req.path == "/rs/search" else { return .json(["error": "not found"], status: 404) }
        if req.query["api_key"] == "bad" {
            return .json(["header": ["status": -1, "message": "Invalid API key."]], status: 403)
        }
        // Something to search with: an uploaded file or an address.
        let seed: Int
        if !req.body.isEmpty {
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
            return [
                "header": ["similarity": String(format: "%.1f", sim), "thumbnail": "\(origin)/media/\(item.thumbFile)"],
                "data": ["title": "Demo post #\(n)", "urls": ["\(origin)/a/view/\(n)"]],
            ]
        }
        return .json(["header": ["status": 0, "results_returned": results.count], "results": results])
    }
}
