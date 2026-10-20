import SwiftUI
import AVFoundation
import AVKit

/// Which player handles a given file. Decided at runtime per URL: AVFoundation is asked
/// whether it can play the asset; if not (WebM, usually) the WKWebView player is used, or
/// VLCKit when that setting is on.
enum PlaybackPath: String {
    case native, web, vlc
    var label: String {
        switch self {
        case .native: return "Native player (AVPlayer)"
        case .web: return "Web player (WKWebView)"
        case .vlc: return "VLCKit player"
        }
    }
}

actor PlaybackRouter {
    static let shared = PlaybackRouter()
    /// .native, or .web meaning "not AVPlayer" (the web player or VLC, per the setting).
    private var cache: [URL: PlaybackPath] = [:]
    /// What AVPlayer actually opens, when that differs from the post's address.
    private var aliases: [URL: URL] = [:]

    func playURL(for url: URL) -> URL { aliases[url] ?? url }

    func route(for url: URL, siteID: String? = nil) async -> PlaybackPath {
        let useVLC = await MainActor.run { AppSettings.shared.useVLC && VLCVideoView.available }
        let other: PlaybackPath = useVLC ? .vlc : .web
        if let c = cache[url] { return c == .native ? .native : other }
        // HLS streams list no tracks until they play, so the check below would wrongly send
        // them to the web player; AVPlayer is the stream player.
        if url.pathExtension.lowercased() == "m3u8" { cache[url] = .native; return .native }
        // WebM/MKV: look inside first. An MP4 with the wrong name goes to AVPlayer; real
        // Matroska goes straight to the web player or VLC, skipping AVPlayer's slow refusal.
        if ["webm", "mkv"].contains(url.pathExtension.lowercased()), let s = await MediaSniffer.sniff(url) {
            DebugLog.log("Playback", "\(url.lastPathComponent): \(s.summary)")
            switch s.container {
            case .mp4:
                let alias = url.isFileURL ? (MediaSniffer.mp4FileAlias(url) ?? url) : MediaSniffer.mp4ProxyURL(url, siteID: siteID)
                if await Self.isPlayable(AVURLAsset.withSiteHeaders(alias)) {
                    aliases[url] = alias
                    cache[url] = .native
                    DebugLog.log("Playback", "\(url.lastPathComponent) is an MP4: AVPlayer")
                    return .native
                }
            case .matroska:
                if s.isH264orHEVC, !useVLC {
                    DebugLog.log("Playback", "H.264/HEVC in Matroska: the web decoder can't play it; turn on VLCKit in Settings › Reading & Viewer")
                }
                cache[url] = .web
                return other
            case .unknown:
                break
            }
        }
        let playable = await Self.isPlayable(AVURLAsset.withSiteHeaders(url))
        let path: PlaybackPath = playable ? .native : .web
        cache[url] = path
        NSLog("[Playback] %@ → %@", url.lastPathComponent, path.rawValue)
        return path == .native ? .native : other
    }

    private static func isPlayable(_ asset: AVURLAsset) async -> Bool {
        // Race the playability check against a timeout so a slow server can't hang the viewer.
        let playable: Bool = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                guard let p = try? await asset.load(.isPlayable), p else { return false }
                let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                return !tracks.isEmpty
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
        return playable
    }

    /// Native playback failed after routing; remember to use the web player next time.
    func markFailed(_ url: URL) { cache[url] = .web }
}

/// Picks the player for `url` and shows a small label saying which one is in use.
extension AVURLAsset {
    /// AVPlayer ignores URLSession settings, so the adapter's headers (Referer, User-Agent…)
    /// are passed through the asset's HTTP header option.
    static func withSiteHeaders(_ url: URL) -> AVURLAsset {
        guard !url.isFileURL else { return AVURLAsset(url: url) }
        let headers = NetworkClient.forMedia(url).mediaHeaders
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }
}

