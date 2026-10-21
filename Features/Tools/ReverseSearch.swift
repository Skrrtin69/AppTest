import SwiftUI
import UIKit
import AVFoundation

/// A reverse image search service the user describes in JSON, like an adapter: where to send
/// the picture, and where the matches are in the answer. No service is built in; the demo
/// engine talks to the app's own demo server.
struct ReverseEngine: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var enabled: Bool = true
    /// "url" sends the picture's address ({url} in requestURL); "upload" posts the file itself.
    var mode: String = "url"
    /// Request address. Placeholders: {url} (the picture's address, encoded) and {api_key}.
    var requestURL: String
    /// Form field name for the file in "upload" mode.
    var uploadField: String? = "file"
    /// Where the list of matches is in the answer.
    var resultsPath: String
    /// Inside one match:
    var similarityPath: String?
    var thumbnailPath: String?
    var sourceURLPath: String?
    var titlePath: String?
    /// Matches below this similarity (0–100) are hidden.
    var minSimilarity: Double? = nil
    /// Optional page where the user gets an API key.
    var apiKeyPageURL: String? = nil

    static func demo(port: UInt16) -> ReverseEngine {
        ReverseEngine(id: "demo-reverse", name: "Demo Reverse Search", mode: "upload",
                      requestURL: "http://127.0.0.1:\(port)/rs/search?api_key={api_key}",
                      uploadField: "file", resultsPath: "results",
                      similarityPath: "header.similarity", thumbnailPath: "header.thumbnail",
                      sourceURLPath: "data.urls[0]", titlePath: "data.title", minSimilarity: 0)
    }
}

/// One match from a reverse search.
struct ReverseMatch: Identifiable {
    let id = UUID()
    let similarity: Double?
    let thumbnail: URL?
    let source: URL?
    let title: String?
    /// Artist names and the series/work, when the engine's answer has them.
    var creators: [String] = []
    var material: String? = nil
}

/// Engines are kept in Documents/reverse_search.json, so they can be edited like adapters.json.
/// API keys are not in the file; they're in the Keychain.
@MainActor
final class ReverseEngineStore: ObservableObject {
    static let shared = ReverseEngineStore()
    @Published private(set) var engines: [ReverseEngine] = []

