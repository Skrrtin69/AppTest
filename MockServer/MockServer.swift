import Foundation
import Network

/// Tiny HTTP/1.1 server on 127.0.0.1 that serves the two demo "sites" and their media,
/// so the app works on first launch with zero outside network calls.
/// One request per connection (`Connection: close`); supports GET/HEAD and byte ranges
/// (AVPlayer requires ranges for video).
final class MockServer {
    static let defaultPort: UInt16 = 8765
    static let shared = MockServer()

    /// The port actually bound (may differ from `defaultPort` if it was taken).
    private(set) var port: UInt16 = defaultPort
    private var listener: NWListener?
    private let listenQueue = DispatchQueue(label: "mockserver.listen")
    private let workQueue = DispatchQueue(label: "mockserver.work", qos: .userInitiated, attributes: .concurrent)

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var isRunning: Bool { listener?.state == .ready }

    /// Starts (or restarts) the listener. Returns the bound port, or nil if every port failed.
    @discardableResult
    func start() async -> UInt16? {
        if isRunning { return port }
        listener?.cancel()
        listener = nil
        // Prefer the port we had before (so already-built URLs stay valid), then scan.
        let candidates = [port] + Array(Self.defaultPort...(Self.defaultPort + 20)).filter { $0 != port }
        for p in candidates {
            if let l = await listen(on: p) {
                listener = l
                port = p
                NSLog("[MockServer] listening on 127.0.0.1:%d", Int(p))
                return p
            }
        }
        NSLog("[MockServer] could not bind any port")
        return nil
    }

    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func run(_ f: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            if !done { done = true; f() }
        }
    }

    private func listen(on p: UInt16) async -> NWListener? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p)!)
        guard let l = try? NWListener(using: params) else { return nil }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        let ok: Bool = await withCheckedContinuation { cont in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { cont.resume(returning: true) }
                case .failed, .waiting, .cancelled:
                    once.run { cont.resume(returning: false) }
                default:
                    break
                }
            }
            l.start(queue: listenQueue)
        }
        if ok {
            // Keep watching for failures after startup (e.g. after the app was suspended).
            l.stateUpdateHandler = { state in
                if case .failed(let e) = state { NSLog("[MockServer] listener failed: %@", "\(e)") }
            }
            return l
        }
        l.cancel()
        return nil
    }

    // MARK: - Connections

    private func accept(_ conn: NWConnection) {
        conn.start(queue: workQueue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                guard let request = HTTPRequest(head: head) else { conn.cancel(); return }
                if request.path == "/proxy" {
                    Task {
                        let response = await PlayerRoutes.proxy(request)
                        self.send(response, for: request, on: conn)
                    }
                    return
                }
                let response = PlayerRoutes.serveStatic(request.path) ?? MockRoutes.respond(to: request, port: self.port)
                self.send(response, for: request, on: conn)
            } else if isComplete || error != nil || buf.count > 256 * 1024 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func send(_ response: HTTPResponse, for request: HTTPRequest, on conn: NWConnection) {
        var status = response.status
        var body = response.body
        var headers = response.headers
        headers["Content-Type"] = response.contentType
        headers["Accept-Ranges"] = "bytes"
        headers["Connection"] = "close"
        headers["Access-Control-Allow-Origin"] = "*"

        // Byte ranges: "bytes=a-b", "bytes=a-", "bytes=-n"
        if status == 200, let range = request.headers["range"], let r = Self.parseRange(range, length: body.count) {
            status = 206
            headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(body.count)"
            body = body.subdata(in: r)
        }
        headers["Content-Length"] = String(body.count)

        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if request.method != "HEAD" { out.append(body) }
        if Self.shouldThrottle(request) {
            sendSlowly(out, from: 0, on: conn)
        } else {
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// Demo only: video *downloads* made by the app's own downloader are served at ~20 KB/s,
    /// so the download queue's pause/resume/cancel controls can actually be seen working.
    /// Playback (AVPlayer, WebKit) uses different User-Agents and is never slowed.
    static func shouldThrottle(_ req: HTTPRequest) -> Bool {
        req.path.contains("/media/video/") && (req.headers["user-agent"] ?? "").hasPrefix("MediaDeck")
    }

    private func sendSlowly(_ data: Data, from offset: Int, on conn: NWConnection) {
        let chunk = 8 * 1024
        let end = min(data.count, offset + chunk)
        let isLast = end >= data.count
        conn.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            if error != nil || isLast { conn.cancel(); return }
            self?.workQueue.asyncAfter(deadline: .now() + 0.4) { self?.sendSlowly(data, from: end, on: conn) }
        })
    }

    static func parseRange(_ header: String, length: Int) -> Range<Int>? {
        guard length > 0, header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let n = Int(parts[1]) {
            return max(0, length - n)..<length
        }
        guard let start = Int(parts[0]), start < length else { return nil }
        let end = Int(parts[1]).map { min($0, length - 1) } ?? (length - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    /// Lowercased header names.
    let headers: [String: String]

    init?(head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let comps = URLComponents(string: "http://x" + target)
        path = comps?.path ?? target
        var q: [String: String] = [:]
        // Keep "+" distinguishable: URLComponents doesn't turn "+" into a space.
        for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
        query = q
        var h: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            h[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        headers = h
    }
}

struct HTTPResponse {
    var status: Int = 200
    var contentType: String = "application/json"
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ s: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, contentType: type, body: Data(s.utf8))
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
