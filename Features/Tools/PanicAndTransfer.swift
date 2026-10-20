import SwiftUI
import UIKit
import Network

// MARK: - Panic button

/// Shake the phone or swipe down with two fingers: the app is instantly covered by a blur or
/// a working calculator. Blur: tap three times to uncover. Calculator: type your passcode and
/// press "=" (or, without a passcode, hold "AC" for two seconds).
@MainActor
final class PanicManager: ObservableObject {
    static let shared = PanicManager()
    @Published var active = false

    func trigger() {
        guard AppSettings.shared.panicGesture != "off", !active else { return }
        active = true
        Haptics.tap()
        DebugLog.log("Panic", "cover shown (\(AppSettings.shared.panicAction))")
    }

    func dismiss() { active = false }

    /// Two-finger swipe down anywhere in the app window.
    func installSwipe() {
        guard let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: { !($0 is PassthroughWindow) }) else { return }
        guard w.gestureRecognizers?.contains(where: { $0.name == "panicSwipe" }) != true else { return }
        let g = UISwipeGestureRecognizer(target: PanicTarget.shared, action: #selector(PanicTarget.swiped))
        g.direction = .down
        g.numberOfTouchesRequired = 2
        g.cancelsTouchesInView = false
        g.name = "panicSwipe"
        w.addGestureRecognizer(g)
    }
}

final class PanicTarget: NSObject {
    static let shared = PanicTarget()
    @objc func swiped() {
        Task { @MainActor in if AppSettings.shared.panicGesture == "twoFingerSwipe" { PanicManager.shared.trigger() } }
    }
}

extension UIWindow {
    /// Shake gesture → panic cover (when chosen in Settings).
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake else { return }
        Task { @MainActor in if AppSettings.shared.panicGesture == "shake" { PanicManager.shared.trigger() } }
    }
}

struct PanicCover: View {
    @ObservedObject private var panic = PanicManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var taps = 0

    var body: some View {
        if settings.panicAction == "calculator" {
            CalculatorView()
        } else {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
                .overlay(Color.black.opacity(0.35).ignoresSafeArea())
                .contentShape(Rectangle())
                .onTapGesture(count: 3) { panic.dismiss() }
                .accessibilityLabel("Covered. Tap three times to uncover.")
                .accessibilityIdentifier("panicBlur")
        }
    }
}

/// A real calculator, so the cover holds up to a quick look.
struct CalculatorView: View {
    @State private var display = "0"
    @State private var stored: Double?
    @State private var op: String?
    @State private var fresh = true
    @State private var typed = ""        // digits since the last "=", for the unlock code

    let rows = [["AC", "±", "%", "÷"], ["7", "8", "9", "×"], ["4", "5", "6", "−"], ["1", "2", "3", "+"], ["0", ".", "="]]

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(display).font(.system(size: 72, weight: .light)).foregroundColor(.white)
                .lineLimit(1).minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 24)
                .accessibilityIdentifier("calcDisplay")
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { k in key(k) }
                }
            }
        }
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    func key(_ k: String) -> some View {
        let isOp = ["÷", "×", "−", "+", "="].contains(k)
        let isFn = ["AC", "±", "%"].contains(k)
        return Text(k)
            .font(.system(size: 32, weight: .medium))
            .foregroundColor(isFn ? .black : .white)
            .frame(width: k == "0" ? 166 : 78, height: 78)
            .background(Capsule().fill(isOp ? Color.orange : (isFn ? Color(white: 0.65) : Color(white: 0.2))))
            .onTapGesture { press(k) }
            .onLongPressGesture(minimumDuration: 2) {
                if k == "AC" && !LockManager.shared.hasPasscode { PanicManager.shared.dismiss() }
            }
            .accessibilityLabel("Calculator \(k)")
    }

    func press(_ k: String) {
        switch k {
        case "0"..."9", ".":
            if k != "." { typed.append(k) }
            if fresh { display = k == "." ? "0." : k; fresh = false }
            else if !(k == "." && display.contains(".")) { display += k }
        case "AC": display = "0"; stored = nil; op = nil; fresh = true; typed = ""
        case "±": if let v = Double(display) { display = format(-v) }
        case "%": if let v = Double(display) { display = format(v / 100) }
        case "=":
            // The passcode followed by "=" leaves the cover.
            if LockManager.shared.hasPasscode, LockManager.shared.verify(String(typed.suffix(LockManager.pinLength))) {
                PanicManager.shared.dismiss(); return
            }
            compute(); op = nil; typed = ""
        default:
            compute(); op = k; fresh = true
        }
    }

    func compute() {
        guard let v = Double(display) else { return }
        if let s = stored, let o = op {
            let r: Double
            switch o {
            case "+": r = s + v
            case "−": r = s - v
            case "×": r = s * v
            case "÷": r = v == 0 ? .nan : s / v
            default: r = v
            }
            display = r.isNaN ? "Error" : format(r)
            stored = r
        } else {
            stored = v
        }
        fresh = true
    }

    func format(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(format: "%.8g", v)
    }
}

