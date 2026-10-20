import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// A simple picture editor: rotate, flip, crop to a shape, brightness / contrast /
/// saturation. The original is never changed; the result is shared, saved to Photos or
/// saved to Files.
struct MediaEditorView: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @State private var source: UIImage?
    @State private var preview: UIImage?
    @State private var rotation = 0          // quarter turns clockwise
    @State private var flipped = false
    @State private var crop: CropShape = .original
    @State private var brightness = 0.0
    @State private var contrast = 1.0
    @State private var saturation = 1.0
    @State private var error: String?

    enum CropShape: String, CaseIterable, Identifiable {
        case original = "Original", square = "1:1", portrait = "4:5", wide = "16:9"
        var id: String { rawValue }
        var ratio: CGFloat? {
            switch self {
            case .original: return nil
            case .square: return 1
            case .portrait: return 4.0 / 5.0
            case .wide: return 16.0 / 9.0
            }
        }
    }

    private static let context = CIContext()

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                ZStack {
                    Color.black
                    if let p = preview {
                        Image(uiImage: p).resizable().scaledToFit()
                    } else if let e = error {
                        Text(e).foregroundColor(.white).padding()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxHeight: 360)
                .accessibilityIdentifier("editorPreview")

                HStack(spacing: 22) {
                    Button { rotation = (rotation + 3) % 4 } label: { Image(systemName: "rotate.left") }
                        .accessibilityLabel("Rotate left")
                    Button { rotation = (rotation + 1) % 4 } label: { Image(systemName: "rotate.right") }
                        .accessibilityLabel("Rotate right")
                    Button { flipped.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        .accessibilityLabel("Flip")
                    Picker("Crop", selection: $crop) {
                        ForEach(CropShape.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("editorCrop")
                }
                .font(.title3)

                Form {
                    slider("Brightness", $brightness, -0.5...0.5)
                    slider("Contrast", $contrast, 0.5...1.5)
                    slider("Saturation", $saturation, 0...2)
                    Button("Reset") { rotation = 0; flipped = false; crop = .original; brightness = 0; contrast = 1; saturation = 1 }
                }
            }
            .navigationTitle("Edit Picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button { export(.share) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        Button { export(.photos) } label: { Label("Save to Photos", systemImage: "photo") }
                        Button { export(.files) } label: { Label("Save to Files…", systemImage: "folder") }
                    } label: { Text("Save").bold() }
                    .disabled(source == nil)
                    .accessibilityIdentifier("editorSave")
                }
            }
            .task { await loadSource() }
            .onChange(of: settingsKey) { _ in renderPreview() }
        }
    }

    var settingsKey: String { "\(rotation)-\(flipped)-\(crop.rawValue)-\(brightness)-\(contrast)-\(saturation)" }

    func slider(_ title: String, _ b: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Slider(value: b, in: range).accessibilityLabel(title)
        }
    }

    func loadSource() async {
        do {
            let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
            let img = try await ImagePipeline.shared.image(for: post.mediaURL, maxPixel: 4096, animate: false, client: client)
            source = img
            renderPreview()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Applies every edit to a CIImage.
    func edited(_ img: UIImage, maxSide: CGFloat?) -> UIImage? {
        guard let cg = img.cgImage else { return nil }
        var ci = CIImage(cgImage: cg)
        if let m = maxSide {
            let s = min(1, m / max(ci.extent.width, ci.extent.height))
            ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        if flipped { ci = ci.oriented(.upMirrored) }
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        ci = ci.oriented(orientations[rotation])
        if let r = crop.ratio {
            let e = ci.extent
            var w = e.width, h = e.width / r
            if h > e.height { h = e.height; w = h * r }
            ci = ci.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h))
        }
        let f = CIFilter.colorControls()
        f.inputImage = ci
        f.brightness = Float(brightness)
        f.contrast = Float(contrast)
        f.saturation = Float(saturation)
        guard let out = f.outputImage, let rendered = Self.context.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }

    func renderPreview() {
        guard let s = source else { return }
        preview = edited(s, maxSide: 900)
    }

    enum Destination { case share, photos, files }

    func export(_ d: Destination) {
        guard let s = source, let full = edited(s, maxSide: nil), let data = full.jpegData(compressionQuality: 0.92) else {
            ToastCenter.shared.show("Couldn't create the edited picture.", style: .error)
            return
        }
        let name = "\(post.siteID)_\(post.id)_edited.jpg"
        switch d {
        case .share:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: url)
            Presenter.share([url])
        case .photos:
            UIImageWriteToSavedPhotosAlbum(full, nil, nil, nil)
            ToastCenter.shared.show("Saved to Photos", style: .success)
        case .files:
            Presenter.exportData(data, filename: name)
        }
    }
}
