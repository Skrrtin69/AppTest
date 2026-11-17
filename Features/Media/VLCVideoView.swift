import SwiftUI
import AVFoundation
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
        VLCSurface(model: model, url: Self.sourceURL(url, siteID: siteID), resumeKey: url,
                   controls: VLCControls(model: model, showControls: showControls, onTap: onTap))
        // Playback follows isActive only. The pager fires onAppear/onDisappear for pages
        // that aren't really coming or going while you swipe, so they don't open or close
        // anything; the stream closes when its surface is removed or the page is unloaded.
        .onAppear { sync() }
        .onChange(of: isActive) { _ in sync() }
        .onChange(of: speed) { _ in sync() }
        .onChange(of: loop) { _ in sync() }
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
            // A tap shows or hides the controls (pausing is the Pause button's job); double tap
            // a side to skip 10 s; touch and hold for 2×.
            VideoGestureLayer(isPlaying: model.isPlaying, onTap: { onTap?() },
                              onSkip: { model.skip(by: $0) }, onHold: { model.hold($0) })
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
                    MuteButton()
                    SpeedButton()
                }
                .foregroundColor(.white)
                .tint(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.horizontal, 16).padding(.bottom, ScreenInsets.videoControlsBottom)
            }
        }
        .onReceive(VideoSound.shared.$muted) { model.applyMute($0) }
        .ignoresSafeArea()
    }
}