    var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("reverse_search.json")
    }

    private init() { load() }

    func load() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([ReverseEngine].self, from: data) {
            engines = list
        } else {
            engines = [.demo(port: MockServer.defaultPort)]
            save()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(engines) { try? data.write(to: file, options: .atomic) }
    }

    func upsert(_ e: ReverseEngine) {
        if let i = engines.firstIndex(where: { $0.id == e.id }) { engines[i] = e } else { engines.append(e) }
        save()
    }

    func delete(_ id: String) {
        engines.removeAll { $0.id == id }
        try? Keychain.delete(service: "reverse-search", account: id)
        save()
    }

    /// Replaces every engine from JSON text (the "Edit as JSON" screen). Throws a readable error.
    func replace(json: String) throws {
        let list = try JSONDecoder().decode([ReverseEngine].self, from: Data(json.utf8))
        let ids = list.map(\.id)
        guard Set(ids).count == ids.count else { throw AppError.message("Two engines have the same id.") }
        engines = list
        save()
    }

    var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(engines)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    func apiKey(for id: String) -> String {
        (try? Keychain.get(service: "reverse-search", account: id)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func setAPIKey(_ key: String, for id: String) {
        if key.isEmpty { try? Keychain.delete(service: "reverse-search", account: id) }
        else { try? Keychain.set(Data(key.utf8), service: "reverse-search", account: id) }
    }
}

enum ReverseSearch {
    /// Runs one engine for a post's picture.
    static func run(_ engine: ReverseEngine, post: Post) async throws -> [ReverseMatch] {
        let key = await ReverseEngineStore.shared.apiKey(for: engine.id)
        // The demo engine follows the demo server if it had to move to another port.
        let template = engine.requestURL.replacingOccurrences(of: "127.0.0.1:\(MockServer.defaultPort)", with: "127.0.0.1:\(MockServer.shared.port)")
        let picture = post.mediaType == .video ? post.thumbnailURL : (post.sampleURL ?? post.mediaURL)
        let pictureIsLocal = ["127.0.0.1", "localhost"].contains(picture.host ?? "") || picture.isFileURL
        // Videos and animations are never sent as they are: a still frame is uploaded instead.
        let needsStill = post.mediaType != .image || isArchive(post.mediaURL)
        let upload = engine.mode == "upload" || pictureIsLocal || needsStill
        let url = try requestURL(template, key: key, picture: picture, upload: upload)
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if upload {
            let field = engine.uploadField?.nonEmpty ?? "file"
            let jpeg = try await stillJPEG(for: post)
            let boundary = "MediaDeck-\(UUID().uuidString)"
            var body = Data()
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"image.jpg\"\r\n".utf8))
            body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
            body.append(jpeg)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
            req.httpBody = body
            DebugLog.log("Reverse", "upload \(jpeg.count) B as \(field) to \(DebugLog.redact(url))")
        }
        return try await perform(engine, req)
    }

    /// Runs one engine for a picture that isn't online (e.g. from the Photo Library): it's
    /// always uploaded, whatever the engine's mode; any {url} parameter is left out.
    static func run(_ engine: ReverseEngine, jpeg: Data) async throws -> [ReverseMatch] {
        let key = await ReverseEngineStore.shared.apiKey(for: engine.id)
        let template = engine.requestURL.replacingOccurrences(of: "127.0.0.1:\(MockServer.defaultPort)", with: "127.0.0.1:\(MockServer.shared.port)")
        let url = try requestURL(template, key: key, picture: URL(string: "about:blank")!, upload: true)
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let field = engine.uploadField?.nonEmpty ?? "file"
        let boundary = "MediaDeck-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"image.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        req.httpBody = body
        DebugLog.log("Reverse", "upload \(jpeg.count) B (photo) as \(field) to \(DebugLog.redact(url))")
        return try await perform(engine, req)
    }

    /// Sends the request and reads the matches out of the engine's answer.
    private static func perform(_ engine: ReverseEngine, _ request: URLRequest) async throws -> [ReverseMatch] {
        guard let url = request.url else { throw AppError.message("The engine's request address isn't valid.") }
        var req = request
        // Engines behind Cloudflare refuse requests that don't look like a browser's.
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await uploadSession.data(for: req)
        let http = response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type")
        if let h = http, !(200..<300).contains(h.statusCode) {
            // What the engine actually sent: a Cloudflare page, a key error, or something else.
            let key = await ReverseEngineStore.shared.apiKey(for: engine.id)
            var body = String(decoding: data.prefix(2000), as: UTF8.self)
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !key.isEmpty { body = body.replacingOccurrences(of: key, with: "•••") }
            let cf = h.value(forHTTPHeaderField: "cf-ray") != nil || (h.value(forHTTPHeaderField: "Server") ?? "").lowercased().contains("cloudflare")
            DebugLog.log("Reverse", "\(engine.name): HTTP \(h.statusCode) · \(type ?? "no type") · cloudflare: \(cf ? "yes" : "no") · cf-mitigated: \(h.value(forHTTPHeaderField: "cf-mitigated") ?? "–") · \(data.count) B: \(body.prefix(500))")
        }
        let parsed = try? JSONSerialization.jsonObject(with: data)
        // Engines report failures as a negative header.status (often with HTTP 200) or as an
        // HTTP error; either way show their own message, cleaned of HTML.
        if let msg = engineError(parsed) {
            throw AppError.message("\(engine.name): \(msg)")
        }
        guard let status = http?.statusCode, (200..<300).contains(status) else {
            let code = http?.statusCode ?? 0
            throw AppError.http(status: code, url: url, message: clean(ErrorParser.describe(status: code, data: data, contentType: type)))
        }
        guard let json = parsed else {
            throw AppError.message(ErrorParser.message(from: data, contentType: type).map(clean) ?? "The engine didn't answer with JSON.")
        }
        guard let list = DottedPath.evaluate(engine.resultsPath, in: json) as? [Any] else {
            throw AppError.message(ErrorParser.message(from: data, contentType: type).map(clean)
                                   ?? "No list of matches at '\(engine.resultsPath)' in the engine's answer.")
        }
        let minimum = engine.minSimilarity ?? 0
        return list.compactMap { node -> ReverseMatch? in
            // Paths the user filled in win; empty ones are found by looking through the match
            // for keys named like similarity / thumbnail / url / title.
            let simText = engine.similarityPath?.nonEmpty.flatMap { DottedPath.string($0, in: node) } ?? MatchGuess.similarity(node)
            let sim = simText.flatMap { Double($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
            if let s = sim, s < minimum { return nil }
            func link(_ p: String?) -> URL? {
                p?.nonEmpty.flatMap { DottedPath.string($0, in: node) }.flatMap { URL(string: $0) }.flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
            }
            let thumb = link(engine.thumbnailPath) ?? MatchGuess.thumbnail(node)
            let source = link(engine.sourceURLPath) ?? MatchGuess.source(node, excluding: thumb)
            let title = engine.titlePath?.nonEmpty.flatMap { DottedPath.string($0, in: node) } ?? MatchGuess.title(node)
            return ReverseMatch(similarity: sim, thumbnail: thumb, source: source, title: title,
                                creators: MatchGuess.creators(node), material: MatchGuess.material(node))
        }
        .sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
    }
}

extension ReverseSearch {
    static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "zip" || AdapterRegistry.shared.configs.contains { $0.zipExtensions.map { $0.lowercased() }.contains(ext) }
    }

    /// The request address. {api_key} is filled in, and when the picture is uploaded any
    /// query item that carries {url} is dropped: an address parameter would make the engine
    /// fetch that address instead of reading the uploaded file. Everything else in the
    /// template (e.g. output_type=2&api_key=…) stays in the query.
    static func requestURL(_ template: String, key: String, picture: URL, upload: Bool) throws -> URL {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var text = template.replacingOccurrences(of: "{api_key}", with: encodedKey)
        if upload, var c = URLComponents(string: text.replacingOccurrences(of: "{url}", with: "MDURLPLACEHOLDER")) {
            c.queryItems = c.queryItems?.filter { !($0.value ?? "").contains("MDURLPLACEHOLDER") }
            if c.queryItems?.isEmpty == true { c.queryItems = nil }
            text = c.string ?? text
        } else {
            let encodedPicture = picture.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            text = text.replacingOccurrences(of: "{url}", with: encodedPicture)
        }
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else {
            throw AppError.message("The engine's request address isn't a valid http(s) address.")
        }
        return url
    }

    /// A JPEG of a picture for uploading: at most 2000 px on the long side, transparency
    /// flattened onto white.
    static func uploadJPEG(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 2000
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.9)
    }

    /// A still JPEG of the post (max 2000 px): the picture itself, the first frame of a GIF,
    /// WebP/APNG or ZIP animation, or the first frame of a video (its thumbnail if the frame
    /// can't be read, e.g. WebM).
    static func stillJPEG(for post: Post) async throws -> Data {
        let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
        var still: UIImage?
        if post.mediaType == .video {
            still = await firstVideoFrame(post.mediaURL)
            if still == nil {
                still = try? await ImagePipeline.shared.image(for: post.thumbnailURL, maxPixel: 2000, animate: false, client: client)
            }
        } else {
            // animate: false gives the first frame of any animation.
            let source = isArchive(post.mediaURL) ? post.mediaURL : (post.sampleURL ?? post.mediaURL)
            still = try await ImagePipeline.shared.image(for: source, maxPixel: 2000, animate: false, client: client)
        }
        guard let img = still, let jpeg = flattened(img).jpegData(compressionQuality: 0.9) else {
            throw AppError.message("Couldn't make a still picture of this post to search with.")
        }
        return jpeg
    }

    /// The first frame of a video, read with AVAssetImageGenerator (with the site's headers).
    static func firstVideoFrame(_ url: URL) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset.withSiteHeaders(url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 2000, height: 2000)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        return await withCheckedContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cg, _, _, error in
                if let e = error { DebugLog.log("Reverse", "first frame: \(e.localizedDescription)") }
                cont.resume(returning: cg.map { UIImage(cgImage: $0) })
            }
        }
    }

    /// JPEG has no transparency: draw on white so transparent areas don't turn black.
    static func flattened(_ img: UIImage) -> UIImage {
        let size = CGSize(width: img.size.width * img.scale, height: img.size.height * img.scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// A negative header.status (or status) in the answer → the engine's message, cleaned.
    static func engineError(_ json: Any?) -> String? {
        guard let root = json as? [String: Any] else { return nil }
        let header = root["header"] as? [String: Any] ?? root
        let raw = header["status"] ?? root["status"]
        let status = (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap { Int($0) }
        guard let s = status, s < 0 else { return nil }
        let msg = (header["message"] ?? root["message"] ?? root["error"]) as? String
        return clean(msg ?? "The engine reported an error (status \(s)).")
    }

    /// Plain text: literal \uXXXX escapes decoded, HTML tags removed, entities decoded,
    /// spaces tidied.
    static func clean(_ text: String) -> String {
        var s = text
        if let r = try? NSRegularExpression(pattern: "\\\\u([0-9a-fA-F]{4})") {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in r.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                if let v = UInt32(ns.substring(with: m.range(at: 1)), radix: 16), let u = Unicode.Scalar(v) {
                    out.unicodeScalars.append(u)
                }
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, c) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps the method and uploaded body if the engine redirects (URLSession would otherwise
    /// turn the POST into an empty GET, and the engine would see no picture).
    /// Safari on this iPhone's iOS version (e.g. "… iPhone OS 16_2 … Version/16.2 …").
    static var browserUserAgent: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let underscored = "\(v.majorVersion)_\(v.minorVersion)"
        let dotted = "\(v.majorVersion).\(v.minorVersion)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(dotted) Mobile/15E148 Safari/604.1"
    }

    static let uploadSession = URLSession(configuration: .default, delegate: RedirectKeeper(), delegateQueue: nil)

    final class RedirectKeeper: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let original = task.originalRequest, original.httpMethod == "POST", let to = request.url else {
                completionHandler(request)
                return
            }
            var r = URLRequest(url: to, timeoutInterval: original.timeoutInterval)
            r.httpMethod = "POST"
            r.httpBody = original.httpBody
            r.allHTTPHeaderFields = original.allHTTPHeaderFields
            completionHandler(r)
        }
    }
}

/// Finds the usual pieces of a match when the engine's paths are left empty.
enum MatchGuess {
    /// Every (key, value) in the match, a few levels deep; arrays keep their parent key.
    static func pairs(_ node: Any, key: String = "", depth: Int = 0) -> [(String, Any)] {
        guard depth < 4 else { return [] }
        if let d = node as? [String: Any] {
            return d.sorted { $0.key < $1.key }.flatMap { k, v -> [(String, Any)] in
                (v is [String: Any] || v is [Any]) ? pairs(v, key: k, depth: depth + 1) : [(k.lowercased(), v)]
            }
        }
        if let a = node as? [Any] { return a.flatMap { pairs($0, key: key, depth: depth + 1) }.map { ($0.0.isEmpty ? key.lowercased() : $0.0, $0.1) } + a.compactMap { ($0 is String) ? (key.lowercased(), $0) : nil } }
        return []
    }

    static func text(_ v: Any) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func similarity(_ node: Any) -> String? {
        pairs(node).first { $0.0.contains("similarity") || $0.0 == "score" }.flatMap { text($0.1) }
    }

    static func httpURL(_ v: Any) -> URL? {
        guard let s = v as? String, let u = URL(string: s), u.scheme?.hasPrefix("http") == true else { return nil }
        return u
    }

    static func thumbnail(_ node: Any) -> URL? {
        pairs(node).first { ($0.0.contains("thumb") || $0.0.contains("preview")) && httpURL($0.1) != nil }.flatMap { httpURL($0.1) }
    }

    /// The first web link under a key like url/urls/source/link that isn't the thumbnail.
    static func source(_ node: Any, excluding thumb: URL?) -> URL? {
        let all = pairs(node).filter { httpURL($0.1) != nil && httpURL($0.1) != thumb }
        let named = all.first { k, _ in ["url", "source", "link", "page"].contains { k.contains($0) } && !k.contains("thumb") }
        return (named ?? all.first(where: { !$0.0.contains("thumb") })).flatMap { httpURL($0.1) }
    }

    /// data.creator (text or list), else member/author/artist names.
    static func creators(_ node: Any) -> [String] {
        let p = pairs(node)
        var out: [String] = []
        for k in ["creator", "creators", "member_name", "author_name", "author", "artist"] {
            for (key, v) in p where key == k {
                if let s = text(v)?.trimmingCharacters(in: .whitespaces), !s.isEmpty, httpURL(s) == nil,
                   !out.contains(where: { $0.lowercased() == s.lowercased() }) { out.append(s) }
            }
            if !out.isEmpty { break }
        }
        return Array(out.prefix(4))
    }

    /// data.material: the series or work the picture is from.
    static func material(_ node: Any) -> String? {
        pairs(node).first { $0.0 == "material" }.flatMap { text($0.1) }?.trimmingCharacters(in: .whitespaces).nonEmpty
    }

    static func title(_ node: Any) -> String? {
        let p = pairs(node)
        for k in ["title", "material", "source", "creator", "author", "member_name", "artist", "name"] {
            if let t = p.first(where: { $0.0 == k || $0.0.hasSuffix("_" + k) }).flatMap({ text($0.1) }),
               !t.isEmpty, httpURL(t) == nil { return t }
        }
        return nil
    }
}

/// Picks an engine (if there are several), runs it and lists the matches.
struct ReverseSearchSheet: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ReverseEngineStore.shared
    @State private var engine: ReverseEngine?
    @State private var matches: [ReverseMatch]?
    @State private var error: String?
    @State private var running = false
    @State private var viewer: ViewerRequest?
    @State private var opening = false
    /// Hide matches below this similarity.
    @State private var minSimilarity = 0.0

    var enabled: [ReverseEngine] { store.engines.filter(\.enabled) }

    var body: some View {
        NavigationView {
            List {
                if enabled.isEmpty {
                    Text("No reverse search engines are switched on. Add one in Settings › Reverse Search.")
                        .foregroundColor(.secondary)
                } else if enabled.count > 1 {
                    Section("Engine") {
                        ForEach(enabled) { e in
                            Button { Task { await run(e) } } label: {
                                HStack { Text(e.name).foregroundColor(.primary); Spacer(); if engine?.id == e.id { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                }
                if running {
                    HStack { ProgressView(); Text("Searching \(engine?.name ?? "")…").foregroundColor(.secondary) }
                }
                if let e = error {
                    Section { Label(e, systemImage: "exclamationmark.triangle").foregroundColor(.red) }
                }
                if let m = matches { matchSection(m) }
            }
            .navigationTitle("Reverse Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if enabled.count == 1, matches == nil { await run(enabled[0]) } }
            .overlay { if opening { ProgressView().padding(24).background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial)) } }
            .fullScreenCover(item: $viewer) { ViewerView(posts: $0.posts, startIndex: $0.index) }
        }
    }

    func matchSection(_ all: [ReverseMatch]) -> some View {
        let m = all.filter { ($0.similarity ?? 100) >= minSimilarity }
        return Section {
            if !all.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("At least \(Int(minSimilarity))% similar · showing \(m.count) of \(all.count)").font(.caption).foregroundColor(.secondary)
                    Slider(value: $minSimilarity, in: 0...100, step: 5)
                        .accessibilityLabel("Minimum similarity")
                        .accessibilityIdentifier("similaritySlider")
                }
            }
            if m.isEmpty { Text(all.isEmpty ? "No matches." : "No matches this similar.").foregroundColor(.secondary) }
            ForEach(m) { match in
                MatchRow(match: match, onOpen: { picked in Task { await openMatch(picked) } })
            }
        } header: {
            Text("\(m.count) match\(m.count == 1 ? "" : "es")")
        } footer: {
            Text("Tap a match to view it: a match on one of your sites opens that post; others open their preview picture (⋯ › Open Source for the page). Hold a match for its page and link.")
        }
    }

    func openMatch(_ m: ReverseMatch) async {
        opening = true
        defer { opening = false }
        if let p = await MatchOpener.post(for: m) { viewer = ViewerRequest(posts: [p], index: 0) }
        else if let s = m.source { await UIApplication.shared.open(s) }
    }

    func run(_ e: ReverseEngine) async {
        engine = e; running = true; error = nil; matches = nil
        defer { running = false }
        do { matches = try await ReverseSearch.run(e, post: post) }
        catch { self.error = error.localizedDescription }
    }
}

/// What tapping a match shows in the viewer.
@MainActor
enum MatchOpener {
    /// The real post when the match links to a post on one of your sites; otherwise the
    /// match's preview picture (which often survives when the page itself is gone).
    static let deadNotice = "Source deleted. Showing cached preview."

    static func post(for m: ReverseMatch) async -> Post? {
        var dead = false
        if let s = m.source, let site = LinkRouter.site(for: s), let id = LinkRouter.target(of: s).postID,
           let adapter = AdapterRegistry.shared.adapter(for: site.id) {
            DebugLog.log("Reverse", "match \(s.absoluteString) → \(site.id) post \(id)")
            do { return try await adapter.fetchPost(id: id) }
            catch {
                DebugLog.log("Reverse", "open \(site.id):\(id) failed: \(error.localizedDescription)")
                dead = true
            }
        } else if let s = m.source {
            dead = await isGone(s)
            DebugLog.log("Reverse", "match \(s.absoluteString): not on your sites, page \(dead ? "gone" : "still there")")
        }
        guard let t = m.thumbnail else { return nil }
        var meta: [String: String] = [:]
        if dead { meta["notice"] = deadNotice }
        if let sim = m.similarity { meta["similarity"] = String(format: "%.1f%%", sim) }
        if let title = m.title?.nonEmpty { meta["title"] = title }
        return Post(id: "match-\(abs(t.absoluteString.hashValue) % 1_000_000)", siteID: "", thumbnailURL: t, mediaURL: t,
                    mediaType: .image, tags: [], sourceURL: m.source, metadata: meta)
    }

    /// The source page answers 404/410, or not at all within a few seconds.
    static func isGone(_ url: URL) async -> Bool {
        var r = URLRequest(url: url, timeoutInterval: 6)
        r.httpMethod = "HEAD"
        do {
            let (_, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            return code == 404 || code == 410
        } catch let e as URLError where [.timedOut, .cannotFindHost, .dnsLookupFailed].contains(e.code) {
            return true
        } catch {
            return false
        }
    }

    /// Saves the match to the Library: the full post when it's on one of your sites,
    /// otherwise the preview picture (all the engine has).
    static func save(_ m: ReverseMatch) async {
        if let s = m.source, let site = LinkRouter.site(for: s), let id = LinkRouter.target(of: s).postID,
           let a = AdapterRegistry.shared.adapter(for: site.id), let p = try? await a.fetchPost(id: id) {
            await DownloadManager.shared.enqueue([p])
            return
        }
        guard let t = m.thumbnail else { ToastCenter.shared.show("This match has no picture to save.", style: .error); return }
        let p = Post(id: "match-\(abs(t.absoluteString.hashValue) % 1_000_000)", siteID: "", thumbnailURL: t, mediaURL: t,
                     mediaType: .image, tags: m.creators.map { $0.lowercased() }, sourceURL: m.source, metadata: [:])
        await DownloadManager.shared.enqueue([p])
        ToastCenter.shared.show("Only the preview picture is available for this match; it was saved.")
    }

    /// Searches an artist or series name on the site open in Browse (spaces become the
    /// site's tag separator).
    static func searchNatively(_ name: String) {
        let site = BrowseModel.shared.current?.siteID ?? AdapterRegistry.shared.enabledConfigs.first?.id ?? ""
        Presenter.dismissAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            AppRouter.shared.search(tag: TagQuery.display(name.lowercased()), siteID: site)
        }
    }
}

struct MatchRow: View {
    let match: ReverseMatch
    var onOpen: (ReverseMatch) -> Void = { _ in }
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Group {
                    if let t = match.thumbnail {
                        CachedAsyncImage(url: t, maxPixel: 200)
                    } else {
                        Color.gray.opacity(0.2).overlay(Image(systemName: "photo").foregroundColor(.secondary))
                    }
                }
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    if let s = match.similarity {
                        Text(String(format: "%.1f%% similar", s)).font(.headline)
                            .foregroundColor(s >= 85 ? .green : (s >= 60 ? .orange : .secondary))
                    }
                    if let t = match.title?.nonEmpty { Text(t).font(.subheadline).foregroundColor(.primary).lineLimit(2) }
                    Text(match.source?.host ?? "No link").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                // Save the best version to the Library.
                Button {
                    Task { saving = true; await MatchOpener.save(match); saving = false }
                } label: {
                    if saving { ProgressView() } else { Image(systemName: "arrow.down.circle").font(.title3) }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Save to Library")
                .accessibilityIdentifier("saveMatch")
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen(match) }
            if !match.creators.isEmpty || match.material != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(match.creators, id: \.self) { c in chip(c, icon: "person") }
                        if let m = match.material { chip(m, icon: "books.vertical") }
                    }
                }
            }
        }
        .contextMenu {
            if let s = match.source {
                Button { if !LinkRouter.open(s) { UIApplication.shared.open(s) } } label: { Label("Open Page", systemImage: "arrow.up.right.square") }
                Button { UIPasteboard.general.string = s.absoluteString; ToastCenter.shared.show("Link copied") } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                Button { UIApplication.shared.open(s) } label: { Label("Open in Browser", systemImage: "safari") }
            }
        }
    }

    /// Tapping an artist or series searches it on the site open in Browse.
    func chip(_ text: String, icon: String) -> some View {
        Button { MatchOpener.searchNatively(text) } label: {
            Label(text, systemImage: icon).font(.caption).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("matchChip")
    }
}

