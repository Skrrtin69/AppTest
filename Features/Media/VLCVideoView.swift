import SwiftUI
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// Optional player for WebM/Matroska (Settings › Reading & Viewer › Use VLCKit for Video).
/// VLC decodes VP8/VP9/AV1/H.264 with native ARM code on several threads, which is much
/// faster than the WebAssembly decoder. Remote files go through the local /proxy, which adds
/// the site's headers and cookies.
struct VLCVideoView: View {
    let url: URL
    let isActive: Bool
    var siteID: String? = nil
    var speed: Double = 1
    var loop: Bool = true
    var showControls: Bool = true
    var onFinished: (() -> Void)? = nil
    var onReady: (() -> Void)? = nil
    var onError: ((String) -> Void)? = nil
    var onStatus: ((String) -> Void)? = nil

    @StateObject private var model = VLCPlayerModel()

    static var available: Bool {
        #if canImport(MobileVLCKit)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VLCSurface(model: model, url: Self.sourceURL(url, siteID: siteID))
                .contentShape(Rectangle())
                .onTapGesture { model.togglePause() }
            if showControls, model.duration > 0 {
                HStack(spacing: 10) {
                    Button { model.togglePause() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.body.weight(.semibold))
                    }
                    .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                    Slider(value: Binding(get: { Double(model.position) }, set: { model.seek(to: Float($0)) }), in: 0...1)
                        .accessibilityIdentifier("vlcScrubber")
                    Text(model.timeText).font(.caption.monospacedDigit())
                }
                .foregroundColor(.white)
                .tint(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .padding(.horizontal, 16).padding(.bottom, 96)
            }
        }
        .onAppear { sync() }
        .onChange(of: isActive) { _ in sync() }
        .onChange(of: speed) { _ in sync() }
        .onChange(of: loop) { _ in sync() }
        .onDisappear { model.stop() }
    }

    private func sync() {
        model.loop = loop
        model.onFinished = isActive ? onFinished : nil
        model.onReady = onReady
        model.onError = onError
        model.onStatus = onStatus
        model.setRate(speed)
        model.setActive(isActive)
    }

    static func sourceURL(_ url: URL, siteID: String?) -> URL {
        guard !url.isFileURL else { return url }
        let server = MockServer.shared.baseURL.absoluteString
        let site = siteID.map { "&site=" + WebVideoView.encode($0) } ?? ""
        return URL(string: "\(server)/proxy?url=\(WebVideoView.encode(url.absoluteString))\(site)") ?? url
    }
}

/// The view VLC draws into.
private struct VLCSurface: UIViewRepresentable {
    let model: VLCPlayerModel
    let url: URL

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.accessibilityIdentifier = "vlcVideo"
        model.load(url, into: v)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {}
}

final class VLCPlayerModel: NSObject, ObservableObject {
    @Published var position: Float = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var timeText = ""

    var loop = true
    var onFinished: (() -> Void)?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private var readySent = false
    private var active = false
    private var loaded = false
    private var opened: Date?

    #if canImport(MobileVLCKit)
    private let player = VLCMediaPlayer()

    func load(_ url: URL, into view: UIView) {
        guard !loaded else { return }
        loaded = true
        let media = VLCMedia(url: url)
        // Milliseconds of network buffer: enough to ride out short stalls, small enough to start fast.
        media.addOptions(["network-caching": 1000])
        player.media = media
        player.drawable = view
        player.delegate = self
        if AppSettings.shared.startMuted { player.audio?.isMuted = true }
        if active { start() }
    }

    func setActive(_ on: Bool) {
        active = on
        guard loaded else { return }
        if on { start() } else if player.isPlaying { player.pause() }
    }

    private func start() {
        if opened == nil { opened = Date() }
        player.play()
    }

    func togglePause() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func seek(to p: Float) {
        position = p
        player.position = p
    }

    func setRate(_ r: Double) { player.rate = Float(r) }

    func stop() {
        player.delegate = nil
        player.stop()
    }
    #else
    func load(_ url: URL, into view: UIView) { onError?("VLCKit isn't included in this build.") }
    func setActive(_ on: Bool) {}
    func togglePause() {}
    func seek(to p: Float) {}
    func setRate(_ r: Double) {}
    func stop() {}
    #endif

    fileprivate func markReady() {
        guard !readySent else { return }
        readySent = true
        let ms = opened.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        DebugLog.log("VLC", "Playing after \(ms) ms")
        onStatus?("VLCKit (native decoder)")
        onReady?()
    }
}

#if canImport(MobileVLCKit)
extension VLCPlayerModel: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let state = player.state
        DispatchQueue.main.async { [self] in
            isPlaying = player.isPlaying
            switch state {
            case .playing:
                markReady()
            case .error:
                DebugLog.log("VLC", "Playback error")
                onError?("VLC couldn't play this video.")
            case .ended:
                if loop {
                    player.stop()
                    player.play()
                } else {
                    onFinished?()
                }
            default:
                break
            }
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let p = player.position
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        let now = Double(player.time.intValue) / 1000
        DispatchQueue.main.async { [self] in
            markReady()
            position = p
            duration = length
            isPlaying = player.isPlaying
            timeText = Self.format(now) + " / " + Self.format(length)
        }
    }

    static func format(_ s: Double) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
#endif
