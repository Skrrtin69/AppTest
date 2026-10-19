import SwiftUI
import WebKit

/// Fallback player for formats AVPlayer refuses (WebM): a WKWebView with a minimal
/// HTML5 <video> element that loops and plays inline.
struct WebVideoView: UIViewRepresentable {
    let url: URL
    let isActive: Bool

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
        load(into: wv)
        context.coordinator.loadedURL = url
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            load(into: wv)
        }
        let js = isActive ? "var v=document.getElementById('v'); if(v){v.play();}" : "var v=document.getElementById('v'); if(v){v.pause();}"
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    static func dismantleUIView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.evaluateJavaScript("var v=document.getElementById('v'); if(v){v.pause(); v.src='';}", completionHandler: nil)
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "status")
    }

    private func load(into wv: WKWebView) {
        let src = url.isFileURL ? url.lastPathComponent : url.absoluteString
        let html = Self.html(src: src.replacingOccurrences(of: "\"", with: "%22"),
                             type: url.pathExtension.lowercased() == "webm" ? "video/webm" : "")
        if url.isFileURL {
            // Local files: write the page next to the video so WebKit may read both.
            let dir = url.deletingLastPathComponent()
            let page = FileManager.default.temporaryDirectory.appendingPathComponent("player-\(UUID().uuidString).html")
            let absoluteHTML = Self.html(src: url.absoluteString, type: "")
            try? absoluteHTML.write(to: page, atomically: true, encoding: .utf8)
            _ = dir
            wv.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: NSHomeDirectory()))
        } else {
            wv.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        }
    }

    static func html(src: String, type: String) -> String {
        let typeAttr = type.isEmpty ? "" : " type=\"\(type)\""
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        video{position:absolute;top:0;left:0;width:100%;height:100%;object-fit:contain}
        #msg{color:#fff;font:16px -apple-system;padding:24px;position:absolute;top:40%;width:100%;box-sizing:border-box;text-align:center}</style>
        </head><body>
        <video id="v" autoplay loop playsinline muted controls><source src="\(src)"\(typeAttr)></video>
        <script>
        var v=document.getElementById('v');
        function post(m){try{window.webkit.messageHandlers.status.postMessage(m);}catch(e){}}
        post('canPlayType(webm)=' + v.canPlayType('video/webm'));
        function fail(){
          document.body.innerHTML='<div id="msg">This video format can\\'t be played on this device.<br>Download it and open it in another app.</div>';
          post('error');
        }
        v.addEventListener('error', fail, true);
        var s=v.querySelector('source'); if(s){s.addEventListener('error', fail);}
        v.addEventListener('playing', function(){post('playing');});
        v.addEventListener('loadedmetadata', function(){post('metadata ' + v.videoWidth + 'x' + v.videoHeight);});
        </script></body></html>
        """
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
            let imp = prefs.method(for: setSel)
            let fn = unsafeBitCast(imp, to: SetFn.self)
            for feature in list {
                let key = (feature.value(forKey: "key") as? String) ?? ""
                if key.range(of: "webm", options: .caseInsensitive) != nil ||
                    key.range(of: "vorbis", options: .caseInsensitive) != nil ||
                    key.range(of: "opus", options: .caseInsensitive) != nil {
                    fn(prefs, setSel, true, feature)
                    NSLog("[WebVideo] enabled WebKit feature %@", key)
                }
            }
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loadedURL: URL?
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            NSLog("[WebVideo] %@", "\(message.body)")
        }
    }
}
