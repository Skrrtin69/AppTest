import SwiftUI
import WebKit

/// Opens a site's Cloudflare check so the user can pass it. When the cf_clearance cookie
/// appears, the site's cookies are copied to the app's network cookie store and the
/// browser's User-Agent is reported (the pass only works with that same User-Agent).
struct CloudflareVerifyView: View {
    let url: URL
    let onVerified: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = Model()

    final class Model: ObservableObject {
        weak var webView: WKWebView?
        var timer: Timer?
        var done = false
        /// cf_clearance values that existed before the page opened: only a new one closes it.
        var before: Set<String>?
    }

    /// Just the scheme and host (and port): https://example.com/. API addresses aren't
    /// pages, so opening one shows the site's 404 instead of the check.
    static func siteRoot(of address: String) -> URL? {
        guard let u = URL(string: address), let scheme = u.scheme, let host = u.host else { return nil }
        return URL(string: "\(scheme)://\(host)\(u.port.map { ":\($0)" } ?? "")/")
    }

    var root: URL { Self.siteRoot(of: url.absoluteString) ?? url }

    var body: some View {
        NavigationView {
            CloudflareWebView(url: root, model: model)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Security check")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    // For when the site had already let this browser in (no new pass appears).
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { finish(force: true) }.accessibilityIdentifier("cloudflareDone")
                    }
                }
        }
        .onAppear { startWatching() }
        .onDisappear { model.timer?.invalidate() }
    }

    private func startWatching() {
        model.timer?.invalidate()
        model.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in finish(force: false) }
    }

    private func cookies(_ done: @escaping ([HTTPCookie]) -> Void) {
        guard let wv = model.webView, let host = root.host?.lowercased() else { return done([]) }
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { all in
            done(all.filter { c in
                let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == d || host.hasSuffix("." + d)
            })
        }
    }

    /// Closes (and hands over the cookies and User-Agent) when a new cf_clearance appears,
    /// or right away when `force` (Done). Error pages (404…) never close it.
    private func finish(force: Bool) {
        guard !model.done, let wv = model.webView else { return }
        cookies { mine in
            let passes = Set(mine.filter { $0.name == "cf_clearance" }.map(\.value))
            if model.before == nil { model.before = passes; if !force { return } }
            guard !model.done, force || !passes.subtracting(model.before ?? []).isEmpty else { return }
            model.done = true
            model.timer?.invalidate()
            for c in mine { HTTPCookieStorage.shared.setCookie(c) }
            wv.evaluateJavaScript("navigator.userAgent") { result, _ in
                let ua = (result as? String) ?? ""
                DebugLog.log("Cloudflare", "\(force ? "done tapped" : "new pass") for \(root.host ?? ""); \(mine.count) cookie(s) kept")
                onVerified(ua)
                dismiss()
                ToastCenter.shared.show(passes.isEmpty ? "No pass from the site yet. Trying again anyway…" : "Verified. Trying the site again…",
                                        style: passes.isEmpty ? .error : .success)
            }
        }
    }
}

private struct CloudflareWebView: UIViewRepresentable {
    let url: URL
    let model: CloudflareVerifyView.Model

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        wv.accessibilityIdentifier = "cloudflareWebView"
        model.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}
}