/// 1× → 1.5× → 2× → 1×, shared by both players.
struct SpeedButton: View {
    @ObservedObject private var settings = AppSettings.shared
    var label: String {
        settings.playbackSpeed == 1 ? "1×" : (settings.playbackSpeed == 1.5 ? "1.5×" : "2×")
    }
    var body: some View {
        Button { settings.cycleSpeed(); Haptics.tap() } label: {
            Text(label).font(.caption.weight(.bold).monospacedDigit()).foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.5)))
        }
        .accessibilityLabel("Playback speed \(label)")
    }
}

struct MediaVideoView: View {
    let url: URL
    let isActive: Bool
    var showControls: Bool = true
    var siteID: String? = nil
    var onFinished: (() -> Void)? = nil
    /// A single tap on the video: shows or hides the viewer's controls (never pauses).
    var onTap: (() -> Void)? = nil
    @ObservedObject private var settings = AppSettings.shared

    @State private var path: PlaybackPath?
    /// What AVPlayer opens (an MP4 sent under a .webm name plays through the proxy as .mp4).
    @State private var nativeURL: URL?
    @State private var engine: String?
    @State private var webReady = false
    @State private var webTimedOut = false
    @State private var webAttempt = 0
    /// The page's player reported an error (decoder, network): shown at once, no waiting.
    @State private var webError: String?
    @ObservedObject private var network = NetworkSpeed.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch path {
            case .none:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(.native):
                NativeVideoView(url: nativeURL ?? url, isActive: isActive, showControls: showControls, onFinished: onFinished, onTap: onTap) {
                    Task {
                        await PlaybackRouter.shared.markFailed(url)
                        path = .web
                    }
                }
            case .some(.vlc):
                VLCVideoView(url: url, isActive: isActive, siteID: siteID, speed: settings.playbackSpeed,
                             loop: !settings.autoAdvance, showControls: showControls, onFinished: onFinished, onTap: onTap,
                             onReady: { webReady = true; webError = nil },
                             onError: { webError = $0 }, onStatus: { engine = $0 })
                    .id(webAttempt)
                    .overlay { loadingOverlay }
                    .task(id: "\(url.absoluteString)#\(webAttempt)") { await watchStart() }
            case .some(.web):
                WebVideoView(url: url, isActive: isActive, siteID: siteID, speed: settings.playbackSpeed,
                             loop: !settings.autoAdvance, onFinished: onFinished,
                             onReady: { webReady = true; webError = nil },
                             onError: { webError = $0 }) { engine = $0 }
                    .id(webAttempt)
                    .overlay(alignment: .bottomTrailing) {
                        if showControls { SpeedButton().padding(.trailing, 70).padding(.bottom, 145) }
                    }
                    .overlay { loadingOverlay }
                    .task(id: "\(url.absoluteString)#\(webAttempt)") { await watchStart() }
            }
            if let p = path, showControls {
                Text(p != .native ? "\(p.label) · \(engine ?? "loading…")" : p.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .foregroundColor(.white)
                    .padding(.top, 100).padding(.leading, 10)
                    .accessibilityIdentifier("playerPath")
            }
        }
        .task(id: url) {
            path = await PlaybackRouter.shared.route(for: url, siteID: siteID)
            nativeURL = await PlaybackRouter.shared.playURL(for: url)
        }
    }

    /// Until the player can play: "Loading video...", then (after the timeout for this
    /// connection's speed, or at once on an error) Retry / Open in Safari.
    @ViewBuilder var loadingOverlay: some View {
                        if let why = webError {
                            webFailure(why)
                        } else if !webReady {
                            if webTimedOut {
                                webFailure("The video didn't start within \(Int(network.videoTimeout)) seconds.")
                            } else {
                                ZStack {
                                    Color.black.opacity(0.35)
                                    ProgressView("Loading video...")
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                        .foregroundColor(.white)
                                        .font(.subheadline)
                                        .padding(18)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.6)))
                                }
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("webVideoLoading")
                            }
                        }
    }

    func watchStart() async {
        webReady = false
        webTimedOut = false
        webError = nil
        let limit = network.videoTimeout
        try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
        if !Task.isCancelled, !webReady {
            webTimedOut = true
            DebugLog.log("WebVideo", "No canplay within \(Int(limit)) s (\(network.summary)): \(DebugLog.redact(url))")
        }
    }
}

