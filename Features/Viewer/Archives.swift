import SwiftUI
import UIKit

/// Save a gallery as a comic archive (.cbz = a ZIP of numbered pages), keeping each page's
/// own file type, and hand it to Files.
@MainActor
enum CBZExporter {
    static func export(_ post: Post) async {
        guard let pages = post.pages, !pages.isEmpty else {
            ToastCenter.shared.show("This post has no pages to save.", style: .error)
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cbz-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
        let width = max(3, String(pages.count).count)
        var entries: [ZipWriter.Entry] = []
        var failed = 0
        for (i, url) in pages.enumerated() {
            ToastCenter.shared.show("Saving page \(i + 1) of \(pages.count)…")
            do {
                let data = try await ImagePipeline.shared.data(for: url, client: client)
                guard !data.isEmpty else { failed += 1; continue }
                let ext = fileExtension(url: url, data: data)
                let name = String(repeating: "0", count: max(0, width - String(i + 1).count)) + "\(i + 1).\(ext)"
                let file = dir.appendingPathComponent(name)
                try data.write(to: file)
                entries.append(ZipWriter.Entry(name: name, url: file))
            } catch {
                failed += 1
                DebugLog.log("CBZ", "page \(i + 1): \(error.localizedDescription)")
            }
        }
        guard !entries.isEmpty else {
            ToastCenter.shared.show("Couldn't download any page of this gallery.", style: .error)
            return
        }
        let safe = "\(AdapterRegistry.shared.displayName(for: post.siteID))_\(post.id)"
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).cbz")
        do {
            try? FileManager.default.removeItem(at: out)
            try ZipWriter.write(entries, to: out)
            try? FileManager.default.removeItem(at: dir)
            // A copy stays in the app (Downloads/Archives), available over Wi-Fi Transfer.
            let keep = DownloadManager.root.appendingPathComponent("Archives", isDirectory: true)
            try? FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: keep.appendingPathComponent(out.lastPathComponent))
            try? FileManager.default.copyItem(at: out, to: keep.appendingPathComponent(out.lastPathComponent))
            ToastCenter.shared.show(failed == 0 ? "\(entries.count) pages packed. Choose where to save it."
                                    : "\(entries.count) pages packed, \(failed) couldn't be downloaded.",
                                    style: failed == 0 ? .success : .error)
            Presenter.exportFile(out)
        } catch {
            ToastCenter.shared.error(error, prefix: "Couldn't create the archive")
        }
    }

    /// The page's own type: from its address, else from the first bytes of the file.
    static func fileExtension(url: URL, data: Data) -> String {
        let known = ["jpg", "jpeg", "png", "gif", "webp", "avif", "bmp", "heic"]
        let e = url.pathExtension.lowercased()
        if known.contains(e) { return e == "jpeg" ? "jpg" : e }
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return "jpg"
    }
}

enum ExternalArchive {
    /// The adapter's externalArchiveURL with {id} filled in, or nil when none is set up.
    static func url(for post: Post) -> URL? {
        guard let t = AdapterRegistry.shared.config(for: post.siteID)?.externalArchiveURL?.nonEmpty else { return nil }
        let id = post.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? post.id
        return URL(string: t.replacingOccurrences(of: "{id}", with: id))
    }
}
