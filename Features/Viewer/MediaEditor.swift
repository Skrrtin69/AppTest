import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// A simple picture editor: rotate, flip, crop to a shape, brightness / contrast /
/// saturation. The original is never changed; the result is shared, saved to Photos or
/// saved to Files.
struct MediaEditorView: View {
    let post: Post
    /// Edit this picture instead of loading the post's file (e.g. a grabbed video frame).
    var initialImage: UIImage? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var source: UIImage?
    @State private var preview: UIImage?
    @State private var rotation = 0          // quarter turns clockwise
    @State private var flipped = false
    @State private var crop: CropShape = .original
    @State private var brightness = 0.0
    @State private var contrast = 1.0
    @State private var saturation = 1.0
    /// Export size: 1× (original), 2× or 3× (Lanczos upscaling plus light sharpening).
    @State private var upscale = 1
    @State private var error: String?
    /// The source shrunk once to preview size: sliders re-render this, not the full picture.
    @State private var previewBase: UIImage?
    /// The newest preview request; older ones finishing late are dropped.
    @State private var renderGen = 0
    @State private var rendering = false
    @State private var exporting = false

    /// Everything the edit needs, as a value, so it can be rendered off the main thread.
    struct Edits {
        var rotation: Int, flipped: Bool, crop: CGFloat?, brightness: Double, contrast: Double, saturation: Double, upscale: Int
        static let identity = Edits(rotation: 0, flipped: false, crop: nil, brightness: 0, contrast: 1, saturation: 1, upscale: 1)
    }
    var edits: Edits {
        Edits(rotation: rotation, flipped: flipped, crop: crop.ratio, brightness: brightness,
              contrast: contrast, saturation: saturation, upscale: upscale)
    }

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
                    Picker("Size when saved", selection: $upscale) {
                        Text("Original").tag(1); Text("2× larger").tag(2); Text("3× larger").tag(3)
                    }
                    .accessibilityIdentifier("editorUpscale")
                    if let size = outputSize {
                        Text("Saved size: \(Int(size.width)) × \(Int(size.height))").font(.footnote).foregroundColor(.secondary)
                            .accessibilityIdentifier("editorOutputSize")
                    }
                    Button("Reset") { rotation = 0; flipped = false; crop = .original; brightness = 0; contrast = 1; saturation = 1; upscale = 1 }
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

    /// Size of the saved picture: the preview's shape at the source's resolution × upscale
    /// (never above 8192 px on the long side).
    var outputSize: CGSize? {
        guard let s = source?.cgImage, let p = preview else { return nil }
        let long = CGFloat(max(s.width, s.height)) * CGFloat(upscale)
        let r = p.size.width / max(p.size.height, 1)
        var w = r >= 1 ? long : long * r, h = r >= 1 ? long / r : long
        let cap = min(1, 8192 / max(w, h)); w *= cap; h *= cap
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    var settingsKey: String { "\(rotation)-\(flipped)-\(crop.rawValue)-\(brightness)-\(contrast)-\(saturation)" }

    func slider(_ title: String, _ b: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Slider(value: b, in: range).accessibilityLabel(title)
        }
    }

