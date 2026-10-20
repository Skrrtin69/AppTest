import Foundation

/// In-app log for the debug console (Settings › About › tap Version 5 times). Keeps the
/// last 600 lines in memory; secrets in addresses are masked before anything is stored.
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    struct Line: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    private let lock = NSLock()

    static func log(_ category: String, _ text: String) {
        NSLog("[%@] %@", category, text)
        let line = Line(date: Date(), category: category, text: text)
        DispatchQueue.main.async {
            shared.lines.append(line)
            if shared.lines.count > 600 { shared.lines.removeFirst(shared.lines.count - 600) }
        }
    }

    func clear() { lines = [] }

    var text: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return lines.map { "\(f.string(from: $0.date)) [\($0.category)] \($0.text)" }.joined(separator: "\n")
    }

    /// An address with key / token / password / user values replaced by "•••".
    static func redact(_ url: URL?) -> String {
        guard let url = url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "?" }
        let secret = ["key", "token", "pass", "secret", "auth", "session", "user_id", "userid", "login", "sig"]
        c.queryItems = c.queryItems?.map { q in
            secret.contains(where: { q.name.lowercased().contains($0) }) ? URLQueryItem(name: q.name, value: "•••") : q
        }
        c.user = nil; c.password = nil
        return c.string ?? url.absoluteString
    }
}
