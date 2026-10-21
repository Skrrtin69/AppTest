import SwiftUI
import WebKit

/// Opens a site's Cloudflare check so the user can pass it. When the cf_clearance cookie
/// appears, the site's cookies are copied to the app's network cookie store and the
/// browser's User-Agent is reported (the pass only works with that same User-Agent).
struct CloudflareVerifyView: View {
    let url: URL
    /// Open `url` as it is instead of the site's home page: for a check that only guards
    /// one address (e.g. a reverse engine's search page while its home page is open).
    var exact: Bool = false
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

    /// Remembers the passes present once the first page has loaded.
    fileprivate func takeBaseline() {
        guard model.before == nil else { return }
        cookies { mine in
            if model.before == nil { model.before = Set(mine.filter { $0.name == "cf_clearance" }.map(\.value)) }
        }
    }

    /// Just the scheme and host (and port): https://example.com/. API addresses aren't
    /// pages, so opening one shows the site's 404 instead of the check.
    static func siteRoot(of address: String) -> URL? {
        guard let u = URL(string: address), let scheme = u.scheme, let host = u.host else { return nil }
        return URL(string: "\(scheme)://\(host)\(u.port.map { ":\($0)" } ?? "")/")
    }

    var root: URL { exact ? url : (Self.siteRoot(of: url.absoluteString) ?? url) }

    var body: some View {
        NavigationView {
            CloudflareWebView(url: root, model: model, onFirstLoad: { takeBaseline() })
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
        // The baseline is taken once the first page has loaded (the cookie store can read
        // as empty before that), so an old pass isn't mistaken for a new one.
        guard force || model.before != nil else { return }
        cookies { mine in
            let passes = Set(mine.filter { $0.name == "cf_clearance" }.map(\.value))
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
    let onFirstLoad: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFirstLoad: onFirstLoad) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        wv.accessibilityIdentifier = "cloudflareWebView"
        wv.navigationDelegate = context.coordinator
        model.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onFirstLoad: () -> Void
        private var loaded = false
        init(onFirstLoad: @escaping () -> Void) { self.onFirstLoad = onFirstLoad }

        // Error pages (404…) load like any page: nothing here ever closes the sheet.
        func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
            guard !loaded else { return }
            loaded = true
            onFirstLoad()
        }

        func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !loaded { loaded = true; onFirstLoad() }
        }

        func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if !loaded { loaded = true; onFirstLoad() }
        }
    }
}
