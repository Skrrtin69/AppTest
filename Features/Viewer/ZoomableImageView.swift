import SwiftUI
import UIKit

/// UIScrollView-based zoom: pinch, double-tap to zoom in/out, pan while zoomed.
/// At 1x the inner scroll view can't scroll horizontally, so swipes fall through to the
/// pager and move between posts.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var onZoomChange: ((Bool) -> Void)? = nil
    var onSingleTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.delegate = context.coordinator
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 6
        sv.bouncesZoom = true
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .clear
        sv.accessibilityIdentifier = "zoomScrollView"

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = true
        sv.addSubview(iv)
        context.coordinator.imageView = iv

        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        sv.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        sv.addGestureRecognizer(single)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.parent = self
        guard let iv = context.coordinator.imageView else { return }
        if iv.image !== image {
            iv.image = image
            if image.images != nil { iv.startAnimating() }
            sv.zoomScale = 1
        }
        DispatchQueue.main.async { context.coordinator.layout(sv) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImageView
        weak var imageView: UIImageView?
        private var lastBounds: CGSize = .zero
        private var wasZoomed = false

        init(_ p: ZoomableImageView) { parent = p }

        /// Sizes the image view to fit the scroll view at 1x.
        func layout(_ sv: UIScrollView) {
            guard let iv = imageView, sv.bounds.size != .zero else { return }
            if sv.zoomScale == 1, (lastBounds != sv.bounds.size || iv.frame.size == .zero || iv.frame.size != sv.bounds.size) {
                lastBounds = sv.bounds.size
                iv.frame = CGRect(origin: .zero, size: sv.bounds.size)
                sv.contentSize = sv.bounds.size
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ sv: UIScrollView) {
            let zoomed = sv.zoomScale > 1.01
            if zoomed != wasZoomed {
                wasZoomed = zoomed
                parent.onZoomChange?(zoomed)
            }
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            if sv.zoomScale > 1.01 {
                sv.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let scale: CGFloat = 3
                let size = CGSize(width: sv.bounds.width / scale, height: sv.bounds.height / scale)
                sv.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }

        @objc func singleTap() { parent.onSingleTap?() }
    }
}
