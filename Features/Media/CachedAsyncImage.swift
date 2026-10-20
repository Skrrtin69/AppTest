import SwiftUI
import UIKit

/// Loads an image through ImagePipeline (memory → disk → network). GIFs animate.
struct CachedAsyncImage: View {
    let url: URL
    var maxPixel: CGFloat = 0
    var animate: Bool = true
    var contentMode: UIView.ContentMode = .scaleAspectFill
    var client: NetworkClient? = nil
    var onLoad: ((UIImage) -> Void)? = nil

    @StateObject private var model = ImageLoadModel()

    var body: some View {
        ZStack {
            if let img = model.image {
                AnimatedImageView(image: img, contentMode: contentMode)
            } else if let err = model.error {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Tap to retry").font(.caption2)
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.load(url, maxPixel: maxPixel, animate: animate, client: client, onLoad: onLoad, force: true) } }
                .accessibilityLabel("Image failed: \(err)")
            } else {
                Color.gray.opacity(0.15)
                    .overlay(ProgressView())
            }
        }
        // Also reloads when animation is switched (e.g. Battery Saver) so GIFs stop or start.
        .task(id: "\(url.absoluteString)|\(animate)") {
            await model.load(url, maxPixel: maxPixel, animate: animate, client: client, onLoad: onLoad)
        }
        // Off-screen cells drop their image so long sessions don't pile up memory;
        // it comes back from the caches when the cell reappears.
        .onDisappear { model.release() }
    }
}

@MainActor
final class ImageLoadModel: ObservableObject {
    @Published var image: UIImage?
    @Published var error: String?
    private var loadedURL: URL?
    private var loadedAnimate: Bool?

    func load(_ url: URL, maxPixel: CGFloat, animate: Bool, client: NetworkClient?,
              onLoad: ((UIImage) -> Void)?, force: Bool = false) async {
        if !force, loadedURL == url, loadedAnimate == animate, image != nil { return }
        if loadedURL != url { image = nil }
        error = nil
        // Fast-scroll throttle: a cell that scrolls past within 150 ms is cancelled (this task
        // ends when the cell disappears) before it costs a network request.
        if !ImagePipeline.shared.isInMemory(url, maxPixel: maxPixel, animate: animate) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
        }
        do {
            let img = try await ImagePipeline.shared.image(for: url, maxPixel: maxPixel, animate: animate, client: client)
            guard !Task.isCancelled else { return }
            image = img
            loadedURL = url
            loadedAnimate = animate
            onLoad?(img)
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func release() {
        image = nil
        loadedURL = nil
    }
}

/// UIImageView wrapper: SwiftUI's Image can't play animated UIImages.
struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    var contentMode: UIView.ContentMode = .scaleAspectFill

    final class Container: UIView {
        let imageView = UIImageView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            imageView.frame = bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.clipsToBounds = true
            addSubview(imageView)
        }
        required init?(coder: NSCoder) { fatalError() }
        // No intrinsic size, so SwiftUI decides the frame.
        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
    }

    func makeUIView(context: Context) -> Container {
        let c = Container()
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        c.setContentHuggingPriority(.defaultLow, for: .vertical)
        c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        c.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return c
    }

    func updateUIView(_ c: Container, context: Context) {
        c.imageView.contentMode = contentMode
        if c.imageView.image !== image {
            c.imageView.image = image
            if image.images != nil { c.imageView.startAnimating() }
        }
    }
}
