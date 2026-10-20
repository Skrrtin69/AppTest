import Foundation

/// Measures download speed once per launch (1 MB from a fast CDN) and turns it into the
/// web video player's start-up timeout: slower connections get longer before "Retry".
@MainActor
final class NetworkSpeed: ObservableObject {
    static let shared = NetworkSpeed()

    /// A 1 MB test payload from a CDN built for speed tests (no media site).
    static let testURL = URL(string: "https://speed.cloudflare.com/__down?bytes=1000000")!

    enum Tier: String {
        case fast = "Fast", average = "Average", slow = "Slow", unknown = "Not measured"
    }

    /// Megabits per second; nil until measured (or when the test failed).
    @Published private(set) var mbps: Double?
    @Published private(set) var failed = false
    private var running = false

    var tier: Tier {
        guard let m = mbps else { return failed ? .slow : .unknown }
        return m > 15 ? .fast : (m >= 5 ? .average : .slow)
    }

    /// Seconds the web player gets to start: > 15 Mbps 15 s, 5–15 Mbps 30 s, < 5 Mbps 60 s.
    /// A failed test counts as slow; before the test finishes, the middle value is used.
    var videoTimeout: Double {
        switch tier {
        case .fast: return 15
        case .average, .unknown: return 30
        case .slow: return 60
        }
    }

    var summary: String {
        let speed = mbps.map { String(format: "%.1f Mbps", $0) } ?? (failed ? "test failed" : "measuring…")
        return "\(speed) · \(tier.rawValue) · video timeout \(Int(videoTimeout)) s"
    }

    func measure() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: Self.testURL)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let seconds = max(Date().timeIntervalSince(start), 0.001)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100_000 else { throw URLError(.badServerResponse) }
            mbps = Double(data.count) * 8 / seconds / 1_000_000
            failed = false
            DebugLog.log("Network", "Speed test: \(data.count) bytes in \(String(format: "%.2f", seconds)) s → \(summary)")
        } catch {
            mbps = nil
            failed = true
            DebugLog.log("Network", "Speed test failed (\(error.localizedDescription)) → \(summary)")
        }
    }
}
