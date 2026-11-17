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
        // AVPlayer's own formats go straight to it: asking first cost up to 8 s before the
        // player even existed. If one turns out unplayable, the player's failure switches it
        // to the web player / VLC (markFailed).
        if ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) { cache[url] = .native; return .native }
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
        let answer = await Self.check(AVURLAsset.withSiteHeaders(url))
        let path: PlaybackPath = answer == true ? .native : .web
        // A check that ran out of time says nothing about the file: don't remember it.
        if answer != nil { cache[url] = path }
        NSLog("[Playback] %@ → %@", url.lastPathComponent, path.rawValue)
        return path == .native ? .native : other
    }

    private static func isPlayable(_ asset: AVURLAsset) async -> Bool { await check(asset) ?? false }

    /// true / false, or nil when the check ran out of time.
    private static func check(_ asset: AVURLAsset) async -> Bool? {
        // Race the playability check against a timeout so a slow server can't hang the viewer.
        let playable: Bool?? = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                guard let p = try? await asset.load(.isPlayable), p else { return false }
                let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                return !tracks.isEmpty
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first
        }
        // group.next(): nil only if no task finished; the inner nil is the timeout.
        return playable ?? nil
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

/// Tap: 1× → 1.5× → 2× → 1×. Touch and hold: every speed from 0.5× to 2×. Shared by the
/// built-in player and VLCKit.
struct SpeedButton: View {
    @ObservedObject private var settings = AppSettings.shared
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// 0.5×, 0.75×, 1×, 1.25×…
    static func label(_ v: Double) -> String {
        var t = String(format: "%.2f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t + "×"
    }
    var label: String { Self.label(settings.playbackSpeed) }
    var body: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { v in
                Button { settings.playbackSpeed = v } label: {
                    if v == settings.playbackSpeed { Label(Self.label(v), systemImage: "checkmark") } else { Text(Self.label(v)) }
                }
            }
        } label: {
            Text(label).font(.caption.weight(.bold).monospacedDigit()).foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.5)))
        } primaryAction: {
            settings.cycleSpeed(); Haptics.tap()
        }
        .accessibilityLabel("Playback speed \(label)")
        .accessibilityHint("Touch and hold for more speeds")
    }
}

