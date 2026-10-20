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
    }

    var body: some View {
        NavigationView {
            CloudflareWebView(url: url, model: model)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Security check")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear { startWatching() }
        .onDisappear { model.timer?.invalidate() }
    }

    private func startWatching() {
        model.timer?.invalidate()
        model.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in check() }
    }

    private func check() {
        guard !model.done, let wv = model.webView, let host = url.host?.lowercased() else { return }
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let mine = cookies.filter { c in
                let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == d || host.hasSuffix("." + d)
            }
            guard !model.done, mine.contains(where: { $0.name == "cf_clearance" }) else { return }
            model.done = true
            model.timer?.invalidate()
            for c in mine { HTTPCookieStorage.shared.setCookie(c) }
            wv.evaluateJavaScript("navigator.userAgent") { result, _ in
                let ua = (result as? String) ?? ""
                DebugLog.log("Cloudflare", "passed for \(host); \(mine.count) cookie(s) kept")
                onVerified(ua)
                dismiss()
                ToastCenter.shared.show("Verified. Trying the site again…", style: .success)
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
