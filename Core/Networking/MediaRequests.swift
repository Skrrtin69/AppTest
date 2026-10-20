import Foundation

/// The single path for fetching thumbnails and media. Every request carries the adapter's
/// headers (plus a default Referer, which many sites require before they serve images),
/// public http:// addresses are upgraded to https with an http fallback, and answers that
/// aren't media (HTML pages, empty files) become clear errors instead of "damaged image".
extension NetworkClient {
    /// The adapter's base address, sent as Referer when the adapter sets none.
    var refererDefault: String? {
        siteID.flatMap { AdapterRegistry.shared.config(for: $0) }?.baseURL.absoluteString
    }

    /// Headers for a media request: the adapter's own, User-Agent, and a default Referer.
    var mediaHeaders: [String: String] {
        var h = config.headers
        h["User-Agent"] = config.userAgent?.nonEmpty ?? Self.defaultUserAgent
        if !h.keys.contains(where: { $0.lowercased() == "referer" }), let r = refererDefault { h["Referer"] = r }
        return h
    }

    func mediaData(for original: URL) async throws -> Data {
        let url = MediaURL.upgraded(original)
        do {
            return try await fetchMedia(url)
        } catch let e as URLError where url != original && MediaURL.isHTTPSFailure(e) {
            // The site has no working https: use the address exactly as the API gave it.
            return try await fetchMedia(original)
        }
    }

    private func fetchMedia(_ url: URL) async throws -> Data {
        let (data, response) = try await data(for: url, headers: mediaHeaders, rateLimited: false)
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("text/html") {
            throw AppError.message("Site blocked request or requires login. (It answered with a web page instead of the picture.)")
        }
        if data.isEmpty {
            throw AppError.message("File not found on server (it sent an empty file).")
        }
        return data
    }

    /// Picks the client of the adapter whose addresses share this media URL's host.
    static func forMedia(_ url: URL) -> NetworkClient {
        guard let host = url.host?.lowercased() else { return .shared }
        let registry = AdapterRegistry.shared
        let match = registry.configs.first { c in
            let base = c.baseURL.host?.lowercased(), media = c.mediaBaseURL.host?.lowercased()
            guard base == host || media == host else { return false }
            // Several adapters can share a host (e.g. the demo server): prefer the one whose
            // address path is a prefix of the media URL.
            return url.absoluteString.hasPrefix(c.mediaBaseURL.absoluteString) || url.absoluteString.hasPrefix(c.baseURL.absoluteString)
        } ?? registry.configs.first { c in c.baseURL.host?.lowercased() == host || c.mediaBaseURL.host?.lowercased() == host }
        return match.flatMap { registry.adapter(for: $0.id)?.client } ?? .shared
    }
}

enum MediaURL {
    /// Local and private-network hosts are never upgraded (they rarely have certificates).
    static func isLocal(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return true }
        if h == "localhost" || h.hasSuffix(".local") || h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") { return true }
        if h.hasPrefix("172."), let second = Int(h.split(separator: ".").dropFirst().first ?? ""), (16...31).contains(second) { return true }
        return false
    }

    /// `//host/x` → `https://host/x`; `http://public-host/x` → `https://public-host/x`.
    static func upgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", !isLocal(url.host),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = "https"
        return c.url ?? url
    }

    static func isHTTPSFailure(_ e: URLError) -> Bool {
        [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
         .serverCertificateHasUnknownRoot, .cannotConnectToHost, .clientCertificateRejected].contains(e.code)
    }
}
