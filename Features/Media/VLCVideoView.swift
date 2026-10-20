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
    /// A single tap shows or hides the viewer's controls; it never pauses.
    var onTap: (() -> Void)? = nil
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
        // The controls live inside the same UIKit container, above VLC's drawing view:
        // VLC's video output draws over SwiftUI views placed next to it.
        VLCSurface(model: model, url: Self.sourceURL(url, siteID: siteID),
                   controls: VLCControls(model: model, showControls: showControls, onTap: onTap))
        .onAppear { sync() }
        .onChange(of: isActive) { _ in sync() }
        .onChange(of: speed) { _ in sync() }
        .onChange(of: loop) { _ in sync() }
        .onDisappear { model.stop() }
    }

    private func sync() {
        // Rebuilt on return from the background: the server may be on a different port.
        let (u, site) = (url, siteID)
        model.reopenURL = { Self.sourceURL(u, siteID: site) }
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
/// The tap area, the paused icon and the control bar, drawn above the video.
private struct VLCControls: View {
    @ObservedObject var model: VLCPlayerModel
    let showControls: Bool
    let onTap: (() -> Void)?

    var body: some View {
        ZStack(alignment: .bottom) {
            // A tap shows or hides the controls; pausing is the Pause button's job.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
                .accessibilityLabel(model.isPlaying ? "Video playing, tap for controls" : "Video paused, tap for controls")
            if model.started, !model.isPlaying {
                Image(systemName: "play.circle.fill").font(.system(size: 64)).foregroundColor(.white.opacity(0.85))
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showControls, model.duration > 0 {
                HStack(spacing: 10) {
                    Button { model.togglePause() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                    Slider(value: Binding(get: { Double(model.position) }, set: { model.seek(to: Float($0)) }), in: 0...1)
                        .accessibilityIdentifier("vlcScrubber")
                    Text(model.timeText).font(.caption.monospacedDigit())
                }
                .foregroundColor(.white)
                .tint(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.horizontal, 16).padding(.bottom, ScreenInsets.videoControlsBottom)
            }
        }
        .ignoresSafeArea()
    }
}

/// A container with VLC's drawing view at the back and the SwiftUI controls on top.
private struct VLCSurface: UIViewRepresentable {
    let model: VLCPlayerModel
    let url: URL
    let controls: VLCControls

    final class Coordinator { var host: UIHostingController<VLCControls>? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let video = UIView(frame: container.bounds)
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        video.backgroundColor = .black
        video.isUserInteractionEnabled = false
        video.accessibilityIdentifier = "vlcVideo"
        container.addSubview(video)
        let host = UIHostingController(rootView: controls)
        host.view.backgroundColor = .clear
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(host.view)
        context.coordinator.host = host
        model.load(url, into: video)
        return container
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.host?.rootView = controls
    }
}

final class VLCPlayerModel: NSObject, ObservableObject {
    @Published var position: Float = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var timeText = ""
    /// Playback has begun at least once (the paused icon only shows after that).
    @Published var started = false

    var loop = true
    var onFinished: (() -> Void)?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private var readySent = false
    private var active = false
    private var loaded = false
    private var opened: Date?
    /// Background handling: where to pick up, whether it was playing, and whether the
    /// stream was closed.
    var reopenURL: (() -> URL)?
    private var resumeAtMs: Int32 = 0
    private var wasPlaying = false
    private var suspended = false

    // iOS closes the local server's connections while the app is away, so VLC's stream
    // would be dead on return: stop it in the background and reopen it at the same time.
    // (App notifications, not scenePhase: the viewer is presented outside the SwiftUI scene,
    // where scenePhase never changes.)
    override init() {
        super.init()
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.pauseForInactive()
            },
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.suspend()
            },
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await MockServer.shared.ensureReady()
                    guard let self = self, let url = self.reopenURL?() else { return }
                    self.resume(from: url)
                }
            },
        ]
    }

    private var observers: [NSObjectProtocol] = []
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

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

    /// Control Center, a notification, the app switcher: pause, remember to carry on.
    func pauseForInactive() {
        guard loaded, !suspended, player.isPlaying else { return }
        wasPlaying = true
        player.pause()
    }

    /// The app went to the background: note the time and close the stream.
    func suspend() {
        guard loaded, !suspended else { return }
        if player.isPlaying { wasPlaying = true }
        resumeAtMs = max(0, player.time.intValue)
        suspended = true
        player.stop()
        DebugLog.log("VLC", "Background: stopped at \(resumeAtMs) ms (was \(wasPlaying ? "playing" : "paused"))")
    }

    /// Back in the foreground: reopen the stream at the saved time (a new connection to the
    /// local server), and play again if it was playing.
    func resume(from url: URL) {
        guard loaded else { return }
        defer { wasPlaying = false }
        guard suspended else {
            if wasPlaying, active { player.play() }
            return
        }
        suspended = false
        let media = VLCMedia(url: url)
        media.addOptions(["network-caching": 1000, "start-time": Double(resumeAtMs) / 1000])
        player.media = media
        if wasPlaying, active { player.play() }
        DebugLog.log("VLC", "Foreground: reopened at \(resumeAtMs) ms\(wasPlaying && active ? ", playing" : ", paused")")
    }
    #else
    func pauseForInactive() {}
    func suspend() {}
    func resume(from url: URL) {}
    func load(_ url: URL, into view: UIView) { onError?("VLCKit isn't included in this build.") }
    func setActive(_ on: Bool) {}
    func togglePause() {}
    func seek(to p: Float) {}
    func setRate(_ r: Double) {}
    func stop() {}
    #endif

    fileprivate func markReady() {
        started = true
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
                // Errors from the stream being closed for the background don't count.
                guard !suspended else { return }
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
