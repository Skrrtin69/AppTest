import Foundation

/// Reads the first 64 KB of a video to see what's really inside, whatever its name says.
/// A real WebM only holds VP8/VP9/AV1 video; a ".webm" that starts with an MP4 header is an
/// MP4 with the wrong name, which AVPlayer can play directly.
enum MediaSniffer {
    enum Container: String { case mp4 = "MP4", matroska = "Matroska/WebM", unknown = "unknown" }

    struct Result {
        var container: Container
        /// Matroska codec ID (V_VP9, V_MPEG4/ISO/AVC…), when found.
        var videoCodec: String?
        var summary: String { "\(container.rawValue)" + (videoCodec.map { ", video \($0)" } ?? "") }
        var isH264orHEVC: Bool { videoCodec.map { $0.hasPrefix("V_MPEG4/ISO/AVC") || $0.hasPrefix("V_MPEGH/ISO/HEVC") } ?? false }
    }

    static let probeBytes = 64 * 1024
    static let codecIDs = ["V_VP9", "V_VP8", "V_AV1", "V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC", "V_MPEG4/ISO/ASP", "V_THEORA"]

    static func sniff(_ url: URL) async -> Result? {
        guard let data = await head(of: url), !data.isEmpty else { return nil }
        return classify(data)
    }

    static func classify(_ d: Data) -> Result {
        let b = [UInt8](d.prefix(probeBytes))
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) { return Result(container: .mp4) }
        guard b.count >= 4, Array(b[0..<4]) == [0x1A, 0x45, 0xDF, 0xA3] else { return Result(container: .unknown) }
        let text = String(decoding: b, as: UTF8.self)
        let codec = codecIDs.compactMap { id -> (String, String.Index)? in
            text.range(of: id).map { (id, $0.lowerBound) }
        }.min { $0.1 < $1.1 }?.0
        return Result(container: .matroska, videoCodec: codec)
    }

    /// The first bytes of a local file, or of a remote one (a Range request with the site's
    /// headers; reading stops at 64 KB even if the server sends the whole file).
    private static func head(of url: URL) async -> Data? {
        if url.isFileURL {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            return try? h.read(upToCount: probeBytes)
        }
        let client = NetworkClient.forMedia(url)
        var r = URLRequest(url: url)
        r.timeoutInterval = 8
        r.setValue("bytes=0-\(probeBytes - 1)", forHTTPHeaderField: "Range")
        for (k, v) in client.mediaHeaders { r.setValue(v, forHTTPHeaderField: k) }
        do {
            let (bytes, resp) = try await client.session.bytes(for: r)
            defer { bytes.task.cancel() }
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            var out = Data()
            out.reserveCapacity(probeBytes)
            for try await byte in bytes {
                out.append(byte)
                if out.count >= probeBytes { break }
            }
            return out
        } catch {
            return nil
        }
    }

    /// AVPlayer goes by the name and type, so an MP4 called .webm is played through the
    /// local proxy under a .mp4 name with an MP4 type.
    static func mp4ProxyURL(_ url: URL, siteID: String?) -> URL {
        let server = MockServer.shared.baseURL.absoluteString
        let site = siteID.map { "&site=" + encode($0) } ?? ""
        return URL(string: "\(server)/proxy/video.mp4?url=\(encode(url.absoluteString))&type=video%2Fmp4\(site)") ?? url
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/:")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Local MP4 files named .webm: a link with an .mp4 name in the temporary folder.
    static func mp4FileAlias(_ url: URL) -> URL? {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("sniffed-\(abs(url.path.hashValue)).mp4")
        try? FileManager.default.removeItem(at: link)
        return (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)) != nil ? link : nil
    }
}
