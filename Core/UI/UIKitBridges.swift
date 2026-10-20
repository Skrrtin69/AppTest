import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Presents UIKit controllers (share sheet, document picker) from anywhere,
/// on top of whatever is currently showing (including sheets and full-screen covers).
enum Presenter {
    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    static func present(_ vc: UIViewController) {
        DispatchQueue.main.async {
            guard let top = topController() else { return }
            if let pop = vc.popoverPresentationController {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            top.present(vc, animated: true)
        }
    }

    static func share(_ items: [Any]) {
        present(UIActivityViewController(activityItems: items, applicationActivities: nil))
    }

    /// Lets the user save copies of `urls` anywhere in the Files app.
    static func exportToFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        present(picker)
    }

    /// Lets the user pick a file in the Files app; `completion` receives a readable local copy.
    static func importFile(types: [UTType], completion: @escaping (URL) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        let delegate = PickerDelegate(completion: completion)
        picker.delegate = delegate
        // Keep the delegate alive as long as the picker.
        objc_setAssociatedObject(picker, &PickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        present(picker)
    }

    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        static var key = 0
        let completion: (URL) -> Void
        init(completion: @escaping (URL) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let u = urls.first else { return }
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            completion(u)
        }
    }

    /// Writes `data` to a temp file with `name` and offers to save it to Files.
    static func exportData(_ data: Data, filename: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            exportToFiles([url])
        } catch {
            ToastCenter.shared.error(error, prefix: "Export failed")
        }
    }
}

enum Keyboard {
    /// Hides the keyboard whichever field has focus.
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension View {
    /// Adds a "Done" button above the keyboard that just hides it (forms never lose data).
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { Keyboard.dismiss() }.font(.body.weight(.semibold))
            }
        }
    }

    /// Applies the AMOLED/system background behind scrolling content.
    func themedBackground() -> some View {
        modifier(ThemedBackground())
    }
}

struct ThemedBackground: ViewModifier {
    @ObservedObject var settings = AppSettings.shared
    func body(content: Content) -> some View {
        content.background(background.ignoresSafeArea())
    }

    var background: Color {
        if let c = settings.theme.custom { return Color(hex: c.background) }
        return settings.theme == .amoled ? Color.black : Color(UIColor.systemBackground)
    }
}
