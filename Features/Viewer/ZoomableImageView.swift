import SwiftUI
import UIKit

/// UIScrollView-based zoom: pinch, double-tap to zoom in/out, pan while zoomed.
/// At 1x the inner scroll view can't scroll horizontally, so swipes fall through to the
/// pager and move between posts.
/// How an image is sized when not zoomed by hand.
enum ViewerAspect: String, CaseIterable {
    case fit, fill, original
    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .original: return "1:1"
        }
    }
    var next: ViewerAspect {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var aspect: ViewerAspect = .fit
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
            context.coordinator.appliedAspect = nil
        }
        DispatchQueue.main.async {
            context.coordinator.layout(sv)
            context.coordinator.apply(aspect, to: sv)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImageView
        weak var imageView: UIImageView?
        private var lastBounds: CGSize = .zero
        private var wasZoomed = false
        var appliedAspect: ViewerAspect?

        /// Zoom factor that makes the fitted image fill the screen, or show 1 image pixel per
        /// screen pixel. The image view itself always stays aspect-fit inside the scroll view.
        func scale(for aspect: ViewerAspect, in sv: UIScrollView) -> CGFloat {
            guard let img = imageView?.image, img.size.width > 0, img.size.height > 0, sv.bounds.width > 0 else { return 1 }
            let b = sv.bounds.size
            let fit = min(b.width / img.size.width, b.height / img.size.height)
            let fitted = CGSize(width: img.size.width * fit, height: img.size.height * fit)
            switch aspect {
            case .fit: return 1
            case .fill: return max(b.width / fitted.width, b.height / fitted.height)
            case .original:
                let pixelWidth = img.size.width * img.scale
                return max(0.1, (pixelWidth / UIScreen.main.scale) / fitted.width)
            }
        }

        func apply(_ aspect: ViewerAspect, to sv: UIScrollView) {
            guard appliedAspect != aspect, imageView?.image != nil, sv.bounds.width > 0 else { return }
            appliedAspect = aspect
            let s = scale(for: aspect, in: sv)
            sv.minimumZoomScale = min(1, s)
            sv.maximumZoomScale = max(6, s * 2)
            sv.setZoomScale(s, animated: true)
            // Center the enlarged image.
            let off = CGPoint(x: max(0, (sv.contentSize.width - sv.bounds.width) / 2),
                              y: max(0, (sv.contentSize.height - sv.bounds.height) / 2))
            sv.setContentOffset(off, animated: false)
        }

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
            let base = scale(for: appliedAspect ?? .fit, in: sv)
            if sv.zoomScale > base * 1.01 {
                sv.setZoomScale(base, animated: true)
            } else {
                // Zoom to exactly where the finger tapped: that point becomes the center.
                let p = g.location(in: imageView)
                let scale: CGFloat = max(3, base * 2.5)
                let size = CGSize(width: sv.bounds.width / scale, height: sv.bounds.height / scale)
                sv.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }

        @objc func singleTap() { parent.onSingleTap?() }
    }
}
