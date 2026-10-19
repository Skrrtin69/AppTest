import SwiftUI

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark, amoled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .amoled: return "AMOLED Black"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark, .amoled: return .dark
        }
    }
}

enum ThumbAspect: String, CaseIterable, Identifiable {
    case square, original
    var id: String { rawValue }
    var label: String { self == .square ? "Square" : "Original" }
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
        static let all = [theme, gridColumns, thumbAspect, downloadQuality, filenameTemplate, folderTemplate,
                          maxThumbLoads, maxDownloads, cacheLimitMB, slideshowInterval, blacklist, hapticsTap,
                          hapticsResult, backgroundDownloads, biometrics, lockGrace, updateURL, animateGridGIFs, autoplayVideos,
                          blurThumbnails, dimViewed]
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
    /// Thumbnails stay blurred until tapped once.
    @Published var blurThumbnails: Bool = false { didSet { d.set(blurThumbnails, forKey: K.blurThumbnails) } }
    /// Thumbnails of posts already opened are dimmed.
    @Published var dimViewed: Bool = true { didSet { d.set(dimViewed, forKey: K.dimViewed) } }

    private init() { load() }

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
        blurThumbnails = d.object(forKey: K.blurThumbnails) as? Bool ?? false
        dimViewed = d.object(forKey: K.dimViewed) as? Bool ?? true
    }

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(hi, max(lo, v)) }

    var blacklistSet: Set<String> { Set(blacklist.map { $0.lowercased() }) }

    func isBlacklisted(_ post: Post) -> Bool {
        let bl = blacklistSet
        guard !bl.isEmpty else { return false }
        return post.tags.contains { bl.contains($0.lowercased()) }
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
