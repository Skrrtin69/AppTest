import SwiftUI
import UIKit
import CryptoKit

/// Viewer backdrop: black, white, or a checkerboard (useful for transparent images).
struct ViewerBackdrop: View {
    let style: String
    var body: some View {
        switch style {
        case "white": Color.white
        case "checker": Color(UIColor(patternImage: Self.checker))
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