// MARK: - Wi-Fi Transfer

/// A small web page on the local network (only while its screen is open, and only with the
/// code shown there): download Library files and saved archives to a computer, or upload
/// pictures and videos into the Library.
@MainActor
final class WiFiTransfer: ObservableObject {
    static let shared = WiFiTransfer()
    static let port: UInt16 = 8899
    @Published private(set) var running = false
    @Published private(set) var address: String?
    @Published private(set) var log: [String] = []
    private(set) var code = ""
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "wifi.transfer")

    func start() {
        guard listener == nil else { return }
        code = String(format: "%06d", Int.random(in: 0...999_999))
        guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!) else { note("Couldn't start the server."); return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                if case .ready = st { self?.running = true }
                if case .failed(let e) = st { self?.note("Server stopped: \(e)"); self?.stop() }
            }
        }
        l.start(queue: queue)
        listener = l
        address = Self.wifiIP().map { "http://\($0):\(Self.port)/?code=\(code)" }
        note("Started")
    }

    func stop() {
        listener?.cancel(); listener = nil
        running = false
        note("Stopped")
    }

    private func note(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 30 { log.removeLast() }
        DebugLog.log("WiFi", s)
    }

    /// The phone's address on Wi-Fi (en0).
    nonisolated static func wifiIP() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0, let first = addr else { return nil }
        defer { freeifaddrs(addr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            let a = i.pointee
            if a.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: a.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a.ifa_addr, socklen_t(a.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            p = a.ifa_next
        }
        return nil
    }

    // MARK: HTTP

    nonisolated private func accept(_ c: NWConnection) {
        c.start(queue: DispatchQueue(label: "wifi.conn"))
        receive(c, Data())
    }

    nonisolated private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self = self else { c.cancel(); return }
            var b = buf
            if let d = data { b.append(d) }
            guard let end = b.range(of: Data("\r\n\r\n".utf8)) else {
                if done || err != nil || b.count > 64 * 1024 { c.cancel() } else { self.receive(c, b) }
                return
            }
            let head = String(decoding: b[..<end.lowerBound], as: UTF8.self)
            let length = Self.header(head, "content-length").flatMap(Int.init) ?? 0
            let bodyStart = end.upperBound
            if length > 0, b.count - bodyStart < min(length, 500_000_000), !done, err == nil {
                self.receive(c, b); return
            }
            let body = length > 0 ? Data(b[bodyStart...].prefix(length)) : Data()
            Task { @MainActor in
                let (status, type, payload, file) = self.handle(head: head, body: body)
                self.send(c, status: status, type: type, body: payload, file: file)
            }
        }
    }

    nonisolated static func header(_ head: String, _ name: String) -> String? {
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func handle(head: String, body: Data) -> (Int, String, Data, URL?) {
        let first = head.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard first.count >= 2, let comps = URLComponents(string: String(first[1])) else { return (400, "text/plain", Data("Bad request".utf8), nil) }
        let method = String(first[0])
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["code"] == code else {
            return (403, "text/html; charset=utf-8", Data(page("<h1>MediaDeck</h1><p>Open the address shown in MediaDeck › Settings › Wi-Fi Transfer (it includes a code).</p>").utf8), nil)
        }
        switch (method, comps.path) {
        case ("GET", "/"):
            return (200, "text/html; charset=utf-8", Data(indexPage().utf8), nil)
        case ("GET", "/file"):
            guard let rel = q["path"], !rel.contains(".."), !rel.hasPrefix("/") else { return (400, "text/plain", Data(), nil) }
            let url = DownloadManager.root.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { return (404, "text/plain", Data("Not found".utf8), nil) }
            note("Sent \(url.lastPathComponent)")
            return (200, "application/octet-stream", Data(), url)
        case ("POST", "/upload"):
            let boundary = Self.header(head, "content-type")?.components(separatedBy: "boundary=").last?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
            let files = Self.multipartFiles(body, boundary: boundary)
            var saved: [String] = []
            for (name, data) in files where !data.isEmpty {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try data.write(to: tmp)
                    try DownloadManager.shared.importLocalFile(tmp, name: name)
                    saved.append(name)
                } catch { note("Upload of \(name) failed: \(error.localizedDescription)") }
            }
            note(saved.isEmpty ? "Upload had no files" : "Received \(saved.joined(separator: ", "))")
            if !saved.isEmpty { ToastCenter.shared.show("Received \(saved.count) file\(saved.count == 1 ? "" : "s") over Wi-Fi", style: .success) }
            return (200, "text/html; charset=utf-8", Data(page("<p>Saved \(saved.count) file(s) to the Library.</p><p><a href='/?code=\(code)'>Back</a></p>").utf8), nil)
        default:
            return (404, "text/plain", Data("Not found".utf8), nil)
        }
    }

    /// The (filename, data) of every file part in a multipart/form-data body.
    nonisolated static func multipartFiles(_ body: Data, boundary: String) -> [(String, Data)] {
        guard !boundary.isEmpty else { return [] }
        let sep = Data("--\(boundary)".utf8)
        var out: [(String, Data)] = []
        var pos = body.startIndex
        while let r = body.range(of: sep, in: pos..<body.endIndex) {
            let partStart = r.upperBound
            guard let next = body.range(of: sep, in: partStart..<body.endIndex) else { break }
            var part = body[partStart..<next.lowerBound]
            if part.starts(with: Data("\r\n".utf8)) { part = part.dropFirst(2) }
            if let h = part.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: part[part.startIndex..<h.lowerBound], as: UTF8.self)
                var content = part[h.upperBound...]
                if content.suffix(2) == Data("\r\n".utf8) { content = content.dropLast(2) }
                if let fn = headers.components(separatedBy: "filename=\"").dropFirst().first?.components(separatedBy: "\"").first, !fn.isEmpty {
                    out.append(((fn as NSString).lastPathComponent, Data(content)))
                }
            }
            pos = next.lowerBound
        }
        return out
    }

    private func indexPage() -> String {
        let fm = FileManager.default
        var rows = ""
        let items = DownloadManager.shared.completed
        for i in items {
            guard let rel = i.relativePath, let url = i.fileURL else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
            let enc = rel.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rel
            rows += "<tr><td><a href='/file?path=\(enc)&code=\(code)' download>\(escape(url.lastPathComponent))</a></td><td>\(escape(AdapterRegistry.shared.displayName(for: i.post.siteID)))</td><td>\(size)</td></tr>"
        }
        // Saved archives (Save as CBZ also keeps a copy here).
        let archives = DownloadManager.root.appendingPathComponent("Archives")
        for u in (try? fm.contentsOfDirectory(at: archives, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
            let enc = "Archives/\(u.lastPathComponent)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            rows += "<tr><td><a href='/file?path=\(enc)&code=\(code)' download>\(escape(u.lastPathComponent))</a></td><td>Archive</td><td>\(size)</td></tr>"
        }
        return page("""
        <h1>MediaDeck</h1>
        <h2>Upload to the Library</h2>
        <form method='post' action='/upload?code=\(code)' enctype='multipart/form-data'>
        <input type='file' name='file' multiple> <button>Upload</button></form>
        <h2>Library (\(items.count))</h2>
        <table><tr><th>File</th><th>Site</th><th>Size</th></tr>\(rows)</table>
        """)
    }

    private func page(_ body: String) -> String {
        "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width'><title>MediaDeck Wi-Fi Transfer</title><style>body{font:15px -apple-system,sans-serif;margin:24px;max-width:900px}td,th{padding:4px 10px;text-align:left}a{color:#2a7}</style></head><body>\(body)</body></html>"
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    nonisolated private func send(_ c: NWConnection, status: Int, type: String, body: Data, file: URL?) {
        var payload = body
        var ctype = type
        var extra = ""
        if let f = file, let d = try? Data(contentsOf: f, options: .mappedIfSafe) {
            payload = d
            ctype = "application/octet-stream"
            extra = "Content-Disposition: attachment; filename=\"\(f.lastPathComponent.replacingOccurrences(of: "\"", with: ""))\"\r\n"
        }
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(ctype)\r\nContent-Length: \(payload.count)\r\n\(extra)Connection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in c.cancel() })
    }
}

struct WiFiTransferView: View {
    @ObservedObject private var server = WiFiTransfer.shared

    var body: some View {
        List {
            Section {
                if server.running, let a = server.address {
                    Text("On a computer on the same Wi-Fi, open:").font(.footnote).foregroundColor(.secondary)
                    Text(a).font(.body.monospaced()).textSelection(.enabled).accessibilityIdentifier("wifiAddress")
                    Button { UIPasteboard.general.string = a; ToastCenter.shared.show("Address copied") } label: { Label("Copy Address", systemImage: "doc.on.doc") }
                } else if server.running {
                    Text("Running, but this phone isn't on Wi-Fi.").foregroundColor(.orange)
                } else {
                    ProgressView()
                }
            } header: { Text("Wi-Fi Transfer") } footer: {
                Text("Download Library files and saved archives (CBZ) to a computer, or upload pictures and videos into the Library. It runs only while this screen is open, and only with the code in the address. Stay on this screen while transferring.")
            }
            Section("Activity") {
                ForEach(Array(server.log.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
            }
        }
        .navigationTitle("Wi-Fi Transfer")
        .onAppear { server.start(); UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { server.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    }
}
