import Foundation

/// In-app log for the debug console (Settings › About › tap Version 5 times). Keeps the
/// last 600 lines in memory; secrets in addresses are masked before anything is stored.
/// Every line is also written to a file right away (off the main thread), so after a
/// freeze or crash the next launch can still show what happened ("Previous run").
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    struct Line: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    /// The end of the last run's log (it may have ended in a freeze or a crash).
    private(set) var previousRun = ""

    private static let fileQueue = DispatchQueue(label: "MediaDeck.DebugLog.file", qos: .utility)
    private static let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DebugLog.txt")
    /// Used on fileQueue only.
    private static var handle: FileHandle?
    private static var written = 0
    private static let maxFileBytes = 600_000

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private init() {
        // Keep the last run's tail, then start this run's file.
        if let data = try? Data(contentsOf: Self.fileURL) {
            let text = String(decoding: data.suffix(120_000), as: UTF8.self)
            previousRun = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(400).joined(separator: "\n")
        }
        Self.fileQueue.async {
            FileManager.default.createFile(atPath: Self.fileURL.path, contents: nil)
            Self.handle = try? FileHandle(forWritingTo: Self.fileURL)
            Self.written = 0
        }
    }

    static func log(_ category: String, _ text: String) {
        NSLog("[%@] %@", category, text)
        let line = Line(date: Date(), category: category, text: text)
        writeToFile(line)
        DispatchQueue.main.async {
            shared.lines.append(line)
            if shared.lines.count > 600 { shared.lines.removeFirst(shared.lines.count - 600) }
        }
    }

    /// Straight to the file, never through the main thread (used by the hang watchdog,
    /// when the main thread is the thing that's stuck).
    static func writeToFile(_ line: Line) {
        _ = shared   // the file is opened (and the last run kept) on first use
        let text = "\(stampFormat.string(from: line.date)) [\(line.category)] \(line.text)\n"
        fileQueue.async {
            guard let h = handle else { return }
            let data = Data(text.utf8)
            h.write(data)
            written += data.count
            if written > maxFileBytes { trimFile() }
        }
    }

    /// Keeps the newest half of the file.
    private static func trimFile() {
        try? handle?.close()
        if let data = try? Data(contentsOf: fileURL) {
            try? data.suffix(maxFileBytes / 2).write(to: fileURL)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        written = maxFileBytes / 2
    }

    func clear() { lines = []; previousRun = "" }

    var text: String {
        let now = lines.map { "\(Self.stampFormat.string(from: $0.date)) [\($0.category)] \($0.text)" }.joined(separator: "\n")
        guard !previousRun.isEmpty else { return now }
        return "— Previous run (end) —\n" + previousRun + "\n— This run —\n" + now
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

/// Notices when the main thread stops responding (a freeze) and writes it to the log file
/// with the time, so the lines just before it show what the app was doing.
enum HangWatchdog {
    private static let lock = NSLock()
    private static var lastBeat = Date()
    private static var started = false

    static func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        let t = Thread {
            var reported: Date?
            var lastLoop = Date()
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let now = Date()
                // The app was suspended (background): the gap says nothing about main.
                if now.timeIntervalSince(lastLoop) > 2 {
                    lastLoop = now
                    lock.lock(); lastBeat = now; lock.unlock()
                    continue
                }
                lastLoop = now
                DispatchQueue.main.async { lock.lock(); lastBeat = Date(); lock.unlock() }
                lock.lock(); let beat = lastBeat; lock.unlock()
                let stuck = now.timeIntervalSince(beat)
                if stuck > 2.5, reported == nil {
                    reported = beat
                    DebugLog.writeToFile(.init(date: now, category: "Hang", text: "The main thread hasn't responded for \(String(format: "%.1f", stuck)) s (the lines just above show what it was doing)"))
                } else if stuck < 1, let since = reported {
                    reported = nil
                    DebugLog.log("Hang", "The main thread responded again after \(String(format: "%.1f", now.timeIntervalSince(since))) s")
                }
            }
        }
        t.name = "MediaDeck.HangWatchdog"
        t.qualityOfService = .utility
        t.start()
    }
}
