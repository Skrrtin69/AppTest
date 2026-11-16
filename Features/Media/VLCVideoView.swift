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
        .onAppear { sync(); model.setOnScreen(true) }
        .onChange(of: isActive) { _ in sync() }
        .onChange(of: speed) { _ in sync() }
        .onChange(of: loop) { _ in sync() }
        // Swiping to another post: close the stream. Coming back reopens it at the same
        // time (see setOnScreen), with the delegate still attached so "ready" is reported.
        .onDisappear { model.setOnScreen(false) }
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

    final class Coordinator {
        var host: UIHostingController<VLCControls>?
        weak var model: VLCPlayerModel?
        weak var video: UIView?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ v: UIView, coordinator: Coordinator) {
        if let video = coordinator.video { coordinator.model?.surfaceGone(video) }
    }

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
        context.coordinator.model = model
        context.coordinator.video = video
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
    /// "Ready" was reported for the stream that is open now. Reset on every reopen and after
    /// an error, so the "Loading video..." overlay always hears when the video really plays.
    private var readySent = false
    private var active = false
    private var loaded = false
    private var opened: Date?
    /// Rebuilds the stream's address (after the background the local server may be on a
    /// different port).
    var reopenURL: (() -> URL)?
    private var firstURL: URL?
    /// The view VLC draws into. VLC ties its video output to the view it started on, so a
    /// new view needs the stream reopened on it; otherwise the sound plays over black.
    private weak var surface: UIView?
    /// The page is on screen (onAppear / onDisappear).
    private var onScreen = false
    private var inBackground = false
    /// The stream is closed (page swiped away, app in the background, or a new surface)
    /// and reopens at resumeAtMs.
    private var closed = false
    private var resumeAtMs: Int32 = 0
    private var wasPlaying = false
    /// When the app last stopped the stream itself: VLC can report that stop as an error
    /// a moment later, which must not show the error card.
    private var lastStop: Date?
    /// Reopened while not playing: play to the first frame (muted), then pause on it.
    private var pauseOnStart = false
    private var mutedBeforePeek = false

    // iOS closes the local server's connections while the app is away, so VLC's stream
    // would be dead on return: close it in the background and reopen it at the same time.
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
                    self?.resumeFromBackground()
                }
            },
        ]
    }

    private var observers: [NSObjectProtocol] = []
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        releasePlayer()
    }

    #if canImport(MobileVLCKit)
    private let player = VLCMediaPlayer()

    private static func media(_ url: URL, startMs: Int32) -> VLCMedia {
        let media = VLCMedia(url: url)
        // Milliseconds of network buffer: enough to ride out short stalls, small enough to start fast.
        var options: [AnyHashable: Any] = ["network-caching": 1000]
        if startMs > 0 { options["start-time"] = Double(startMs) / 1000 }
        media.addOptions(options)
        return media
    }

    /// Called each time SwiftUI builds the surface.
    func load(_ url: URL, into view: UIView) {
        surface = view
        guard loaded else {
            loaded = true
            firstURL = url
            player.delegate = self
            player.drawable = view
            player.media = Self.media(url, startMs: 0)
            if AppSettings.shared.startMuted { player.audio?.isMuted = true }
            if active { start() }
            return
        }
        // A new surface for a player that already exists: move the stream onto it.
        DebugLog.log("VLC", "New video surface: reopening the stream on it")
        close("new surface")
        if onScreen, !inBackground { reopen(play: active) }
    }

    /// SwiftUI removed a surface. If VLC is still drawing into it, close the stream.
    func surfaceGone(_ view: UIView) {
        guard loaded, surface == nil || surface === view else { return }
        close("surface removed")
    }

    /// The page came on screen or went off it.
    func setOnScreen(_ on: Bool) {
        onScreen = on
        guard loaded else { return }
        if on {
            if closed, !inBackground { reopen(play: active) }
        } else {
            close("off screen")
        }
    }

    func setActive(_ on: Bool) {
        active = on
        guard loaded, !closed else { return }
        if on { start() } else if player.isPlaying { player.pause() }
    }

    private func start() {
        endPeek()
        if opened == nil { opened = Date() }
        player.play()
    }

    /// Stops the stream and notes where to pick up. The delegate stays attached.
    private func close(_ why: String) {
        guard loaded, !closed else { return }
        let t = player.time.intValue
        if t > 0 { resumeAtMs = t }
        endPeek()
        closed = true
        readySent = false
        lastStop = Date()
        player.stop()
        DebugLog.log("VLC", "Closed (\(why)) at \(resumeAtMs) ms")
    }

    /// Opens the stream again on the current surface at the saved time.
    private func reopen(play: Bool) {
        guard loaded, closed, let view = surface, let url = reopenURL?() ?? firstURL else { return }
        closed = false
        readySent = false
        opened = Date()
        player.delegate = self
        player.drawable = view
        player.media = Self.media(url, startMs: resumeAtMs)
        if !play {
            // Show the paused frame instead of a black screen.
            pauseOnStart = true
            mutedBeforePeek = player.audio?.isMuted ?? false
            player.audio?.isMuted = true
        }
        player.play()
        DebugLog.log("VLC", "Reopened at \(resumeAtMs) ms\(play ? ", playing" : ", paused")")
    }

    private func endPeek() {
        guard pauseOnStart else { return }
        pauseOnStart = false
        player.audio?.isMuted = mutedBeforePeek
    }

    func togglePause() {
        // Play pressed while the stream is closed: reopen now and play.
        if closed { reopen(play: true); return }
        endPeek()
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func seek(to p: Float) {
        position = p
        player.position = p
    }

    func setRate(_ r: Double) { player.rate = Float(r) }

    /// Control Center, a notification, the app switcher: pause, remember to carry on.
    func pauseForInactive() {
        guard loaded, !closed, player.isPlaying else { return }
        wasPlaying = true
        player.pause()
    }

    /// The app went to the background: close the stream (iOS drops the connection anyway).
    func suspend() {
        inBackground = true
        guard loaded else { return }
        if !closed, player.isPlaying { wasPlaying = true }
        close("background")
    }

    /// Back in the foreground: reopen the stream if this page is on screen, and play again
    /// if it was playing.
    func resumeFromBackground() {
        inBackground = false
        guard loaded else { return }
        defer { wasPlaying = false }
        if closed {
            if onScreen { reopen(play: wasPlaying && active) }
        } else if wasPlaying, active {
            player.play()
        }
    }

    private func releasePlayer() {
        player.delegate = nil
        player.stop()
    }
    #else
    func pauseForInactive() {}
    func suspend() {}
    func resumeFromBackground() {}
    func load(_ url: URL, into view: UIView) { onError?("VLCKit isn't included in this build.") }
    func surfaceGone(_ view: UIView) {}
    func setOnScreen(_ on: Bool) {}
    func setActive(_ on: Bool) {}
    func togglePause() {}
    func seek(to p: Float) {}
    func setRate(_ r: Double) {}
    private func releasePlayer() {}
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
            // Events from a stream the app closed itself don't count.
            guard !closed else { return }
            switch state {
            case .playing:
                markReady()
            case .error:
                if let s = lastStop, Date().timeIntervalSince(s) < 2 {
                    DebugLog.log("VLC", "Ignored an error right after closing the previous stream")
                    return
                }
                DebugLog.log("VLC", "Playback error")
                // If it plays after all, report "ready" again so the error card goes away.
                readySent = false
                onError?("VLC couldn't play this video.")
            case .ended:
                if loop {
                    lastStop = Date()
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
            guard !closed else { return }
            markReady()
            // Reopened while not playing: the first time update means a frame is on screen.
            if pauseOnStart {
                player.pause()
                endPeek()
            }
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
