import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

/// Sets the system volume. iOS only allows this through MPVolumeView's slider, so a tiny
/// off-screen MPVolumeView is kept in the key window.
final class SystemVolume {
    static let shared = SystemVolume()
    private let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))

    var current: Float { AVAudioSession.sharedInstance().outputVolume }

    func set(_ value: Float) {
        if view.superview == nil {
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }.first { $0.isKeyWindow }
            window?.addSubview(view)
        }
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = min(1, max(0, value))
        slider.sendActions(for: .valueChanged)
    }
}

/// What a vertical drag in the viewer is doing, decided from where it started.
enum ViewerDragMode { case none, dismiss, brightness, volume, other }

/// Edge-swipe level indicator (brightness / volume).
struct LevelHUD: View {
    let icon: String
    let level: Double
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2)
            ProgressView(value: level).frame(width: 110).tint(.white)
            Text("\(Int(level * 100))%").font(.caption.monospacedDigit())
        }
        .foregroundColor(.white)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.65)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("levelHUD")
    }
}

/// Posts stacked top to bottom for comic/webtoon-style reading. Videos show as a still with
/// a play badge; tapping one opens it in the normal paged viewer.
struct VerticalReader: View {
    let posts: [Post]
    let startIndex: Int
    @Binding var index: Int
    var onOpenPaged: (Int) -> Void
    var onTap: () -> Void

    /// Every row: galleries are expanded into their pages; `post` is the index in `posts`.
    private var rows: [(id: Int, post: Int, item: Post)] {
        var out: [(Int, Int, Post)] = []
        for (i, p) in posts.enumerated() {
            if p.isGallery {
                for n in 0..<(p.pages?.count ?? 0) { out.append((out.count, i, p.page(n))) }
            } else {
                out.append((out.count, i, p))
            }
        }
        return out
    }

    var body: some View {
        let rows = self.rows
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows, id: \.id) { row in
                        VerticalItem(post: row.item)
                            .id("post-\(row.post)-\(row.item.id)")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: RowTops.self, value: [row.id: g.frame(in: .named("vertical")).minY])
                            })
                            .onTapGesture {
                                if row.item.mediaType == .video { onOpenPaged(row.post) } else { onTap() }
                            }
                    }
                }
            }
            .coordinateSpace(name: "vertical")
            // The counter follows the row at the top third of the screen, not rows that are
            // merely preloaded below it.
            .onPreferenceChange(RowTops.self) { tops in
                let line = UIScreen.main.bounds.height / 3
                if let row = tops.filter({ $0.value <= line }).max(by: { $0.value < $1.value })?.key,
                   rows.indices.contains(row), rows[row].post != index {
                    index = rows[row].post
                }
            }
            .onAppear {
                if let first = rows.first(where: { $0.post == startIndex }) {
                    proxy.scrollTo("post-\(first.post)-\(first.item.id)", anchor: .top)
                }
            }
        }
        .accessibilityIdentifier("verticalReader")
    }
}

/// Each row's top edge in the reader, keyed by post index.
struct RowTops: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

struct VerticalItem: View {
    let post: Post
    @StateObject private var model = ImageLoadModel()

