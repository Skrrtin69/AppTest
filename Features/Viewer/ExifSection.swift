import SwiftUI
import ImageIO

/// Camera and file details stored inside the picture (EXIF / TIFF / GPS), read with ImageIO
/// from the cached file. Shown in the Info panel.
struct ExifSection: View {
    let post: Post
    @State private var rows: [(String, String)]?
    @State private var hasLocation = false

    var body: some View {
        Section {
            if let r = rows {
                if r.isEmpty {
                    Text("No camera details in this file.").foregroundColor(.secondary)
                }
                ForEach(r, id: \.0) { row in
                    HStack(alignment: .top) {
                        Text(row.0)
                        Spacer()
                        Text(row.1).foregroundColor(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
                if hasLocation {
                    Label("This file contains the place where it was taken.", systemImage: "location.fill")
                        .font(.footnote).foregroundColor(.orange)
                }
            } else {
                HStack { ProgressView(); Text("Reading…").foregroundColor(.secondary) }
            }
        } header: { Text("Photo details (EXIF)") }
        .task(id: post.mediaURL) { await load() }
    }

    func load() async {
        guard post.mediaType != .video else { rows = []; return }
        let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
        guard let data = try? await ImagePipeline.shared.data(for: post.mediaURL, client: client) else { rows = []; return }
        let parsed = Self.parse(data)
        rows = parsed.rows
        hasLocation = parsed.location
    }

    static func parse(_ data: Data) -> (rows: [(String, String)], location: Bool) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return ([], false) }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        var out: [(String, String)] = []
        func add(_ label: String, _ v: Any?) {
            guard let v = v else { return }
            let s = "\(v)".trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append((label, s)) }
        }
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0 }.joined(separator: " ")
        if !camera.isEmpty { out.append(("Camera", camera)) }
        add("Lens", exif[kCGImagePropertyExifLensModel])
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            out.append(("Shutter", t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%.1f s", t)))
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { out.append(("Aperture", String(format: "f/%.1f", f))) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { out.append(("ISO", "\(iso)")) }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { out.append(("Focal length", String(format: "%.0f mm", fl))) }
        add("Taken", exif[kCGImagePropertyExifDateTimeOriginal] ?? tiff[kCGImagePropertyTIFFDateTime])
        add("Software", tiff[kCGImagePropertyTIFFSoftware])
        add("Artist", tiff[kCGImagePropertyTIFFArtist])
        add("Copyright", tiff[kCGImagePropertyTIFFCopyright])
        add("Description", tiff[kCGImagePropertyTIFFImageDescription])
        add("Color profile", props[kCGImagePropertyProfileName])
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 { out.append(("Resolution", "\(Int(dpi)) dpi")) }
        var location = false
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ns = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -1.0 : 1.0
            let ew = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -1.0 : 1.0
            out.append(("Location", String(format: "%.4f, %.4f", lat * ns, lon * ew)))
            location = true
        }
        return (out, location)
    }
}
