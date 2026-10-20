import SwiftUI
import UIKit

/// Opens a web address inside MediaDeck when it belongs to one of the user's sites:
/// a post address opens that post, a search address runs that search.
@MainActor
enum LinkRouter {
    /// The enabled site whose address (or media address) has this link's host.
    static func site(for url: URL) -> AdapterConfig? {
        guard let host = url.host?.lowercased() else { return nil }
        func strip(_ h: String) -> String { h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        let configs = AdapterRegistry.shared.enabledConfigs
        let matching = configs.filter { c in
            [c.baseURL, c.mediaBaseURL].compactMap { $0.host?.lowercased() }.contains { strip($0) == strip(host) }
        }
        // Several sites on one host (the demo server): prefer the one whose path matches too.
        return matching.max { a, b in
            commonPrefix(url.path, a.baseURL.path) < commonPrefix(url.path, b.baseURL.path)
        }
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    /// What a link asks for: a post ID or search words.
    static func target(of url: URL) -> (postID: String?, tags: String?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ names: [String]) -> String? { items.first { names.contains($0.name.lowercased()) }?.value?.nonEmpty }
        if let id = q(["id", "post_id", "postid"]) { return (id, nil) }
        if let tags = q(["tags", "tag", "q", "query", "search", "s"]) { return (nil, tags.replacingOccurrences(of: "+", with: " ")) }
        // The last part of the path that contains a number: /posts/123, /view/123, /item/b-12.json
        let parts = url.pathComponents.reversed().map { ($0 as NSString).deletingPathExtension }
        if let id = parts.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil && $0.count <= 40 }) { return (id, nil) }
        return (nil, nil)
    }

    /// Returns false when the link isn't for one of the user's sites (or says nothing useful).
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let site = site(for: url) else { return false }
        let t = target(of: url)
        guard let words = t.postID ?? t.tags else { return false }
        // Close the viewer and any sheet so the result is visible in Browse.
        let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow && !($0 is PassthroughWindow) }?.rootViewController
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first?.rootViewController
        if root?.presentedViewController != nil { root?.dismiss(animated: true) }
        AppRouter.shared.queueSearch(tags: words, siteName: site.id)
        ToastCenter.shared.show(t.postID != nil ? "Opening post \(words) on \(site.displayName)" : "Searching \(site.displayName) for \(words)")
        return true
    }
}

/// Notices a copied web link when the app comes to the front and offers to open it.
/// Only the *kind* of clipboard content is checked first, so iOS doesn't ask for paste
/// permission until the user taps Open.
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    private var lastChange = UserDefaults.standard.integer(forKey: "clipboardLastChange")

    func check() {
        guard AppSettings.shared.detectClipboardLinks else { return }
        let pb = UIPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        UserDefaults.standard.set(lastChange, forKey: "clipboardLastChange")
        pb.detectPatterns(for: [.probableWebURL]) { result in
            guard case .success(let found) = result, found.contains(.probableWebURL) else { return }
            Task { @MainActor in
                ToastCenter.shared.show("You copied a link. Open it in MediaDeck?", actionTitle: "Open") {
                    Task { @MainActor in self.openClipboard() }
                }
            }
        }
    }

    func openClipboard() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text) ?? UIPasteboard.general.url else { return }
        if !LinkRouter.open(url) {
            ToastCenter.shared.show("That link isn't from one of your sites.", style: .error)
        }
    }
}