    var body: some View {
        Group {
            if post.mediaType == .video {
                ZStack {
                    CachedAsyncImage(url: post.thumbnailURL, maxPixel: 900, contentMode: .scaleAspectFit)
                        .aspectRatio(post.pixelSize.map { $0.width / $0.height } ?? 4 / 3, contentMode: .fit)
                    Image(systemName: "play.circle.fill").font(.system(size: 54)).foregroundColor(.white.opacity(0.85))
                }
            } else if let img = model.image {
                AnimatedImageView(image: img, contentMode: .scaleAspectFit)
                    .aspectRatio(img.size.width / max(img.size.height, 1), contentMode: .fit)
            } else {
                Color.gray.opacity(0.15)
                    .aspectRatio(post.pixelSize.map { $0.width / $0.height } ?? 1, contentMode: .fit)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(post.mediaType.label) \(post.id)")
        .task(id: post.mediaURL) {
            guard post.mediaType != .video else { return }
            // Downsampled to screen width: a full-resolution long strip could exhaust memory.
            await model.load(post.mediaURL, maxPixel: 1600, animate: true,
                             client: AdapterRegistry.shared.adapter(for: post.siteID)?.client, onLoad: nil)
        }
        .onDisappear { model.release() }
    }
}

/// A multi-page post in the paged viewer: its pages stacked top to bottom, with a
/// "3 / 24" counter. Tall strips are decoded at screen width (see ImagePipeline).
struct GalleryPage: View {
    let post: Post
    let isActive: Bool
    var onTap: () -> Void
    var onFinished: () -> Void = {}
    @State private var current = 0
    @State private var showCounter = true
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let pages = post.pages ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(pages.indices, id: \.self) { i in
                        VerticalItem(post: post.page(i))
                            .id(i)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: RowTops.self, value: [i: g.frame(in: .named("gallery")).minY])
                            })
                    }
                    Text("End of gallery · \(pages.count) pages")
                        .font(.footnote).foregroundColor(.white.opacity(0.7))
                        .padding(.vertical, 40)
                        .onAppear { if isActive && settings.autoAdvance { onFinished() } }
                }
            }
            .coordinateSpace(name: "gallery")
            .onPreferenceChange(RowTops.self) { tops in
                let line = UIScreen.main.bounds.height / 3
                if let c = tops.filter({ $0.value <= line }).max(by: { $0.value < $1.value })?.key, c != current {
                    current = c
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .overlay(alignment: .bottom) {
                if isActive {
                    HStack(spacing: 14) {
                        Button { withAnimation { proxy.scrollTo(0, anchor: .top) } } label: { Image(systemName: "arrow.up.to.line") }
                            .accessibilityLabel("First page")
                        Text("\(current + 1) / \(pages.count)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .accessibilityIdentifier("galleryCounter")
                            .accessibilityLabel("Page \(current + 1) of \(pages.count)")
                        Button { withAnimation { proxy.scrollTo(pages.count - 1, anchor: .top) } } label: { Image(systemName: "arrow.down.to.line") }
                            .accessibilityLabel("Last page")
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(.bottom, 90)
                }
            }
        }
        .accessibilityIdentifier("galleryReader")
    }
}

/// Copies a post's picture (GIFs keep their animation) to the clipboard.
enum ImageClipboard {
    static func copy(_ post: Post) async {
        guard post.mediaType != .video else {
            ToastCenter.shared.show("Videos can't be copied as an image. Use Copy URL or Share.", style: .error)
            return
        }
        do {
            let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
            let data = try await ImagePipeline.shared.data(for: post.mediaURL, client: client)
            await MainActor.run {
                if ImagePipeline.isGIF(data) {
                    UIPasteboard.general.setData(data, forPasteboardType: "com.compuserve.gif")
                } else if let img = UIImage(data: data) {
                    UIPasteboard.general.image = img
                } else {
                    ToastCenter.shared.show("That file isn't an image that can be copied.", style: .error)
                    return
                }
                ToastCenter.shared.show("Image copied", style: .success)
            }
        } catch {
            ToastCenter.shared.error(error, prefix: "Couldn't copy image")
        }
    }
}

/// Long-press peek: a bigger preview above the context menu (iOS 16+; plain menu before).
struct PeekContextMenu<Menu: View>: ViewModifier {
    let post: Post
    @ViewBuilder var menu: () -> Menu

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.contextMenu(menuItems: menu) {
                CachedAsyncImage(url: post.sampleURL ?? post.thumbnailURL, maxPixel: 900, contentMode: .scaleAspectFit)
                    .frame(width: 320, height: 320 / max(0.4, min(2.5, post.pixelSize.map { $0.width / $0.height } ?? 1)))
                    .background(Color.black)
            }
        } else {
            content.contextMenu(menuItems: menu)
        }
    }
}
