import SwiftUI
import UIKit

// MARK: - Gestures on a video

/// Taps and holds on a video, for both the native player and VLCKit:
/// - one tap: show or hide the controls (as before),
/// - double tap on the left or right third: back or forward 10 s (taps in a row add up),
///   in the middle third: same as one tap,
/// - press and hold: 2× while the finger is down.
/// Sideways swipes still turn the page: taps fail once the finger moves.
struct VideoGestureLayer: View {
    var isPlaying: Bool
    var onTap: () -> Void
    /// Seconds to move (negative = back).
    var onSkip: (Double) -> Void
    /// true while held.
    var onHold: (Bool) -> Void

    static let step: Double = 10

    @State private var bubble: Bubble?
    @State private var holding = false

    struct Bubble: Equatable {
        var forward: Bool
        var seconds: Int
        var at: Date
    }

    var body: some View {
        ZStack {
            TouchCatcher(onSingle: onTap, onDouble: double, onHold: hold)
                .accessibilityElement()
                .accessibilityLabel(isPlaying ? "Video playing, tap for controls" : "Video paused, tap for controls")
                .accessibilityHint("Double-tap the left or right side to skip 10 seconds; touch and hold for double speed.")
                .accessibilityIdentifier("videoGestures")
            if let b = bubble {
                HStack {
                    if b.forward { Spacer() }
                    Label("\(b.seconds) s", systemImage: b.forward ? "goforward" : "gobackward")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(.horizontal, 36)
                    if !b.forward { Spacer() }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityIdentifier("skipBubble")
            }
            if holding {
                VStack {
                    Label("2×", systemImage: "forward.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(.top, 150)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityIdentifier("holdFastBadge")
            }
        }
    }

    /// x is 0…1 across the video.
    private func double(_ x: CGFloat) {
        guard x < 1.0 / 3 || x > 2.0 / 3 else { onTap(); return }
        let forward = x > 2.0 / 3
        onSkip(forward ? Self.step : -Self.step)
        Haptics.tap()
        // Double taps in a row on the same side add up in the bubble.
        let now = Date()
        var total = Int(Self.step)
        if let b = bubble, b.forward == forward, now.timeIntervalSince(b.at) < 1.2 { total = b.seconds + Int(Self.step) }
        let shown = Bubble(forward: forward, seconds: total, at: now)
        withAnimation(.easeOut(duration: 0.15)) { bubble = shown }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if bubble == shown { withAnimation(.easeIn(duration: 0.2)) { bubble = nil } }
        }
    }

    private func hold(_ on: Bool) {
        guard on != holding else { return }
        if on { Haptics.tap() }
        withAnimation(.easeOut(duration: 0.15)) { holding = on }
        onHold(on)
    }
}

/// UIKit recognizers, because SwiftUI's tap gesture has no location before iOS 16 and
/// can't tell a hold's end. The single tap waits for the double tap to fail (about a
/// quarter second), like other video apps.
private struct TouchCatcher: UIViewRepresentable {
    var onSingle: () -> Void
    var onDouble: (CGFloat) -> Void
    var onHold: (Bool) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchCatcher
        init(_ p: TouchCatcher) { parent = p }

        @objc func single(_ g: UITapGestureRecognizer) { parent.onSingle() }
        @objc func double(_ g: UITapGestureRecognizer) {
            guard let v = g.view, v.bounds.width > 0 else { return }
            parent.onDouble(g.location(in: v).x / v.bounds.width)
        }
        @objc func hold(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: parent.onHold(true)
            case .ended, .cancelled, .failed: parent.onHold(false)
            default: break
            }
        }
        // Never block the pager's swipe or the viewer's swipe-down.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other is UITapGestureRecognizer) && !(other is UILongPressGestureRecognizer)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.double(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.single(_:)))
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.35
        single.require(toFail: double)
        // A quick tap lifts the finger before the hold time, so this adds no delay.
        single.require(toFail: hold)
        double.require(toFail: hold)
        [double, single, hold].forEach { $0.delegate = c; v.addGestureRecognizer($0) }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) { context.coordinator.parent = self }
}

// MARK: - Resume where you left off

/// Where each long video was left, so reopening it continues from there. Only videos of a
/// minute or more are remembered; the spot is forgotten near the start or the end.
final class VideoResumeStore {
    static let shared = VideoResumeStore()
    static let minimumDuration: Double = 60

