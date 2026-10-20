import UIKit
import UniformTypeIdentifiers

/// "MediaDeck" in the share sheet: puts the shared link or picture into the app group's
/// inbox and opens MediaDeck, which then opens the link on the matching site or offers a
/// reverse search for the picture.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "Sending to MediaDeck…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handle() }
    }

    private func handle() async {
        guard let inbox = AppGroup.inbox else {
            finish("MediaDeck can't receive shared items on this device (no shared folder).")
            return
        }
        var saved = 0
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if await save(provider, to: inbox) { saved += 1 }
            }
        }
        if saved == 0 {
            finish("Nothing MediaDeck can use was shared. Share a link or a picture.")
            return
        }
        label.text = "Sent to MediaDeck"
        openApp(URL(string: "mediadeck://inbox")!)
        try? await Task.sleep(nanoseconds: 600_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func save(_ p: NSItemProvider, to inbox: URL) async -> Bool {
        let name = UUID().uuidString
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let item = try? await p.loadItem(forTypeIdentifier: UTType.image.identifier)
            var data: Data?
            var ext = "jpg"
            if let url = item as? URL {
                data = try? Data(contentsOf: url)
                ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
            } else if let d = item as? Data {
                data = d
            } else if let img = item as? UIImage {
                data = img.jpegData(compressionQuality: 0.95)
            }
            guard let d = data else { return false }
            return (try? d.write(to: inbox.appendingPathComponent("\(name).\(ext)"))) != nil
        }
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
            return write(url.absoluteString, name: name, to: inbox)
        }
        if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
           let link = Self.firstLink(in: text) {
            return write(link, name: name, to: inbox)
        }
        return false
    }

    private func write(_ link: String, name: String, to inbox: URL) -> Bool {
        (try? link.write(to: inbox.appendingPathComponent("\(name).link"), atomically: true, encoding: .utf8)) != nil
    }

    static func firstLink(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url?.absoluteString
    }

    private func finish(_ message: String) {
        label.text = message
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Extensions can't call UIApplication.shared; find the application object in the
    /// responder chain and ask it to open MediaDeck. If that isn't possible, the item still
    /// waits in the inbox and appears the next time MediaDeck opens.
    private func openApp(_ url: URL) {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let r = responder {
            if r.responds(to: selector), r.isKind(of: NSClassFromString("UIApplication")!) {
                typealias OpenFn = @convention(c) (AnyObject, Selector, URL, NSDictionary, Any?) -> Void
                let fn = unsafeBitCast(r.method(for: selector), to: OpenFn.self)
                fn(r, selector, url, NSDictionary(), nil)
                return
            }
            responder = r.next
        }
    }
}