/// A container with VLC's drawing view at the back and the SwiftUI controls on top.
private struct VLCSurface: UIViewRepresentable {
    let model: VLCPlayerModel
    let url: URL
    /// The post's own address (the key for the saved playback spot).
    let resumeKey: URL
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
        model.resumeKey = resumeKey
        model.load(url, into: video)
        return container
    }

    func updateUIView(_ v: UIView, context: Context) {
        let c = context.coordinator
        c.host?.rootView = controls
        // The pager can hand this view to another page (another player) without making a
        // new one. Move the view to that player; otherwise the old player keeps drawing
        // here (wrong video, or sound over black) and the new one never starts.
        if c.model !== model, let video = c.video {
            c.model?.surfaceGone(video)
            c.model = model
            DebugLog.log("VLC", "Video surface handed to another post")
            model.resumeKey = resumeKey
            model.load(url, into: video)
        }
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
    private var inBackground = false
    /// The stream is closed (app in the background, or its surface was replaced or removed)
    /// and reopens at resumeAtMs when the page is the current one.
    private var closed = false
    private var resumeAtMs: Int32 = 0
    private var wasPlaying = false
    /// When the app last stopped the stream itself: VLC can report that stop as an error
    /// a moment later, which must not show the error card.
    private var lastStop: Date?
    /// The post's own address: the key for the saved playback spot.
    var resumeKey: URL?
    /// Picked up from a saved spot; announced once when playback starts.
    private var resumedFrom: Double?
    /// Touch-and-hold 2×.
    private var holding = false
    private var playingBeforeHold = false
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
            // Headphones unplugged or Bluetooth gone: pause, like the built-in player does,
            // instead of carrying on out loud through the speaker.
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                self?.pauseForRouteLoss()
            },
        ]
    }

    private func pauseForRouteLoss() {
        guard loaded, !closed, player.isPlaying else { return }
        player.pause()
        DebugLog.log("VLC", "Paused: headphones disconnected")
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
            if let k = resumeKey, let t = VideoResumeStore.shared.position(for: k) {
                resumedFrom = t
                resumeAtMs = Int32(t * 1000)
            }
            player.media = Self.media(url, startMs: resumeAtMs)
            player.audio?.isMuted = VideoSound.shared.muted
            if active { start() }
            return
        }
        // A new surface for a player that already exists: move the stream onto it.
        DebugLog.log("VLC", "New video surface: reopening the stream on it")
        close("new surface")
        if active, !inBackground { reopen(play: true) }
    }

    /// SwiftUI removed a surface. If VLC is still drawing into it, close the stream.
    func surfaceGone(_ view: UIView) {
        guard loaded, surface == nil || surface === view else { return }
        close("surface removed")
        // Never reopen into a view that left the screen (it may still be alive, waiting
        // for reuse): wait for load(_:into:) to bring a surface.
        surface = nil
    }

    /// The current post plays; the others pause (their streams stay open, so going back is
    /// instant). A closed stream reopens only for the current post.
    func setActive(_ on: Bool) {
        active = on
        guard loaded else { return }
        if closed {
            if on, !inBackground { reopen(play: true) }
            return
        }
        if on { start() } else if player.isPlaying { player.pause() }
    }

    private func start() {
        endPeek()
        if opened == nil { opened = Date() }
        player.play()
        player.audio?.isMuted = VideoSound.shared.muted
    }

    /// Stops the stream and notes where to pick up. The delegate stays attached.
    private func close(_ why: String) {
        guard loaded, !closed else { return }
        let t = player.time.intValue
        if t > 0 { resumeAtMs = t }
        saveSpot(force: true)
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
        player.audio?.isMuted = VideoSound.shared.muted
    }

    /// The mute button: applies now, or after a silent paused-frame peek ends.
    func applyMute(_ muted: Bool) {
        guard loaded, !pauseOnStart else { return }
        player.audio?.isMuted = muted
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

    func setRate(_ r: Double) {
        guard !holding else { return }
        player.rate = Float(r)
    }

    /// Double tap on a side: back or forward by `seconds`.
    func skip(by seconds: Double) {
        guard loaded, !closed else { return }
        let lengthMs = player.media?.length.intValue ?? 0
        var target = Double(player.time.intValue) + seconds * 1000
        if lengthMs > 0 { target = min(target, Double(lengthMs) - 250) }
        target = max(0, target)
        player.time = VLCTime(int: Int32(target))
        if lengthMs > 0 { position = Float(target / Double(lengthMs)) }
    }

    /// Touch and hold: 2× while held, then back to how it was.
    func hold(_ on: Bool) {
        guard loaded, !closed, on != holding else { return }
        holding = on
        if on {
            playingBeforeHold = player.isPlaying
            endPeek()
            player.rate = 2
            if !player.isPlaying { player.play() }
        } else {
            player.rate = Float(AppSettings.shared.playbackSpeed)
            if !playingBeforeHold { player.pause() }
        }
    }

    /// Remembers where this video is (long videos only; see VideoResumeStore).
    fileprivate func saveSpot(force: Bool = false) {
        guard let k = resumeKey, let length = player.media?.length.intValue, length > 0 else { return }
        let now = Double(player.time.intValue) / 1000
        guard now > 0 else { return }
        VideoResumeStore.shared.save(now, duration: Double(length) / 1000, for: k, force: force)
    }

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
            // Only the current post reopens now (paused on its frame if it was paused);
            // the others reopen when you swipe to them.
            if active { reopen(play: wasPlaying) }
        } else if wasPlaying, active {
            player.play()
        }
    }

    private func releasePlayer() {
        if loaded, !closed { saveSpot(force: true) }
        player.delegate = nil
        player.stop()
    }

    fileprivate func announceResume() {
        guard let r = resumedFrom else { return }
        resumedFrom = nil
        ToastCenter.shared.show("Resumed at \(VideoResumeStore.format(r))", actionTitle: "Start Over") { [weak self] in
            guard let self = self else { return }
            if let k = self.resumeKey { VideoResumeStore.shared.clear(k) }
            self.seek(to: 0)
        }
    }
    #else
    func pauseForInactive() {}
    func suspend() {}
    func resumeFromBackground() {}
    func load(_ url: URL, into view: UIView) { onError?("VLCKit isn't included in this build.") }
    func surfaceGone(_ view: UIView) {}
    func setActive(_ on: Bool) {}
    func togglePause() {}
    func seek(to p: Float) {}
    func setRate(_ r: Double) {}
    func skip(by seconds: Double) {}
    func hold(_ on: Bool) {}
    fileprivate func saveSpot(force: Bool = false) {}
    fileprivate func announceResume() {}
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
        if active { announceResume() }
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
                if let k = resumeKey { VideoResumeStore.shared.clear(k) }
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
            // Only publish what changed: each change redraws the controls.
            if position != p { position = p }
            if duration != length { duration = length }
            if isPlaying != player.isPlaying { isPlaying = player.isPlaying }
            let text = Self.format(now) + " / " + Self.format(length)
            if timeText != text { timeText = text }
            if player.isPlaying { saveSpot() }
        }
    }

    static func format(_ s: Double) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
#endif
