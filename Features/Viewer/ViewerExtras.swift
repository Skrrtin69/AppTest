import SwiftUI
import CoreImage
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
                guard let first = rows.first(where: { $0.post == startIndex }) else { return }
                let target = "post-\(first.post)-\(first.item.id)"
                proxy.scrollTo(target, anchor: .top)
                // Rows above change height as their pictures load (tall strips especially),
                // which pushes the start post down; settle on it again shortly after.
                for delay in [0.4, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo(target, anchor: .top) }
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
    /// Show only the left (0) or right (1) half of the picture (split double pages).
    var half: Int? = nil
    /// Reports the picture's width ÷ height once it's loaded.
    var onRatio: ((CGFloat) -> Void)? = nil
    @StateObject private var model = ImageLoadModel()
    @State private var halfImage: UIImage?

    var body: some View {
        Group {
            if post.mediaType == .video {
                ZStack {
                    CachedAsyncImage(url: post.thumbnailURL, maxPixel: 900, contentMode: .scaleAspectFit)
                        .aspectRatio(post.pixelSize.map { $0.width / $0.height } ?? 4 / 3, contentMode: .fit)
                    Image(systemName: "play.circle.fill").font(.system(size: 54)).foregroundColor(.white.opacity(0.85))
                }
            } else if let img = half == nil ? model.image : halfImage {
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
        .accessibilityLabel("\(post.mediaType.label) \(post.id)\(half.map { $0 == 0 ? ", left half" : ", right half" } ?? "")")
        .task(id: "\(post.mediaURL.absoluteString)|\(half.map(String.init) ?? "-")") {
            guard post.mediaType != .video else { return }
            // Downsampled to screen width: a full-resolution long strip could exhaust memory.
            // A split page is loaded at double width so each half stays sharp.
            await model.load(post.mediaURL, maxPixel: half == nil ? 1600 : 3200, animate: half == nil,
                             client: AdapterRegistry.shared.adapter(for: post.siteID)?.client, onLoad: nil)
            if let img = model.image {
                onRatio?(img.size.width / max(img.size.height, 1))
                if let h = half { halfImage = Self.half(img, h) }
            }
        }
        .onDisappear { model.release(); halfImage = nil }
    }

    /// One vertical half of a picture, cut with Core Image.
    static func half(_ img: UIImage, _ side: Int) -> UIImage? {
        guard let cg = img.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        let w = ci.extent.width / 2
        let rect = CGRect(x: ci.extent.minX + (side == 0 ? 0 : w), y: ci.extent.minY, width: w, height: ci.extent.height)
        guard let out = CIContext().createCGImage(ci.cropped(to: rect), from: rect) else { return nil }
        return UIImage(cgImage: out)
    }
}

/// A multi-page post in the paged viewer: its pages stacked top to bottom, with a
/// "3 / 24" counter. Tall strips are decoded at screen width (see ImagePipeline). Wide
/// pages (double-page scans) can be split into two halves, and the place you stopped is
/// remembered.
struct GalleryPage: View {
    let post: Post
    let isActive: Bool
    var onTap: () -> Void
    var onFinished: () -> Void = {}
    @State private var current = 0
    @State private var ratios: [Int: CGFloat] = [:]
    @State private var offerResume: Int?
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var splits = SplitPages.shared

    struct Row: Hashable {
        let page: Int
        let half: Int?
        var id: String { "p\(page)-\(half.map(String.init) ?? "x")" }
    }

    var rows: [Row] {
        let pages = post.pages ?? []
        return pages.indices.flatMap { i -> [Row] in
            guard splits.isSplit(pages[i]) else { return [Row(page: i, half: nil)] }
            // Right-to-left books read the right half first.
            return settings.readingRTL ? [Row(page: i, half: 1), Row(page: i, half: 0)] : [Row(page: i, half: 0), Row(page: i, half: 1)]
        }
    }

    /// The split/join button sits on whole wide pages, and on the first half of a split one.
    func showsSplitButton(_ row: Row, firstRowOfPage: Bool) -> Bool {
        guard isActive, firstRowOfPage else { return false }
        return row.half != nil || (ratios[row.page] ?? 0) > 1.2
    }

    var body: some View {
        let pages = post.pages ?? []
        let rows = self.rows
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element) { n, row in
                        VerticalItem(post: post.page(row.page), half: row.half, onRatio: { r in
                            if row.half == nil { ratios[row.page] = r }
                        })
                        .id(row.id)
                        .overlay(alignment: .topTrailing) {
                            if showsSplitButton(row, firstRowOfPage: n == 0 || rows[n - 1].page != row.page) {
                                Button { splits.toggle(pages[row.page]); Haptics.tap() } label: {
                                    Label(row.half == nil ? "Split Spread" : "Join Pages",
                                          systemImage: row.half == nil ? "rectangle.split.2x1" : "rectangle")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .background(Capsule().fill(Color.black.opacity(0.6)))
                                        .foregroundColor(.white)
                                }
                                .padding(8)
                                .accessibilityIdentifier("splitSpread-\(row.page)")
                            }
                        }
                        .background(GeometryReader { g in
                            Color.clear.preference(key: RowTops.self, value: [row.page: g.frame(in: .named("gallery")).minY])
                        })
                    }
                    Text("End of gallery · \(pages.count) pages")
                        .font(.footnote).foregroundColor(.white.opacity(0.7))
                        .padding(.vertical, 40)
                        .onAppear {
                            ReadingProgress.shared.save(post.key, page: 0, total: pages.count)   // finished
                            if isActive && settings.autoAdvance { onFinished() }
                        }
                }
            }
            .coordinateSpace(name: "gallery")
            .onPreferenceChange(RowTops.self) { tops in
                let line = UIScreen.main.bounds.height / 3
                if let c = tops.filter({ $0.value <= line }).max(by: { $0.value < $1.value })?.key, c != current {
                    current = c
                    if c > 0 { offerResume = nil }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .overlay(alignment: .top) {
                if isActive, let page = offerResume {
                    Button {
                        withAnimation { proxy.scrollTo(rows.first { $0.page == page }?.id, anchor: .top) }
                        offerResume = nil
                    } label: {
                        Label("Continue Reading · page \(page + 1) of \(pages.count)", systemImage: "book")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundColor(.white)
                    }
                    .padding(.top, 110)
                    .accessibilityIdentifier("continueReading")
                }
            }
            .overlay(alignment: .bottom) {
                if isActive {
                    HStack(spacing: 14) {
                        Button { withAnimation { proxy.scrollTo(rows.first?.id, anchor: .top) } } label: { Image(systemName: "arrow.up.to.line") }
                            .accessibilityLabel("First page")
                        Text("\(current + 1) / \(pages.count)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .accessibilityIdentifier("galleryCounter")
                            .accessibilityLabel("Page \(current + 1) of \(pages.count)")
                        Button { withAnimation { proxy.scrollTo(rows.last?.id, anchor: .top) } } label: { Image(systemName: "arrow.down.to.line") }
                            .accessibilityLabel("Last page")
                        Button { Task { await CBZExporter.export(post) } } label: { Image(systemName: "archivebox") }
                            .accessibilityLabel("Save as CBZ")
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(.bottom, 90)
                }
            }
            .onAppear {
                if let m = ReadingProgress.shared.mark(post.key), m.page > 0, m.page < pages.count { offerResume = m.page }
            }
            .onDisappear {
                // Remember where reading stopped (cleared again at the end of the gallery).
                if current > 0 { ReadingProgress.shared.save(post.key, page: current, total: pages.count) }
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