/// Sound on/off for every video this session; it starts from Settings › Start videos muted.
struct MuteButton: View {
    @ObservedObject private var sound = VideoSound.shared
    var body: some View {
        Button { sound.muted.toggle(); Haptics.tap() } label: {
            Image(systemName: sound.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").foregroundColor(.white)
                .frame(width: 26)
        }
        .accessibilityLabel(sound.muted ? "Sound off" : "Sound on")
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
    /// Which video (address + attempt) webReady / webError belong to.
    @State private var watchedKey: String?
    /// The video that already had its one silent retry.
    @State private var autoRetried: URL?
    /// How many times the VLC stream was closed (for the loading watchdog).
    @State private var closures = 0
    @ObservedObject private var network = NetworkSpeed.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch path {
            case .none:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(.native):
                NativeVideoView(url: nativeURL ?? url, resumeKey: url, isActive: isActive, showControls: showControls, onFinished: onFinished, onTap: onTap) {
                    Task {
                        await PlaybackRouter.shared.markFailed(url)
                        path = .web
                    }
                }
            case .some(.vlc):
                VLCVideoView(url: url, isActive: isActive, siteID: siteID, speed: settings.playbackSpeed,
                             loop: !settings.autoAdvance, showControls: showControls, onFinished: onFinished, onTap: onTap,
                             onReady: { webReady = true; webError = nil },
                             onError: { reportError($0) }, onStatus: { engine = $0 },
                             onClosed: { webReady = false; closures += 1 })
                    // Per address too: if the pager hands this view to another post, it gets
                    // its own player instead of the old video carrying on under it.
                    .id("\(url.absoluteString)#\(webAttempt)")
                    .overlay { loadingOverlay }
                    // Also re-armed after each close, so a reopen that hangs still ends in the card.
                    .task(id: "\(url.absoluteString)#\(webAttempt)#\(isActive)#\(closures)") { await watchStart() }
            case .some(.web):
                WebVideoView(url: url, isActive: isActive, siteID: siteID, speed: settings.playbackSpeed,
                             loop: !settings.autoAdvance, onFinished: onFinished,
                             onReady: { webReady = true; webError = nil },
                             onError: { reportError($0) }) { engine = $0 }
                    .id("\(url.absoluteString)#\(webAttempt)")
                    .overlay(alignment: .bottomTrailing) {
                        if showControls { SpeedButton().padding(.trailing, 70).padding(.bottom, 145) }
                    }
                    .overlay { loadingOverlay }
                    .task(id: "\(url.absoluteString)#\(webAttempt)#\(isActive)") { await watchStart() }
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
                                    VStack(spacing: 6) {
                                        ProgressView("Loading video...")
                                            .progressViewStyle(.circular)
                                            .tint(.white)
                                            .foregroundColor(.white)
                                            .font(.subheadline)
                                        LoadingProgressText(url: url)
                                    }
                                        .padding(18)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.6)))
                                }
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("webVideoLoading")
                            }
                        }
    }

    /// Many failures are a dropped connection: the first error for a video retries once
    /// without showing anything; a second one shows the card.
    func reportError(_ message: String) {
        if autoRetried != url {
            autoRetried = url
            DebugLog.log("Video", "Error (\(message)): retrying once before showing it")
            webAttempt += 1
        } else {
            webError = message
        }
    }

    func watchStart() async {
        // The pager re-runs this task (onAppear) for pages that never left while you swipe,
        // and can hand this view's state to another post. A video that already started, or
        // already showed its error, keeps that state (resetting it left "Loading video..."
        // over a playing video, then the timeout card); a different video or a Retry starts over.
        let key = "\(url.absoluteString)#\(webAttempt)"
        if watchedKey == key, webReady || webError != nil { return }
        if watchedKey != key {
            watchedKey = key
            webReady = false
            webError = nil
        }
        webTimedOut = false
        // A neighbouring page doesn't start until it's the current one: no timeout for it
        // (it used to show "didn't start within N seconds" when you swiped to it).
        guard isActive else { return }
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
    /// Autoplay already happened for this player (see NativeVideoContent.onAppear).
    var autoplayed = false
    private var rateObservation: NSKeyValueObservation?
    private var viewerClosedObserver: NSObjectProtocol?

    /// Called when the video ends while auto-advance is on.
    var onFinished: (() -> Void)?
    /// Whether this video's page is the one on screen (kept current by the view).
    var isActivePage = false
    /// The post's own address: the key for the saved playback spot.
    let resumeKey: URL
    /// Picked up from a saved spot; announced once when playback starts.
    private var resumedFrom: Double?
    /// Touch-and-hold 2×: whether it was playing before, to go back to that on release.
    private var playingBeforeHold = false
    private var holding = false
    /// The layer Picture in Picture is tied to (the view can be rebuilt with a new layer).
    private weak var pipLayer: AVPlayerLayer?

    init(url: URL, resumeKey: URL? = nil) {
        self.resumeKey = resumeKey ?? url
        let item = AVPlayerItem(asset: AVURLAsset.withSiteHeaders(url))
        player = AVPlayer(playerItem: item)
        super.init()
        player.isMuted = VideoSound.shared.muted
        // The viewer closed: stop, unless this is the video floating in Picture in Picture.
        viewerClosedObserver = NotificationCenter.default.addObserver(forName: VideoActivity.viewerClosed, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.pipActive else { return }
            self.pause()
        }
        // Paused by iOS (headphones out, a call, PiP closed): show it. The end of the video
        // is left to the end observer (it loops or moves on).
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self = self, !self.holding else { return }
                let playing = p.timeControlStatus != .paused
                if !playing, let item = p.currentItem, item.duration.isNumeric,
                   item.currentTime().seconds >= item.duration.seconds - 0.3 { return }
                if self.isPlaying != playing { self.isPlaying = playing }
            }
        }
        if let t = VideoResumeStore.shared.position(for: self.resumeKey) {
            resumedFrom = t
            current = t
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // Loop by default.
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                VideoResumeStore.shared.clear(self.resumeKey)
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
                let now = t.seconds.isFinite ? t.seconds : 0
                if now != self.current { self.current = now }
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d != self.duration { self.duration = d }
                if self.isPlaying { VideoResumeStore.shared.save(now, duration: self.duration, for: self.resumeKey) }
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
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // Already tied to this layer, or floating right now: keep it.
        if pip != nil && (pipLayer === layer || pipActive) { return }
        pipLayer = layer
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

    /// The floating window's "back to the app" button. Without this the button does nothing.
    /// The video's page is still on screen (or was closed, in which case PiP just ends).
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
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
        if duration > 0 { VideoResumeStore.shared.save(player.currentTime().seconds, duration: duration, for: resumeKey, force: true) }
        player.pause()
        rateObservation?.invalidate(); rateObservation = nil
        if let o = viewerClosedObserver { NotificationCenter.default.removeObserver(o); viewerClosedObserver = nil }
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        statusObservation = nil
    }

    /// Plays at the speed chosen in the viewer (1×, 1.5×, 2×).
    func play() {
        player.rate = Float(AppSettings.shared.playbackSpeed)
        isPlaying = true
        if let r = resumedFrom {
            resumedFrom = nil
            ToastCenter.shared.show("Resumed at \(VideoResumeStore.format(r))", actionTitle: "Start Over") { [weak self] in
                self?.current = 0
                self?.seek(to: 0)
                if let k = self?.resumeKey { VideoResumeStore.shared.clear(k) }
            }
        }
    }

    /// Double tap on a side: back or forward by `seconds`, kept inside the video.
    func skip(by seconds: Double) {
        var t = player.currentTime().seconds
        if !t.isFinite { t = current }
        t += seconds
        if duration > 0 { t = min(t, duration - 0.25) }
        t = max(0, t)
        current = t
        seek(to: t)
    }

    /// Touch and hold: 2× while held, then back to how it was.
    func hold(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        if on {
            playingBeforeHold = isPlaying
            player.rate = 2
            isPlaying = true
        } else if playingBeforeHold {
            player.rate = Float(AppSettings.shared.playbackSpeed)
        } else {
            pause()
        }
    }

    func applySpeed() {
        if isPlaying, !holding { player.rate = Float(AppSettings.shared.playbackSpeed) }
    }
    func pause() { player.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

struct NativeVideoView: View {
    let url: URL
    /// The post's own address (the key for the saved playback spot).
    var resumeKey: URL? = nil
    let isActive: Bool
    var showControls: Bool = true
    var onFinished: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil
    var onFailure: () -> Void

    @StateObject private var holder = ControllerHolder()

    /// Owns the player for as long as the page exists. The pager fires onDisappear for
    /// pages that aren't really leaving, so the player is released here, when SwiftUI drops
    /// the page, not on onDisappear (which restarted the video from the beginning).
    final class ControllerHolder: ObservableObject {
        @Published var controller: VideoController?
        deinit {
            guard let c = controller else { return }
            Task { @MainActor in
                // A video in Picture in Picture keeps playing after the viewer closes.
                if c.pipActive { c.viewGone = true } else { c.teardown() }
            }
        }
    }

    private var key: URL { resumeKey ?? url }

    var body: some View {
        ZStack {
            if let c = holder.controller {
                NativeVideoContent(controller: c, isActive: isActive, showControls: showControls, onTap: onTap, onFailure: onFailure)
                    // A replaced controller gets fresh content (its onAppear reports and autoplays).
                    .id(ObjectIdentifier(c))
            } else {
                Color.black
            }
        }
        .onAppear(perform: prepare)
        .onChange(of: key) { _ in prepare() }
    }

    /// Makes the player if there isn't one for this post. (The pager can hand this view's
    /// state to another post: a player for a different video is replaced.)
    private func prepare() {
        if let c = holder.controller, c.resumeKey != key {
            if c.pipActive { c.viewGone = true } else { c.teardown() }
            holder.controller = nil
        }
        if holder.controller == nil { holder.controller = VideoController(url: url, resumeKey: key) }
        if let c = holder.controller {
            c.isActivePage = isActive
            c.onFinished = { [weak c] in if c?.isActivePage == true { onFinished?() } }
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
                .accessibilityIdentifier("videoSurface")
            // A tap shows or hides the controls (pausing is the Pause button's job); double tap
            // a side to skip 10 s; touch and hold for 2×.
            VideoGestureLayer(isPlaying: controller.isPlaying, onTap: { onTap?() },
                              onSkip: { controller.skip(by: $0) }, onHold: { controller.hold($0) })
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
                           onEditingChanged: { editing in controller.isScrubbing = editing; VideoActivity.shared.scrubbing = editing })
                    .accessibilityIdentifier("videoScrubber")
                    Text(Self.fmt(controller.duration)).font(.caption.monospacedDigit()).foregroundColor(.white)
                    MuteButton()
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
        .onReceive(VideoSound.shared.$muted) { controller.player.isMuted = $0 }
        .onChange(of: controller.isPlaying) { p in if isActive { VideoActivity.shared.report(controller, playing: p) } }
        .onAppear {
            // Built while already the current page: report now (onChange(of: isActive) won't fire).
            if isActive { VideoActivity.shared.report(controller, playing: controller.isPlaying) }
            // Once: the pager fires onAppear again for pages that never left, which used to
            // undo a pause.
            if isActive && AppSettings.shared.videosAutoplay && !controller.autoplayed {
                controller.autoplayed = true
                controller.play()
            }
        }
        .onChange(of: isActive) { active in
            controller.isActivePage = active
            if active { VideoActivity.shared.report(controller, playing: controller.isPlaying) } else { VideoActivity.shared.release(controller) }
            if active { if AppSettings.shared.videosAutoplay { controller.autoplayed = true; controller.play() } } else if !controller.pipActive { controller.pause() }
        }
        // No pause on onDisappear: the pager fires it for the page on screen while you swipe.
        // Leaving the page (isActive) pauses; leaving the viewer releases the player.
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
        if v.playerLayer.player !== player {
            v.playerLayer.player = player
            // Handed to another player: tie that one's Picture in Picture to this layer.
            if let cb = onLayer { DispatchQueue.main.async { cb(v.playerLayer) } }
        }
        v.playerLayer.videoGravity = gravity
    }
}