/// Settings › Reverse Search: engines, their API keys, and the JSON behind them.
struct ReverseEnginesView: View {
    @ObservedObject private var store = ReverseEngineStore.shared
    @State private var editing: ReverseEngine?
    @State private var showJSON = false

    var body: some View {
        List {
            Section {
                ForEach(store.engines) { e in
                    Button { editing = e } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(e.name).foregroundColor(.primary)
                                Text(e.mode == "upload" ? "Uploads the picture" : "Sends the picture's address").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if !e.enabled { Text("Off").foregroundColor(.secondary) }
                        }
                    }
                }
                .onDelete { idx in idx.map { store.engines[$0].id }.forEach(store.delete) }
                Button { editing = ReverseEngine(id: "engine-\(Int(Date().timeIntervalSince1970))", name: "New Engine", requestURL: "https://", resultsPath: "results") } label: {
                    Label("Add Engine", systemImage: "plus")
                }
            } footer: {
                Text("A reverse search engine finds where a picture comes from. Like a site adapter, you describe its address and where the matches are in its JSON answer. Use it from the viewer's ⋯ menu.")
            }
            Section {
                Button { showJSON = true } label: { Label("Edit all as JSON", systemImage: "curlybraces") }
                Button {
                    store.upsert(.demo(port: MockServer.defaultPort))
                    ToastCenter.shared.show("Demo engine restored", style: .success)
                } label: { Label("Restore the demo engine", systemImage: "arrow.counterclockwise") }
            } footer: {
                Text("The engines are also in Files › On My iPhone › MediaDeck › reverse_search.json. API keys are kept in the Keychain, not in that file.")
            }
        }
        .navigationTitle("Reverse Search")
        .sheet(item: $editing) { ReverseEngineEditor(engine: $0) }
        .sheet(isPresented: $showJSON) { ReverseJSONEditor() }
    }
}

