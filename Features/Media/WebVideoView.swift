import SwiftUI
import WebKit

/// Fallback player for formats AVPlayer refuses (WebM). Loads the player page from the
/// local server (see PlayerRoutes): it tries WebKit's own <video> first and switches to the
/// bundled ogv.js WebAssembly decoder if WebKit can't play the file.
struct WebVideoView: UIViewRepresentable {
    let url: URL
    let isActive: Bool
    var siteID: String? = nil
    var speed: Double = 1
    /// false = auto-advance: report the end instead of looping.
    var loop: Bool = true
    var onFinished: (() -> Void)? = nil
    /// Called once the page's player can play (canplay, or playback started).
    var onReady: (() -> Void)? = nil
    /// Called when the page's player gives up (decoder or network error), with the reason.
    var onError: ((String) -> Void)? = nil
    /// Reports which engine ended up playing (or the error), for the on-screen label.
    var onStatus: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        Self.enableWebMFeatures(config.preferences)
        config.processPool = Self.processPool
        config.userContentController.add(context.coordinator, name: "status")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.isScrollEnabled = false
        wv.accessibilityIdentifier = "webVideo"
        context.coordinator.onStatus = onStatus
        context.coordinator.onReady = onReady
        context.coordinator.onError = onError
        context.coordinator.loadedURL = url
        wv.load(URLRequest(url: Self.playerURL(for: url, siteID: siteID)))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.onStatus = onStatus
        context.coordinator.onReady = onReady
        context.coordinator.onError = onError
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            wv.load(URLRequest(url: Self.playerURL(for: url, siteID: siteID)))
        }
        wv.evaluateJavaScript(isActive ? "window.mdPlay && mdPlay()" : "window.mdPause && mdPause()", completionHandler: nil)
        wv.evaluateJavaScript("window.mdSpeed && mdSpeed(\(speed)); window.mdSetLoop && mdSetLoop(\(loop))", completionHandler: nil)
        context.coordinator.onFinished = isActive ? onFinished : nil
    }

    static func dismantleUIView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.evaluateJavaScript("window.mdPause && mdPause()", completionHandler: nil)
        wv.stopLoading()
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "status")
    }

    /// Player page address. Same-machine URLs are used directly; downloaded files go
    /// through /local; anything else goes through /proxy so the decoder can read it.
    static func playerURL(for url: URL, siteID: String?) -> URL {
        let server = MockServer.shared.baseURL.absoluteString
        let src: String
        if url.isFileURL {
            let root = DownloadManager.root.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let rel = path.hasPrefix(root) ? String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
            src = "/local/" + rel.split(separator: "/").map { encode(String($0)) }.joined(separator: "/")
        } else {
            // Always through the proxy: it adds the site's headers (Referer, User-Agent…),
            // which WebKit's own requests can't carry, and avoids CORS limits.
            src = "/proxy?url=" + encode(url.absoluteString) + (siteID.map { "&site=" + encode($0) } ?? "")
        }
        let type = url.pathExtension.lowercased() == "webm" ? "video/webm" : ""
        let muted = AppSettings.shared.startMuted ? "&muted=1" : ""
        return URL(string: "\(server)/player/video.html?src=\(encode(src))&type=\(encode(type))\(muted)") ?? url
    }

    /// Shared by every web player, so later ones reuse the already running web process.
    static let processPool = WKProcessPool()
    private static var warm: WKWebView?

    /// Starts the web process and loads the player and decoder files once, off screen,
    /// so the first web video starts without that delay.
    @MainActor
    static func prewarm() {
        guard warm == nil else { return }
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        enableWebMFeatures(config.preferences)
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: config)
        // The player page in preload mode: loads ogv.js and every WebM module into the cache.
        if let u = URL(string: MockServer.shared.baseURL.absoluteString + "/player/video.html?preload=1") {
            wv.load(URLRequest(url: u))
        }
        warm = wv
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/:")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Private WebKit switches: turns on any WebM-related feature flags this iOS version has.
    /// Uses selectors looked up at runtime, so it is a no-op where they don't exist.
    static func enableWebMFeatures(_ prefs: WKPreferences) {
        typealias SetFn = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let pairs: [(list: String, setter: String)] = [
            ("_features", "_setEnabled:forFeature:"),
            ("_experimentalFeatures", "_setEnabled:forExperimentalFeature:"),
        ]
        for (listName, setterName) in pairs {
            let listSel = NSSelectorFromString(listName)
            let setSel = NSSelectorFromString(setterName)
            guard (WKPreferences.self as AnyObject).responds(to: listSel), prefs.responds(to: setSel),
                  let list = (WKPreferences.self as AnyObject).perform(listSel)?.takeUnretainedValue() as? [NSObject] else { continue }
            let fn = unsafeBitCast(prefs.method(for: setSel), to: SetFn.self)
            for feature in list {
                let key = (feature.value(forKey: "key") as? String) ?? ""
                if key.range(of: "webm", options: .caseInsensitive) != nil {
                    fn(prefs, setSel, true, feature)
                    NSLog("[WebVideo] enabled WebKit feature %@", key)
                }
            }
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loadedURL: URL?
        var onStatus: ((String) -> Void)?
        var onFinished: (() -> Void)?
        var onReady: (() -> Void)?
        var onError: ((String) -> Void)?
        private var readySent = false
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            let text = "\(message.body)"
            NSLog("[WebVideo] %@", text)
            if text == "ended" { DispatchQueue.main.async { self.onFinished?() } }
            if !readySent, text == "canplay" || text.hasPrefix("engine:") {
                readySent = true
                DispatchQueue.main.async { self.onReady?() }
            }
            if text.hasPrefix("error:") {
                let why = String(text.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
                DispatchQueue.main.async { self.onError?("This video couldn't be played (\(why)).") }
            }
            if text.hasPrefix("engine:") || text.hasPrefix("error:") {
                let status = text.replacingOccurrences(of: "engine: ", with: "")
                DispatchQueue.main.async { self.onStatus?(status) }
            }
        }
    }
}
