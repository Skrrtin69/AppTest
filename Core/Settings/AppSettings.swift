import SwiftUI

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark, amoled, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .amoled: return "AMOLED Black"
        case .custom: return CustomThemeStore.shared.active?.name ?? "Custom"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark, .amoled: return .dark
        case .custom: return (CustomThemeStore.shared.active?.isDark ?? true) ? .dark : .light
        }
    }
    /// The custom theme in use, when this mode is `.custom`.
    var custom: CustomTheme? { self == .custom ? CustomThemeStore.shared.active : nil }
}

enum ThumbAspect: String, CaseIterable, Identifiable {
    case square, original, masonry
    var id: String { rawValue }
    var label: String {
        switch self {
        case .square: return "Square"
        case .original: return "Original"
        case .masonry: return "Masonry (staggered)"
        }
    }
}

/// All user preferences, persisted in UserDefaults. Views observe this object directly.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    enum K {
        static let theme = "theme", gridColumns = "gridColumns", thumbAspect = "thumbAspect"
        static let downloadQuality = "downloadQuality", filenameTemplate = "filenameTemplate", folderTemplate = "folderTemplate"
        static let maxThumbLoads = "maxThumbLoads", maxDownloads = "maxDownloads", cacheLimitMB = "cacheLimitMB"
        static let slideshowInterval = "slideshowInterval", blacklist = "blacklist"
        static let hapticsTap = "hapticsTap", hapticsResult = "hapticsResult"
        static let backgroundDownloads = "backgroundDownloads", biometrics = "biometrics", lockGrace = "lockGrace"
        static let updateURL = "updateURL", animateGridGIFs = "animateGridGIFs", autoplayVideos = "autoplayVideos"
        static let blurThumbnails = "blurThumbnails", dimViewed = "dimViewed"
        static let viewerAspect = "viewerAspect", playbackSpeed = "playbackSpeed", verticalReading = "verticalReading"
        static let warnOnCellular = "warnOnCellular", maxDownloadMB = "maxDownloadMB", gridSpacing = "gridSpacing"
        static let preferLighter = "preferLighter", viewerBackground = "viewerBackground", autoAdvance = "autoAdvance"
        static let readingRTL = "readingRTL", tapZones = "tapZones", rotationLock = "rotationLock"
        static let batterySaver = "batterySaver", cacheExpiryDays = "cacheExpiryDays", hiddenViewerButtons = "hiddenViewerButtons"
        static let swipeSites = "swipeSites", detectClipboardLinks = "detectClipboardLinks", dataSaver = "dataSaver",
                         wifiOnlyMedia = "wifiOnlyMedia", mixWithOthers = "mixWithOthers",
                         smartThumbnails = "smartThumbnails", twoPageLandscape = "twoPageLandscape", fallbackSite = "fallbackSite",
                         stripEXIF = "stripEXIF", autoTagDownloads = "autoTagDownloads", panicGesture = "panicGesture", panicAction = "panicAction",
                         doubleTapAction = "doubleTapAction", swipeUpAction = "swipeUpAction", swipeDownAction = "swipeDownAction",
                         startMuted = "startMuted", edgeSwipes = "edgeSwipes", useVLC = "useVLC"
        static let all = [theme, gridColumns, thumbAspect, downloadQuality, filenameTemplate, folderTemplate,
                          maxThumbLoads, maxDownloads, cacheLimitMB, slideshowInterval, blacklist, hapticsTap,
                          hapticsResult, backgroundDownloads, biometrics, lockGrace, updateURL, animateGridGIFs, autoplayVideos,
                          blurThumbnails, dimViewed, viewerAspect, playbackSpeed, verticalReading,
                          warnOnCellular, maxDownloadMB, gridSpacing, preferLighter, viewerBackground, autoAdvance,
                          readingRTL, tapZones, rotationLock, batterySaver, cacheExpiryDays, hiddenViewerButtons, swipeSites,
                          detectClipboardLinks, dataSaver, wifiOnlyMedia, mixWithOthers,
                          smartThumbnails, twoPageLandscape, fallbackSite, stripEXIF, autoTagDownloads, panicGesture, panicAction, doubleTapAction, swipeUpAction, swipeDownAction, startMuted, edgeSwipes, useVLC]
    }

    static let defaultFilenameTemplate = "{site}_{id}_{index}"
    static let defaultFolderTemplate = "{site}"
    static let defaultUpdateURL = "https://updates.invalid/mediadeck"

    @Published var theme: ThemeMode = .system { didSet { d.set(theme.rawValue, forKey: K.theme) } }
    @Published var gridColumns: Int = 3 { didSet { d.set(gridColumns, forKey: K.gridColumns) } }
    @Published var thumbAspect: ThumbAspect = .square { didSet { d.set(thumbAspect.rawValue, forKey: K.thumbAspect) } }
    @Published var downloadQuality: MediaQuality = .original { didSet { d.set(downloadQuality.rawValue, forKey: K.downloadQuality) } }
    @Published var filenameTemplate: String = defaultFilenameTemplate { didSet { d.set(filenameTemplate, forKey: K.filenameTemplate) } }
    @Published var folderTemplate: String = defaultFolderTemplate { didSet { d.set(folderTemplate, forKey: K.folderTemplate) } }
    @Published var maxThumbLoads: Int = 6 {
        didSet { d.set(maxThumbLoads, forKey: K.maxThumbLoads); ImagePipeline.shared.setConcurrency(maxThumbLoads) }
    }
    @Published var maxDownloads: Int = 3 { didSet { d.set(maxDownloads, forKey: K.maxDownloads) } }
    @Published var cacheLimitMB: Int = 300 { didSet { d.set(cacheLimitMB, forKey: K.cacheLimitMB) } }
    @Published var slideshowInterval: Double = 5 { didSet { d.set(slideshowInterval, forKey: K.slideshowInterval) } }
    @Published var blacklist: [String] = [] { didSet { d.set(blacklist, forKey: K.blacklist) } }
    @Published var hapticsTap: Bool = true { didSet { d.set(hapticsTap, forKey: K.hapticsTap) } }
    @Published var hapticsResult: Bool = true { didSet { d.set(hapticsResult, forKey: K.hapticsResult) } }
    @Published var backgroundDownloads: Bool = true { didSet { d.set(backgroundDownloads, forKey: K.backgroundDownloads) } }
    @Published var biometricsEnabled: Bool = false { didSet { d.set(biometricsEnabled, forKey: K.biometrics) } }
    /// Seconds the app may stay in the background before it locks again.
    @Published var lockGraceSeconds: Int = 0 { didSet { d.set(lockGraceSeconds, forKey: K.lockGrace) } }
    @Published var updateURL: String = defaultUpdateURL { didSet { d.set(updateURL, forKey: K.updateURL) } }
    @Published var animateGridGIFs: Bool = true { didSet { d.set(animateGridGIFs, forKey: K.animateGridGIFs) } }
    @Published var autoplayVideos: Bool = true { didSet { d.set(autoplayVideos, forKey: K.autoplayVideos) } }
    /// Every player (native, web, Picture in Picture) starts with the sound off.
    @Published var startMuted: Bool = false { didSet { d.set(startMuted, forKey: K.startMuted) } }
    /// Viewer edge swipes: left edge = brightness, right edge = volume.
    @Published var edgeSwipes: Bool = true { didSet { d.set(edgeSwipes, forKey: K.edgeSwipes) } }
    /// WebM/Matroska play in VLCKit (native decoding) instead of the web player.
    @Published var useVLC: Bool = true { didSet { d.set(useVLC, forKey: K.useVLC) } }
    /// Thumbnails stay blurred until tapped once.
    @Published var blurThumbnails: Bool = false { didSet { d.set(blurThumbnails, forKey: K.blurThumbnails) } }
    /// Thumbnails of posts already opened are dimmed.
    @Published var dimViewed: Bool = true { didSet { d.set(dimViewed, forKey: K.dimViewed) } }
    @Published var viewerAspect: ViewerAspect = .fit { didSet { d.set(viewerAspect.rawValue, forKey: K.viewerAspect) } }
    /// Video speed for both players: 1, 1.5 or 2.
    @Published var playbackSpeed: Double = 1 { didSet { d.set(playbackSpeed, forKey: K.playbackSpeed) } }
    /// Viewer shows posts stacked vertically (comic/webtoon style) instead of paging.
    @Published var verticalReading: Bool = false { didSet { d.set(verticalReading, forKey: K.verticalReading) } }
    /// Ask before batch/video downloads on cellular or metered data.
    @Published var warnOnCellular: Bool = true { didSet { d.set(warnOnCellular, forKey: K.warnOnCellular) } }
    /// Downloads bigger than this many MB are skipped (0 = no limit).
    @Published var maxDownloadMB: Double = 0 { didSet { d.set(maxDownloadMB, forKey: K.maxDownloadMB) } }
    /// Gap between grid thumbnails, 0–12 points.
    @Published var gridSpacing: Double = 3 { didSet { d.set(gridSpacing, forKey: K.gridSpacing) } }
    /// Viewer shows the site's medium-size (usually JPG/WebP) file when there is one.
    @Published var preferLighter: Bool = false { didSet { d.set(preferLighter, forKey: K.preferLighter) } }
    /// Viewer backdrop: "black", "white" or "checker".
    @Published var viewerBackground: String = "black" { didSet { d.set(viewerBackground, forKey: K.viewerBackground) } }
    /// End of media: false = loop the current post, true = move on (videos when finished,
    /// GIFs after one cycle, images after the slideshow interval).
    @Published var autoAdvance: Bool = false { didSet { d.set(autoAdvance, forKey: K.autoAdvance) } }
    /// Right-to-left page order (manga): swipe right for the next post.
    @Published var readingRTL: Bool = false { didSet { d.set(readingRTL, forKey: K.readingRTL) } }
    /// Tap the left/right edge of a picture to turn the page; the middle shows the controls.
    @Published var tapZones: Bool = false { didSet { d.set(tapZones, forKey: K.tapZones) } }
    /// Viewer rotation: "auto", "portrait" or "landscape".
    @Published var rotationLock: String = "auto" { didSet { d.set(rotationLock, forKey: K.rotationLock) } }
    /// "off", "auto" (when iOS Low Power Mode is on) or "on".
    @Published var batterySaver: String = "auto" { didSet { d.set(batterySaver, forKey: K.batterySaver) } }
    /// Cached files not opened for this many days are deleted (0 = never).
    @Published var cacheExpiryDays: Int = 0 { didSet { d.set(cacheExpiryDays, forKey: K.cacheExpiryDays) } }
    /// Viewer toolbar buttons moved into the ⋯ menu (see ViewerButton).
    @Published var hiddenViewerButtons: [String] = ViewerButton.defaultHidden { didSet { d.set(hiddenViewerButtons, forKey: K.hiddenViewerButtons) } }
    /// Swipe sideways on the site name to switch sites.
    @Published var swipeSites: Bool = true { didSet { d.set(swipeSites, forKey: K.swipeSites) } }

    /// Offer to open copied web links that belong to one of the user's sites.
    @Published var detectClipboardLinks: Bool = true { didSet { d.set(detectClipboardLinks, forKey: K.detectClipboardLinks) } }
    /// "off", "cellular" (on mobile data / Low Data Mode) or "always": the viewer shows the
    /// lighter file first, with a Load Full Resolution button.
    @Published var dataSaver: String = "off" { didSet { d.set(dataSaver, forKey: K.dataSaver) } }

    /// On mobile data, full-size pictures and videos wait for a tap (thumbnails still load).
    @Published var wifiOnlyMedia: Bool = false { didSet { d.set(wifiOnlyMedia, forKey: K.wifiOnlyMedia) } }

    /// Video sound mixes with other apps' audio instead of interrupting it.
    @Published var mixWithOthers: Bool = false { didSet { d.set(mixWithOthers, forKey: K.mixWithOthers) } }

    /// Square thumbnails are cropped around the interesting part of the picture.
    @Published var smartThumbnails: Bool = true { didSet { d.set(smartThumbnails, forKey: K.smartThumbnails) } }
    /// Remove camera data (EXIF, GPS, XMP) from downloaded pictures.
    @Published var stripEXIF: Bool = false { didSet { d.set(stripEXIF, forKey: K.stripEXIF) } }
    /// Add hidden visual tags (on-device recognition) to downloaded pictures, for Library search.
    @Published var autoTagDownloads: Bool = false { didSet { d.set(autoTagDownloads, forKey: K.autoTagDownloads) } }
    /// Panic gesture: "off", "shake" or "twoFingerSwipe"; what it shows: "blur" or "calculator".
    @Published var panicGesture: String = "off" { didSet { d.set(panicGesture, forKey: K.panicGesture) } }
    @Published var panicAction: String = "blur" { didSet { d.set(panicAction, forKey: K.panicAction) } }
    /// Site offered when a search fails because the site is down or busy ("" = none).
    @Published var fallbackSite: String = "" { didSet { d.set(fallbackSite, forKey: K.fallbackSite) } }
    /// Two posts side by side when the phone is sideways (like an open book).
    @Published var twoPageLandscape: Bool = true { didSet { d.set(twoPageLandscape, forKey: K.twoPageLandscape) } }
    /// Viewer gestures: what a double tap / swipe up / swipe down does.
    @Published var doubleTapAction: String = "zoom" { didSet { d.set(doubleTapAction, forKey: K.doubleTapAction) } }
    @Published var swipeUpAction: String = "hide" { didSet { d.set(swipeUpAction, forKey: K.swipeUpAction) } }
    @Published var swipeDownAction: String = "close" { didSet { d.set(swipeDownAction, forKey: K.swipeDownAction) } }

    var mediaWaitsForWiFi: Bool { wifiOnlyMedia && NetworkStatus.shared.onMeteredData }

    var dataSaverActive: Bool {
        dataSaver == "always" || (dataSaver == "cellular" && NetworkStatus.shared.onMeteredData)
    }

    /// Battery Saver in effect right now: no GIF animation in grids, no video autoplay,
    /// lighter files in the viewer, no preloading of neighbouring posts.
    var savingPower: Bool {
        batterySaver == "on" || (batterySaver == "auto" && ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    var gridGIFsAnimate: Bool { animateGridGIFs && !savingPower }
    var videosAutoplay: Bool { autoplayVideos && !savingPower }
    var viewerPrefersLighter: Bool { preferLighter || savingPower }

    func showsInToolbar(_ b: ViewerButton) -> Bool { !hiddenViewerButtons.contains(b.rawValue) }

    func cycleViewerBackground() {
        switch viewerBackground {
        case "black": viewerBackground = "white"
        case "white": viewerBackground = "checker"
        case "checker": viewerBackground = "color"
        default: viewerBackground = "black"
        }
    }

    /// Columns to use right now: two more when the phone is sideways.
    func columns(landscape: Bool) -> Int { landscape ? gridColumns + 2 : gridColumns }

    func cycleSpeed() {
        playbackSpeed = playbackSpeed >= 2 ? 1 : (playbackSpeed >= 1.5 ? 2 : 1.5)
    }

    private init() {
        load()
        // Battery Saver "auto" follows iOS Low Power Mode as it switches on and off.
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// (Re)reads every value from UserDefaults.
    func load() {
        theme = ThemeMode(rawValue: d.string(forKey: K.theme) ?? "") ?? .system
        gridColumns = Self.clamp(d.object(forKey: K.gridColumns) as? Int ?? 3, 2, 5)
        thumbAspect = ThumbAspect(rawValue: d.string(forKey: K.thumbAspect) ?? "") ?? .square
        downloadQuality = MediaQuality(rawValue: d.string(forKey: K.downloadQuality) ?? "") ?? .original
        filenameTemplate = d.string(forKey: K.filenameTemplate)?.nonEmpty ?? Self.defaultFilenameTemplate
        folderTemplate = d.string(forKey: K.folderTemplate) ?? Self.defaultFolderTemplate
        maxThumbLoads = Self.clamp(d.object(forKey: K.maxThumbLoads) as? Int ?? 6, 1, 16)
        maxDownloads = Self.clamp(d.object(forKey: K.maxDownloads) as? Int ?? 3, 1, 8)
        cacheLimitMB = Self.clamp(d.object(forKey: K.cacheLimitMB) as? Int ?? 300, 50, 4000)
        slideshowInterval = min(30, max(2, d.object(forKey: K.slideshowInterval) as? Double ?? 5))
        blacklist = d.stringArray(forKey: K.blacklist) ?? []
        hapticsTap = d.object(forKey: K.hapticsTap) as? Bool ?? true
        hapticsResult = d.object(forKey: K.hapticsResult) as? Bool ?? true
        backgroundDownloads = d.object(forKey: K.backgroundDownloads) as? Bool ?? true
        biometricsEnabled = d.object(forKey: K.biometrics) as? Bool ?? false
        lockGraceSeconds = d.object(forKey: K.lockGrace) as? Int ?? 0
        updateURL = d.string(forKey: K.updateURL)?.nonEmpty ?? Self.defaultUpdateURL
        animateGridGIFs = d.object(forKey: K.animateGridGIFs) as? Bool ?? true
        autoplayVideos = d.object(forKey: K.autoplayVideos) as? Bool ?? true
        startMuted = d.object(forKey: K.startMuted) as? Bool ?? false
        edgeSwipes = d.object(forKey: K.edgeSwipes) as? Bool ?? true
        useVLC = d.object(forKey: K.useVLC) as? Bool ?? true
        blurThumbnails = d.object(forKey: K.blurThumbnails) as? Bool ?? false
        dimViewed = d.object(forKey: K.dimViewed) as? Bool ?? true
        viewerAspect = ViewerAspect(rawValue: d.string(forKey: K.viewerAspect) ?? "") ?? .fit
        playbackSpeed = d.object(forKey: K.playbackSpeed) as? Double ?? 1
        verticalReading = d.object(forKey: K.verticalReading) as? Bool ?? false
        warnOnCellular = d.object(forKey: K.warnOnCellular) as? Bool ?? true
        maxDownloadMB = d.object(forKey: K.maxDownloadMB) as? Double ?? 0
        gridSpacing = min(12, max(0, d.object(forKey: K.gridSpacing) as? Double ?? 3))
        preferLighter = d.object(forKey: K.preferLighter) as? Bool ?? false
        viewerBackground = d.string(forKey: K.viewerBackground) ?? "black"
        autoAdvance = d.object(forKey: K.autoAdvance) as? Bool ?? false
        readingRTL = d.object(forKey: K.readingRTL) as? Bool ?? false
        tapZones = d.object(forKey: K.tapZones) as? Bool ?? false
        rotationLock = d.string(forKey: K.rotationLock) ?? "auto"
        batterySaver = d.string(forKey: K.batterySaver) ?? "auto"
        cacheExpiryDays = d.object(forKey: K.cacheExpiryDays) as? Int ?? 0
        // The first default (before the interval button moved to the menu) is upgraded.
        let storedHidden = d.stringArray(forKey: K.hiddenViewerButtons)
        hiddenViewerButtons = storedHidden == ["direction", "tapZones", "rotation"] ? ViewerButton.defaultHidden
            : (storedHidden ?? ViewerButton.defaultHidden)
        swipeSites = d.object(forKey: K.swipeSites) as? Bool ?? true
        detectClipboardLinks = d.object(forKey: K.detectClipboardLinks) as? Bool ?? true
        dataSaver = d.string(forKey: K.dataSaver) ?? "off"
        wifiOnlyMedia = d.object(forKey: K.wifiOnlyMedia) as? Bool ?? false
        mixWithOthers = d.object(forKey: K.mixWithOthers) as? Bool ?? false
        smartThumbnails = d.object(forKey: K.smartThumbnails) as? Bool ?? true
        twoPageLandscape = d.object(forKey: K.twoPageLandscape) as? Bool ?? true
        fallbackSite = d.string(forKey: K.fallbackSite) ?? ""
        stripEXIF = d.object(forKey: K.stripEXIF) as? Bool ?? false
        autoTagDownloads = d.object(forKey: K.autoTagDownloads) as? Bool ?? false
        panicGesture = d.string(forKey: K.panicGesture) ?? "off"
        panicAction = d.string(forKey: K.panicAction) ?? "blur"
        doubleTapAction = d.string(forKey: K.doubleTapAction) ?? "zoom"
        swipeUpAction = d.string(forKey: K.swipeUpAction) ?? "hide"
        swipeDownAction = d.string(forKey: K.swipeDownAction) ?? "close"
    }

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(hi, max(lo, v)) }

    var blacklistSet: Set<String> { Set(blacklist.map { $0.lowercased() }) }

    func isBlacklisted(_ post: Post) -> Bool {
        Self.hides(post, blacklistSet)
    }

    /// A post is hidden when one of its tags is blacklisted, or its uploader is muted
    /// (muted uploaders are stored in the blacklist as "uploader:name").
    static func hides(_ post: Post, _ bl: Set<String>) -> Bool {
        guard !bl.isEmpty else { return false }
        if let u = post.uploader, bl.contains("uploader:" + u.lowercased()) { return true }
        return post.tags.contains { bl.contains($0.lowercased()) }
    }

    func muteUploader(_ name: String) {
        let entry = "uploader:" + name.lowercased()
        if !blacklist.contains(entry) { blacklist.append(entry) }
    }

    // MARK: Import / export / reset

    func exportJSON() throws -> Data {
        var dict: [String: Any] = ["_format": "MediaDeck settings", "_version": 1]
        for k in K.all { if let v = d.object(forKey: k) { dict[k] = v } }
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    func importJSON(_ data: Data) throws {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("That file isn't a MediaDeck settings file.")
        }
        var applied = 0
        for k in K.all { if let v = dict[k] { d.set(v, forKey: k); applied += 1 } }
        guard applied > 0 else { throw AppError.message("That file doesn't contain any MediaDeck settings.") }
        load()
    }

    func resetAll() {
        for k in K.all { d.removeObject(forKey: k) }
        load()
    }
}