struct ReverseEngineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var engine: ReverseEngine
    @State private var apiKey = ""
    @State private var keyPage: AccountView.WebPageRequest?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Name", text: $engine.name)
                    Toggle("Switched on", isOn: $engine.enabled)
                    Picker("Send", selection: $engine.mode) {
                        Text("The picture's address").tag("url")
                        Text("The picture file (upload)").tag("upload")
                    }
                }
                Section {
                    field("Request address", $engine.requestURL, "https://…?url={url}&api_key={api_key}")
                    field("Upload field name", opt(\.uploadField), "file")
                } header: { Text("Request") } footer: {
                    Text("{url} becomes the picture's address and {api_key} your key. Pictures that are only on this phone (or the demo server) are always uploaded.")
                }
                Section {
                    SecureField("API key (optional)", text: $apiKey).textInputAutocapitalization(.never).disableAutocorrection(true)
                    field("API key page", opt(\.apiKeyPageURL), "https://…")
                    if let s = engine.apiKeyPageURL?.nonEmpty, let u = URL(string: s) {
                        Button("Open my API key page") { keyPage = AccountView.WebPageRequest(url: u) }
                    }
                } header: { Text("Key") }
                Section {
                    field("Matches list", $engine.resultsPath, "results")
                    field("Similarity", opt(\.similarityPath), "header.similarity")
                    field("Thumbnail", opt(\.thumbnailPath), "header.thumbnail")
                    field("Source link", opt(\.sourceURLPath), "data.urls[0]")
                    field("Title", opt(\.titlePath), "data.title")
                    HStack {
                        Text("Hide matches below")
                        Spacer()
                        TextField("0", value: Binding(get: { engine.minSimilarity ?? 0 }, set: { engine.minSimilarity = $0 }), format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
                        Text("%")
                    }
                } header: { Text("Answer") } footer: {
                    Text("Paths work like in adapters: dots between keys, [0] for the first item of a list. The match paths are inside one match.")
                }
            }
            .keyboardDoneButton()
            .navigationTitle(engine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        ReverseEngineStore.shared.upsert(engine)
                        ReverseEngineStore.shared.setAPIKey(apiKey, for: engine.id)
                        dismiss()
                    }
                    .disabled(engine.name.isEmpty || engine.resultsPath.isEmpty)
                }
            }
            .onAppear { apiKey = ReverseEngineStore.shared.apiKey(for: engine.id) }
            .sheet(item: $keyPage) { ThemedWebPage(url: $0.url, prefillUsername: "") }
        }
    }

    func opt(_ kp: WritableKeyPath<ReverseEngine, String?>) -> Binding<String> {
        Binding(get: { engine[keyPath: kp] ?? "" }, set: { engine[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    func field(_ title: String, _ b: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: b)
                .font(.body.monospaced()).textInputAutocapitalization(.never).disableAutocorrection(true)
        }
    }
}

struct ReverseJSONEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ReverseEngineStore.shared.json
    @State private var error: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let e = error {
                    Text(e).font(.footnote).foregroundColor(.red).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .padding(.horizontal, 6)
            }
            .navigationTitle("Engines JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try ReverseEngineStore.shared.replace(json: text); dismiss() }
                        catch let e as DecodingError { error = "Not saved: \(Self.describe(e))" }
                        catch { self.error = "Not saved: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, _): return "a required field \"\(k.stringValue)\" is missing."
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return "a field has the wrong kind of value (\(c.codingPath.map(\.stringValue).joined(separator: ".")))."
        case .dataCorrupted: return "this isn't valid JSON (check commas and quotes)."
        @unknown default: return "the JSON couldn't be read."
        }
    }
}