    private struct Entry: Codable { var t: Double; var at: Date }
    private let key = "videoResumePositions"
    private let limit = 300
    private let lock = NSLock()
    private var map: [String: Entry] = [:]
    private var lastWrite = Date.distantPast

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let m = try? JSONDecoder().decode([String: Entry].self, from: data) { map = m }
    }

    private func id(_ url: URL) -> String { url.absoluteString }

    /// The saved spot in seconds, if there is a useful one.
    func position(for url: URL) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let e = map[id(url)], e.t >= 5 else { return nil }
        return e.t
    }

    /// Called often while playing; writes to disk at most every few seconds (or now with force).
    func save(_ t: Double, duration: Double, for url: URL, force: Bool = false) {
        guard t.isFinite, duration.isFinite else { return }
        lock.lock()
        let k = id(url)
        if duration < Self.minimumDuration { lock.unlock(); return }
        if t < 5 || t > duration - 5 {
            let had = map.removeValue(forKey: k) != nil
            lock.unlock()
            if had { persist() }
            return
        }
        map[k] = Entry(t: t, at: Date())
        let due = force || Date().timeIntervalSince(lastWrite) > 5
        lock.unlock()
        if due { persist() }
    }

    func clear(_ url: URL) {
        lock.lock(); let had = map.removeValue(forKey: id(url)) != nil; lock.unlock()
        if had { persist() }
    }

    private func persist() {
        lock.lock()
        if map.count > limit {
            let keep = map.sorted { $0.value.at > $1.value.at }.prefix(limit)
            map = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let data = try? JSONEncoder().encode(map)
        lastWrite = Date()
        lock.unlock()
        if let d = data { UserDefaults.standard.set(d, forKey: key) }
    }

    static func format(_ s: Double) -> String {
        let t = max(0, Int(s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - How much of a video has come in

/// Bytes the local proxy has passed on per video address, for "4.2 of 47 MB" while a
/// web or VLC video loads. Updated from the proxy's network thread, published on main
/// at most twice a second.
final class ProxyProgress: ObservableObject {
    static let shared = ProxyProgress()
    struct Entry: Equatable { var received: Int64; var total: Int64 }

    @Published private(set) var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private var pending: [String: Entry] = [:]
    private var scheduled = false

    func entry(for url: URL) -> Entry? { entries[url.absoluteString] }

    /// A 206 answer began: learn the file's full size from its Content-Range.
    func began(_ url: URL, contentRange: String?) {
        guard let total = contentRange?.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 else { return }
        update(url) { $0.total = total }
    }

    func received(_ url: URL, bytes: Int) {
        update(url) { $0.received += Int64(bytes) }
    }

    private func update(_ url: URL, _ change: (inout Entry) -> Void) {
        let k = url.absoluteString
        lock.lock()
        var e = pending[k] ?? entries[k] ?? Entry(received: 0, total: 0)
        change(&e)
        if e.total > 0 { e.received = min(e.received, e.total) }
        pending[k] = e
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let batch = self.pending
            self.pending = [:]
            self.scheduled = false
            self.lock.unlock()
            for (k, v) in batch { self.entries[k] = v }
            // Keep the table small: the newest few dozen videos are enough.
            if self.entries.count > 60 { self.entries = Dictionary(uniqueKeysWithValues: self.entries.suffix(40).map { ($0.key, $0.value) }) }
        }
    }

    static func mb(_ bytes: Int64) -> String {
        let m = Double(bytes) / 1_048_576
        return m >= 10 ? String(format: "%.0f MB", m) : String(format: "%.1f MB", m)
    }
}

/// "4.2 of 47 MB" under "Loading video...". Its own view, so progress updates don't
/// redraw the player.
struct LoadingProgressText: View {
    let url: URL
    @ObservedObject private var progress = ProxyProgress.shared

    var body: some View {
        if let e = progress.entry(for: url), e.received > 0 {
            Text(e.total > 0 ? "\(ProxyProgress.mb(e.received)) of \(ProxyProgress.mb(e.total))" : "\(ProxyProgress.mb(e.received))")
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.85))
                .accessibilityIdentifier("videoLoadProgress")
        }
    }
}

// MARK: - File size before playing on mobile data

/// Asks the site how big a file is without downloading it (HEAD, or a 1-byte range when the
/// site refuses HEAD). Remembered for the session.
actor MediaSize {
    static let shared = MediaSize()
    private var known: [URL: Int64] = [:]
    private var failed = Set<URL>()

    func size(of url: URL, siteID: String?) async -> Int64? {
        if let s = known[url] { return s }
        if failed.contains(url) || url.isFileURL { return nil }
        let client = siteID.flatMap { AdapterRegistry.shared.adapter(for: $0)?.client } ?? NetworkClient.forMedia(url)
        var head = URLRequest(url: url, timeoutInterval: 15)
        head.httpMethod = "HEAD"
        for (k, v) in client.mediaHeaders { head.setValue(v, forHTTPHeaderField: k) }
        if let res = try? await client.session.data(for: head), let h = res.1 as? HTTPURLResponse,
           (200..<300).contains(h.statusCode), h.expectedContentLength > 0 {
            known[url] = h.expectedContentLength
            return h.expectedContentLength
        }
        var one = URLRequest(url: url, timeoutInterval: 15)
        for (k, v) in client.mediaHeaders { one.setValue(v, forHTTPHeaderField: k) }
        one.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let res = try? await client.session.data(for: one), let h = res.1 as? HTTPURLResponse,
           let total = h.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 {
            known[url] = total
            return total
        }
        failed.insert(url)
        return nil
    }
}