extension MediaVideoView {
    /// Native error card over the web player: Retry reloads the page; Open in Safari hands
    /// the original address to Safari (not for downloaded files).
    func webFailure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundColor(.yellow)
            Text(message).font(.subheadline).multilineTextAlignment(.center)
                .accessibilityIdentifier("webVideoError")
            HStack(spacing: 10) {
                Button { webAttempt += 1 } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("webVideoRetry")
                if !url.isFileURL {
                    Button { UIApplication.shared.open(url) } label: { Label("Open in Safari", systemImage: "safari") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("webVideoSafari")
                }
            }
        }
        .foregroundColor(.white)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.75)))
        .padding(24)
    }
}

/// Where video controls sit: above the viewer's bottom toolbar and the home indicator.
enum ScreenInsets {
    static var safeBottom: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.bottom ?? 0
    }
    /// The viewer's bottom toolbar is about 76 pt tall above the safe area; 14 pt gap.
    static var videoControlsBottom: CGFloat { safeBottom + 90 }
}

// MARK: - Native (AVPlayer + AVPlayerLayer)

@MainActor
final class VideoController: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    let player: AVPlayer
    @Published var pipActive = false
    private var pip: AVPictureInPictureController?
    /// Videos playing in Picture in Picture are kept alive here after the viewer closes.
    static var floating: VideoController?
    @Published var isPlaying = false
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var failed = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    var isScrubbing = false

    /// Called when the video ends while auto-advance is on.
    var onFinished: (() -> Void)?
    /// Whether this video's page is the one on screen (kept current by the view).
    var isActivePage = false

    init(url: URL) {
        let item = AVPlayerItem(asset: AVURLAsset.withSiteHeaders(url))
        player = AVPlayer(playerItem: item)
        super.init()
        player.isMuted = AppSettings.shared.startMuted
        // Loop by default.
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if AppSettings.shared.autoAdvance, let done = self.onFinished {
                    done()          // auto-advance: the viewer moves to the next post
                } else {
                    self.player.seek(to: .zero)
                    if self.isPlaying { self.play() }
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self = self, !self.isScrubbing else { return }
                self.current = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                Task { @MainActor in self?.failed = true }
            }
        }
    }

    var pipPossible: Bool { pip != nil && AVPictureInPictureController.isPictureInPictureSupported() }

    /// Called once the video's layer exists.
    func attach(layer: AVPlayerLayer) {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let c = AVPictureInPictureController(playerLayer: layer)
        c?.delegate = self
        // Going to the Home Screen while a video plays continues it in a floating window.
        c?.canStartPictureInPictureAutomaticallyFromInline = true
        pip = c
        objectWillChange.send()
    }

    /// The frame on screen right now, full size.
    func grabFrame() async -> UIImage? {
        guard let asset = player.currentItem?.asset else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let t = player.currentTime()
        return await withCheckedContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { _, cg, _, _, _ in
                cont.resume(returning: cg.map { UIImage(cgImage: $0) })
            }
        }
    }

    func togglePiP() {
        guard let c = pip else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { if !isPlaying { play() }; c.startPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.pipActive = true; VideoController.floating = self }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in
            self.pipActive = false
            // If the viewer was closed meanwhile, the floating video is finished now.
            if VideoController.floating === self { VideoController.floating = nil; if self.viewGone { self.teardown() } }
        }
    }

    /// The viewer page went away while Picture in Picture was running.
    var viewGone = false

    /// Called when the view goes away; removes observers so the player can be released.
    func teardown() {
        player.pause()
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        statusObservation = nil
    }

    /// Plays at the speed chosen in the viewer (1×, 1.5×, 2×).
    func play() {
        player.rate = Float(AppSettings.shared.playbackSpeed)
        isPlaying = true
    }

    func applySpeed() {
        if isPlaying { player.rate = Float(AppSettings.shared.playbackSpeed) }
    }
    func pause() { player.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

struct NativeVideoView: View {
    let url: URL
    let isActive: Bool
    var showControls: Bool = true
    var onFinished: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil
    var onFailure: () -> Void

    @StateObject private var holder = ControllerHolder()

    final class ControllerHolder: ObservableObject {
        @Published var controller: VideoController?
    }

    var body: some View {
        ZStack {
            if let c = holder.controller {
                NativeVideoContent(controller: c, isActive: isActive, showControls: showControls, onTap: onTap, onFailure: onFailure)
            } else {
                Color.black
            }
        }
        .onAppear {
            if holder.controller == nil { holder.controller = VideoController(url: url) }
            if let c = holder.controller {
                c.isActivePage = isActive
                c.onFinished = { [weak c] in if c?.isActivePage == true { onFinished?() } }
            }
        }
        .onDisappear {
            // A video in Picture in Picture keeps playing after the viewer closes.
            if let c = holder.controller, c.pipActive {
                c.viewGone = true
            } else {
                holder.controller?.teardown()
            }
            holder.controller = nil
        }
    }
}

private struct NativeVideoContent: View {
    @ObservedObject var controller: VideoController
    @ObservedObject private var settings = AppSettings.shared
    let isActive: Bool
    let showControls: Bool
    var onTap: (() -> Void)? = nil
    let onFailure: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerLayerView(player: controller.player, onLayer: { controller.attach(layer: $0) })
                .contentShape(Rectangle())
                // A tap shows or hides the controls; pausing is the Pause button's job.
                .onTapGesture { onTap?() }
                .accessibilityIdentifier("videoSurface")
                .accessibilityLabel(controller.isPlaying ? "Video playing, tap for controls" : "Video paused, tap for controls")
            if !controller.isPlaying {
                Image(systemName: "play.circle.fill").font(.system(size: 64)).foregroundColor(.white.opacity(0.85))
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showControls {
                HStack(spacing: 10) {
                    Button { controller.toggle() } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").foregroundColor(.white)
                    }
                    .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                    Text(Self.fmt(controller.current)).font(.caption.monospacedDigit()).foregroundColor(.white)
                    Slider(value: Binding(get: { controller.current },
                                          set: { controller.current = $0; controller.seek(to: $0) }),
                           in: 0...max(controller.duration, 0.1),
                           onEditingChanged: { editing in controller.isScrubbing = editing })
                    .accessibilityIdentifier("videoScrubber")
                    Text(Self.fmt(controller.duration)).font(.caption.monospacedDigit()).foregroundColor(.white)
                    SpeedButton()
                    Button {
                        Task {
                            if let img = await controller.grabFrame() {
                                Presenter.present(UIHostingController(rootView: FrameGrabView(image: img, time: controller.current)))
                            } else {
                                ToastCenter.shared.show("Couldn't grab this frame.", style: .error)
                            }
                        }
                    } label: { Image(systemName: "camera").foregroundColor(.white) }
                    .accessibilityLabel("Grab frame")
                    if controller.pipPossible {
                        Button { controller.togglePiP() } label: {
                            Image(systemName: controller.pipActive ? "pip.exit" : "pip.enter").foregroundColor(.white)
                        }
                        .accessibilityLabel(controller.pipActive ? "Stop Picture in Picture" : "Picture in Picture")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.black.opacity(0.45))
                .padding(.bottom, ScreenInsets.videoControlsBottom)
            }
        }
        .onAppear { if isActive && AppSettings.shared.videosAutoplay { controller.play() } }
        .onChange(of: isActive) { active in
            controller.isActivePage = active
            if active { if AppSettings.shared.videosAutoplay { controller.play() } } else if !controller.pipActive { controller.pause() }
        }
        .onDisappear { if !controller.pipActive { controller.pause() } }
        .onChange(of: controller.failed) { f in if f { onFailure() } }
        .onChange(of: settings.playbackSpeed) { _ in controller.applySpeed() }
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// A UIView whose backing layer is an AVPlayerLayer.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    /// Gets the layer once (for Picture in Picture).
    var onLayer: ((AVPlayerLayer) -> Void)? = nil

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        if let cb = onLayer { DispatchQueue.main.async { cb(v.playerLayer) } }
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = gravity
    }
}
