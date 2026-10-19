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
    /// Reports which engine ended up playing (or the error), for the on-screen label.
    var onStatus: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        Self.enableWebMFeatures(config.preferences)
        config.userContentController.add(context.coordinator, name: "status")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.isScrollEnabled = false
        wv.accessibilityIdentifier = "webVideo"
        context.coordinator.onStatus = onStatus
        context.coordinator.loadedURL = url
        wv.load(URLRequest(url: Self.playerURL(for: url, siteID: siteID)))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.onStatus = onStatus
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            wv.load(URLRequest(url: Self.playerURL(for: url, siteID: siteID)))
        }
        wv.evaluateJavaScript(isActive ? "window.mdPlay && mdPlay()" : "window.mdPause && mdPause()", completionHandler: nil)
        wv.evaluateJavaScript("window.mdSpeed && mdSpeed(\(speed))", completionHandler: nil)
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
        } else if url.host == "127.0.0.1" || url.host == "localhost" {
            src = url.absoluteString
        } else {
            src = "/proxy?url=" + encode(url.absoluteString) + (siteID.map { "&site=" + encode($0) } ?? "")
        }
        let type = url.pathExtension.lowercased() == "webm" ? "video/webm" : ""
        return URL(string: "\(server)/player/video.html?src=\(encode(src))&type=\(encode(type))") ?? url
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
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            let text = "\(message.body)"
            NSLog("[WebVideo] %@", text)
            if text.hasPrefix("engine:") || text.hasPrefix("error:") {
                let status = text.replacingOccurrences(of: "engine: ", with: "")
                DispatchQueue.main.async { self.onStatus?(status) }
            }
        }
    }
}
