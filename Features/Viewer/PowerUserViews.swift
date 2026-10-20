import SwiftUI
import UIKit
import CryptoKit

/// Viewer backdrop: black, white, a checkerboard (useful for transparent images), or a
/// dark version of the picture's own main color.
struct ViewerBackdrop: View {
    let style: String
    var color: UIColor? = nil
    var body: some View {
        switch style {
        case "white": Color.white
        case "checker": Color(UIColor(patternImage: Self.checker))
        case "color": Color(color ?? .black).animation(.easeInOut(duration: 0.35), value: color)
        default: Color.black
        }
    }

    static let checker: UIImage = {
        let size: CGFloat = 16
        return UIGraphicsImageRenderer(size: CGSize(width: size * 2, height: size * 2)).image { ctx in
            UIColor(white: 0.85, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size * 2, height: size * 2))
            UIColor(white: 0.65, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.fill(CGRect(x: size, y: size, width: size, height: size))
        }
    }()
}

/// The average color of each viewed picture, darkened so white controls stay readable.
final class DominantColors: ObservableObject {
    static let shared = DominantColors()
    @Published private(set) var colors: [String: UIColor] = [:]

    func compute(for key: String, image: UIImage) {
        guard colors[key] == nil, AppSettings.shared.viewerBackground == "color", let cg = image.cgImage else { return }
        DispatchQueue.global(qos: .utility).async {
            // Draw into 1×1 pixel: the GPU averages the whole picture.
            var px = [UInt8](repeating: 0, count: 4)
            guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let dim: CGFloat = 0.45
            let c = UIColor(red: CGFloat(px[0]) / 255 * dim, green: CGFloat(px[1]) / 255 * dim,
                            blue: CGFloat(px[2]) / 255 * dim, alpha: 1)
            DispatchQueue.main.async {
                if self.colors.count > 300 { self.colors.removeAll() }
                self.colors[key] = c
            }
        }
    }
}

/// Swipe up in the viewer (or ⋯ › Hide Posts Like This): blacklist one of the post's tags or
/// mute its uploader, with Undo.
struct QuickHideSheet: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        NavigationView {
            List {
                if let u = post.uploader {
                    Section("Uploader") {
                        Button { add("uploader:" + u.lowercased(), label: "Muted \(u)") } label: {
                            Label("Mute \(u)", systemImage: "person.crop.circle.badge.xmark")
                        }
                        .disabled(settings.blacklistSet.contains("uploader:" + u.lowercased()))
                    }
                }
                Section {
                    if post.tags.isEmpty { Text("This post has no tags.").foregroundColor(.secondary) }
                    ForEach(post.tags, id: \.self) { tag in
                        let hidden = settings.blacklistSet.contains(tag.lowercased())
                        Button { add(tag.lowercased(), label: "Hiding posts tagged \(tag)") } label: {
                            HStack {
                                Circle().fill(TagColors.color(for: post.tagCategories?[tag])).frame(width: 8, height: 8)
                                Text(tag).foregroundColor(hidden ? .secondary : .primary)
                                Spacer()
                                if hidden { Image(systemName: "checkmark").foregroundColor(.secondary) }
                            }
                        }
                        .disabled(hidden)
                    }
                } header: { Text("Hide every post tagged…") } footer: {
                    Text("Hidden tags and muted uploaders are listed in Settings › Tag Blacklist, where you can remove them.")
                }
            }
            .navigationTitle("Hide Posts Like This")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    func add(_ entry: String, label: String) {
        guard !settings.blacklist.contains(entry) else { return }
        settings.blacklist.append(entry)
        Haptics.success()
        ToastCenter.shared.show(label, style: .success, actionTitle: "Undo") {
            AppSettings.shared.blacklist.removeAll { $0 == entry }
        }
    }
}

/// Hides the home indicator together with the viewer's controls (iOS 16+).
struct HideHomeIndicator: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.persistentSystemOverlays(hidden ? .hidden : .automatic)
        } else {
            content
        }
    }
}

/// Stable colors for tag categories; common ones get fixed, recognisable colors.
enum TagColors {
    static func color(for category: String?) -> Color {
        guard let c = category?.lowercased(), !c.isEmpty else { return .accentColor }
        switch c {
        case "artist", "creator": return .orange
        case "character": return .green
        case "copyright", "series": return .purple
        case "meta": return .gray
        case "general": return .accentColor
        default:
            // A fixed set of clearly different colors (hashed hues can land too close together).
            let palette: [Color] = [.pink, .teal, .indigo, .yellow, .mint, .brown, .cyan, .red]
            let hash = c.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
            return palette[hash % palette.count]
        }
    }
}

/// Copy MD5: the site's own hash when it provides one, otherwise computed from the file.
enum HashCopier {
    static func copyMD5(_ post: Post) async {
        if let h = post.metadata.first(where: { ["md5", "hash", "checksum"].contains($0.key.lowercased()) })?.value {
            await MainActor.run { UIPasteboard.general.string = h; ToastCenter.shared.show("MD5 copied (\(h.prefix(8))…)") }
            return
        }
        do {
            let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
            let data = try await ImagePipeline.shared.data(for: post.mediaURL, client: client)
            let hex = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            await MainActor.run { UIPasteboard.general.string = hex; ToastCenter.shared.show("MD5 copied (\(hex.prefix(8))…)", style: .success) }
        } catch {
            ToastCenter.shared.error(error, prefix: "Couldn't compute MD5")
        }
    }
}
