import SwiftUI
import WebKit

/// The app's current colors as CSS values (also used by custom themes later).
enum ThemePalette {
    struct Colors { let background: String; let surface: String; let text: String; let accent: String }

    static var current: Colors {
        let mode = AppSettings.shared.theme
        if let c = mode.custom {
            return Colors(background: c.background, surface: c.surface, text: c.text, accent: c.accent)
        }
        let dark: Bool
        switch mode {
        case .light: dark = false
        case .dark, .amoled: dark = true
        case .custom: dark = true
        case .system: dark = UITraitCollection.current.userInterfaceStyle == .dark
        }
        if mode == .amoled { return Colors(background: "#000000", surface: "#111111", text: "#FFFFFF", accent: "#0A84FF") }
        return dark ? Colors(background: "#1C1C1E", surface: "#2C2C2E", text: "#FFFFFF", accent: "#0A84FF")
                    : Colors(background: "#F2F2F7", surface: "#FFFFFF", text: "#000000", accent: "#007AFF")
    }

    /// Stylesheet that makes a site page look like part of the app.
    static var css: String {
        let c = current
        return """
        html, body { background: \(c.background) !important; color: \(c.text) !important;
          font-family: -apple-system, system-ui !important; }
        a { color: \(c.accent) !important; }
        input, textarea, select, button { font-family: -apple-system !important; font-size: 16px !important;
          border-radius: 8px !important; }
        input, textarea, select { background: \(c.surface) !important; color: \(c.text) !important;
          border: 1px solid rgba(128,128,128,.4) !important; padding: 8px !important; }
        header, footer, nav, aside, [class*="ad-"], [id*="ad-"], [class*="advert"], [class*="banner"] { display: none !important; }
        """
    }
}

/// A site page (sign-up, login, API key page) styled with the app's theme. The user
/// logs in themselves; "Copy Selection" copies whatever text they highlighted.
struct ThemedWebPage: View {
    let url: URL
    var prefillUsername: String? = nil
    /// When set, the toolbar offers "Find Key on Page"; called with the chosen key and the
    /// user ID found on the same page (if any).
    var onFindKey: ((KeyFinder.Found, KeyFinder.Found?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = Model()
    @State private var choices: KeyFinder.Result?

    final class Model: ObservableObject {
        weak var webView: WKWebView?
        @Published var title = ""
    }

    var body: some View {
        NavigationView {
            ThemedWebView(url: url, prefillUsername: prefillUsername, model: model)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(model.title.isEmpty ? (url.host ?? "") : model.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { model.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Back")
                        Spacer()
                        if onFindKey != nil {
                            Button { findKey() } label: { Label("Find Key on Page", systemImage: "key.viewfinder") }
                                .labelStyle(.titleAndIcon)
                                .accessibilityIdentifier("findKeyOnPage")
                        } else {
                            Button { copySelection() } label: { Label("Copy Selection", systemImage: "doc.on.doc") }
                                .accessibilityIdentifier("copySelection")
                        }
                        Spacer()
                        Button { model.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Reload")
                    }
                }
                .sheet(isPresented: Binding(get: { choices != nil }, set: { if !$0 { choices = nil } })) {
                    if let r = choices { keyPicker(r) }
                }
        }
    }

    /// Several possible keys: the user picks one, each shown with where it was found.
    func keyPicker(_ r: KeyFinder.Result) -> some View {
        NavigationView {
            List {
                Section {
                    ForEach(r.keys) { k in
                        Button { choices = nil; deliver(k, r.userID) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(k.context).font(.subheadline).foregroundColor(.secondary)
                                Text(k.value).font(.callout.monospaced()).foregroundColor(.primary).lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                        .accessibilityIdentifier("keyChoice")
                    }
                } footer: {
                    if let u = r.userID { Text("User ID found too: \(u.value)") }
                }
            }
            .navigationTitle("Which one is your API key?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choices = nil } } }
        }
    }

    /// Reads the page's visible text and text boxes and looks for the key by its label.
    func findKey() {
        guard let wv = model.webView else { return }
        wv.evaluateJavaScript(KeyFinder.pageScript) { value, error in
            guard let json = value as? String else {
                ToastCenter.shared.show("Couldn't read this page: \(error?.localizedDescription ?? "no text")", style: .error)
                return
            }
            let r = KeyFinder.find(json: json)
            DebugLog.log("KeyFinder", "\(r.keys.count) key(s)\(r.userID != nil ? " + user ID" : "") on \(wv.url?.path ?? "")")
            switch r.keys.count {
            case 0:
                ToastCenter.shared.show("No API key found on this page. Open the page that shows it (usually Account, Profile or Settings), then tap Find Key on Page.", style: .error)
            case 1:
                deliver(r.keys[0], r.userID)
            default:
                choices = r
            }
        }
    }

    func deliver(_ key: KeyFinder.Found, _ user: KeyFinder.Found?) {
        onFindKey?(key, user)
        dismiss()
        ToastCenter.shared.show(user != nil ? "API key and user ID found and filled in." : "API key found and filled in.", style: .success)
    }

    func copySelection() {
        model.webView?.evaluateJavaScript("window.getSelection().toString()") { result, _ in
            let text = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                ToastCenter.shared.show("Highlight the text first (press and hold on it), then tap Copy Selection.", style: .error)
            } else {
                UIPasteboard.general.string = text
                ToastCenter.shared.show("Copied \(text.count) characters. Paste them into the form.", style: .success)
            }
        }
    }
}

private struct ThemedWebView: UIViewRepresentable {
    let url: URL
    let prefillUsername: String?
    let model: ThemedWebPage.Model

    func makeCoordinator() -> Coordinator { Coordinator(model: model, prefill: prefillUsername) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Theme CSS is injected as early as possible so the page never flashes unstyled.
        let js = "var s=document.createElement('style');s.textContent=\(Self.jsString(ThemePalette.css));(document.head||document.documentElement).appendChild(s);"
        config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.accessibilityIdentifier = "themedWebPage"
        model.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: ThemedWebPage.Model
        let prefill: String?
        init(model: ThemedWebPage.Model, prefill: String?) { self.model = model; self.prefill = prefill }

        func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
            model.title = wv.title ?? ""
            // Only fills in the username the user typed in the app, nothing is read back.
            if let name = prefill?.nonEmpty {
                let js = "var u=document.querySelector('input[name=username],input[name=user],input[name=login]');if(u&&!u.value){u.value=\(ThemedWebView.jsString(name));}"
                wv.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
}