    func loadSource() async {
        if let i = initialImage { source = i; renderPreview(); return }
        do {
            let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
            let img = try await ImagePipeline.shared.image(for: post.mediaURL, maxPixel: 4096, animate: false, client: client)
            source = img
            renderPreview()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Applies every edit to a CIImage. Safe to call off the main thread.
    static func edited(_ img: UIImage, maxSide: CGFloat?, _ e: Edits) -> UIImage? {
        let flipped = e.flipped, rotation = e.rotation, brightness = e.brightness
        let contrast = e.contrast, saturation = e.saturation, upscale = e.upscale
        guard let cg = img.cgImage else { return nil }
        var ci = CIImage(cgImage: cg)
        if let m = maxSide {
            let s = min(1, m / max(ci.extent.width, ci.extent.height))
            ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        if flipped { ci = ci.oriented(.upMirrored) }
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        ci = ci.oriented(orientations[rotation])
        if let r = e.crop {
            let x = ci.extent
            var w = x.width, h = x.width / r
            if h > x.height { h = x.height; w = h * r }
            ci = ci.cropped(to: CGRect(x: x.midX - w / 2, y: x.midY - h / 2, width: w, height: h))
        }
        let f = CIFilter.colorControls()
        f.inputImage = ci
        f.brightness = Float(brightness)
        f.contrast = Float(contrast)
        f.saturation = Float(saturation)
        guard var out = f.outputImage else { return nil }
        // Upscaling (saved file only; the preview stays small): Lanczos resampling, then a
        // little sharpening to offset the softness of enlarging.
        if maxSide == nil, upscale > 1 {
            let long = max(out.extent.width, out.extent.height)
            let scale = min(CGFloat(upscale), 8192 / long)
            let l = CIFilter.lanczosScaleTransform()
            l.inputImage = out; l.scale = Float(scale); l.aspectRatio = 1
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = l.outputImage; sharpen.sharpness = 0.4
            if let up = sharpen.outputImage { out = up.cropped(to: up.extent.integral) }
        }
        guard let rendered = Self.context.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }

    /// One render at a time: slider ticks arriving meanwhile only mark the preview as out
    /// of date, and the newest settings are rendered when the current one finishes.
    func renderPreview() {
        guard source != nil else { return }
        renderGen += 1
        guard !rendering else { return }
        rendering = true
        runRender()
    }

    private func runRender() {
        guard let s = source else { rendering = false; return }
        let gen = renderGen, base = previewBase
        var e = edits
        e.upscale = 1
        Task {
            let out = await Task.detached(priority: .userInitiated) { () -> (base: UIImage?, preview: UIImage?) in
                let b = base ?? Self.edited(s, maxSide: 900, .identity)
                return (b, b.flatMap { Self.edited($0, maxSide: nil, e) })
            }.value
            if previewBase == nil { previewBase = out.base }
            if let img = out.preview { preview = img }
            // Settings moved on while this ran: render the newest ones next.
            if gen != renderGen { runRender() } else { rendering = false }
        }
    }

    enum Destination { case share, photos, files }

    func export(_ d: Destination) {
        guard let s = source, !exporting else { return }
        exporting = true
        let e = edits
        if e.upscale > 1 { ToastCenter.shared.show("Preparing the enlarged picture…") }
        Task {
            // Full-size editing (and upscaling) and JPEG encoding take seconds on big pictures.
            let result = await Task.detached(priority: .userInitiated) { () -> (UIImage, Data)? in
                guard let full = Self.edited(s, maxSide: nil, e), let data = full.jpegData(compressionQuality: 0.92) else { return nil }
                return (full, data)
            }.value
            exporting = false
            guard let (full, data) = result else {
                ToastCenter.shared.show("Couldn't create the edited picture.", style: .error)
                return
            }
            deliver(d, full: full, data: data)
        }
    }

    func deliver(_ d: Destination, full: UIImage, data: Data) {
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

/// A frame grabbed from a video: share, save or edit it.
struct FrameGrabView: View {
    let image: UIImage
    let time: Double
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    var stand_in: Post {
        Post(id: "frame-\(Int(time * 1000))", siteID: "video", thumbnailURL: URL(fileURLWithPath: "/"),
             mediaURL: URL(fileURLWithPath: "/"), mediaType: .image, tags: [], sourceURL: nil, metadata: [:])
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 380)
                    .accessibilityIdentifier("grabbedFrame")
                Text("\(image.cgImage?.width ?? 0) × \(image.cgImage?.height ?? 0)").font(.footnote).foregroundColor(.secondary)
                HStack(spacing: 12) {
                    Button { Presenter.share([image]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    Button {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        ToastCenter.shared.show("Saved to Photos", style: .success)
                    } label: { Label("Photos", systemImage: "photo") }
                    Button {
                        if let d = image.pngData() { Presenter.exportData(d, filename: "frame-\(Int(time * 1000)).png") }
                    } label: { Label("Files", systemImage: "folder") }
                }
                .buttonStyle(.bordered)
                Button { editing = true } label: { Label("Edit", systemImage: "slider.horizontal.below.rectangle") }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
            .navigationTitle(String(format: "Frame at %d:%02d", Int(time) / 60, Int(time) % 60))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $editing) { MediaEditorView(post: stand_in, initialImage: image) }
        }
    }
}
