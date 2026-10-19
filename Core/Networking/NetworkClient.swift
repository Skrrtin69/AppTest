import Foundation

/// One per adapter. Applies the adapter's User-Agent, extra headers, proxy, timeout and
/// rate limit, and retries 5xx/timeouts up to 3 times with exponential backoff.
final class NetworkClient {
    struct Config: Equatable {
        var userAgent: String?
        var proxyHost: String?
        var proxyPort: Int?
        var timeout: Double = 20
        var headers: [String: String] = [:]
        var ratePerSecond: Double = 2
    }

    static let defaultUserAgent = "MediaDeck/\(AppInfo.version) (iOS)"
    static let maxRetries = 3

    let config: Config
    let limiter: RateLimiter
    let session: URLSession

    init(config: Config) {
        self.config = config
        limiter = RateLimiter(ratePerSecond: config.ratePerSecond)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = config.timeout
        cfg.timeoutIntervalForResource = max(config.timeout * 6, 60)
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // ImageCache is the only disk cache; don't let URLSession keep a second copy.
        cfg.urlCache = nil
        cfg.httpAdditionalHeaders = ["User-Agent": config.userAgent?.nonEmpty ?? Self.defaultUserAgent]
        if let host = config.proxyHost?.nonEmpty, let port = config.proxyPort {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port,
            ]
        }
        session = URLSession(configuration: cfg)
    }

    convenience init(adapter c: AdapterConfig) {
        self.init(config: Config(userAgent: c.userAgent, proxyHost: c.proxyHost, proxyPort: c.proxyPort,
                                 timeout: c.timeoutSeconds, headers: c.headers, ratePerSecond: c.rateLimitPerSecond))
    }

    /// Shared client for media that isn't tied to an adapter (e.g. library thumbnails).
    static let shared = NetworkClient(config: Config(ratePerSecond: 50))

    /// `acceptAnyStatus` returns 4xx/5xx responses instead of throwing (used by Auto-Configure
    /// to show the server's own error text).
    func data(for url: URL, headers: [String: String] = [:], rateLimited: Bool = true,
              acceptAnyStatus: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        for (k, v) in config.headers { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return try await data(for: request, rateLimited: rateLimited, acceptAnyStatus: acceptAnyStatus)
    }

    func data(for request: URLRequest, rateLimited: Bool = true, acceptAnyStatus: Bool = false) async throws -> (Data, HTTPURLResponse) {
        if request.url?.isFileURL == true, let url = request.url {
            let d = try Data(contentsOf: url)
            return (d, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        // The built-in demo server may still be starting (launch) or restarting (resume).
        if let url = request.url, MockServer.shared.serves(url) {
            await MockServer.shared.ensureReady()
        }
        var attempt = 0
        while true {
            if rateLimited { await limiter.acquire() }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AppError.badResponse("Not an HTTP response")
                }
                if (500...599).contains(http.statusCode), attempt < Self.maxRetries {
                    attempt += 1
                    try await backoff(attempt)
                    continue
                }
                guard acceptAnyStatus || (200...299).contains(http.statusCode) else {
                    throw AppError.http(status: http.statusCode, url: request.url ?? http.url ?? URL(fileURLWithPath: "/"),
                                        message: ErrorParser.describe(status: http.statusCode, data: data,
                                                                      contentType: http.value(forHTTPHeaderField: "Content-Type")))
                }
                return (data, http)
            } catch let e as URLError where Self.isRetryable(e) && attempt < Self.maxRetries {
                attempt += 1
                try await backoff(attempt)
            }
        }
    }

    private func backoff(_ attempt: Int) async throws {
        // 0.5s, 1s, 2s (+ jitter)
        let secs = 0.5 * pow(2, Double(attempt - 1)) + Double.random(in: 0...0.2)
        try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
    }

    static func isRetryable(_ e: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed]
            .contains(e.code)
    }
}

extension String {
    /// nil when the string is empty or whitespace.
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
