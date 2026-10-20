import SwiftUI
import UIKit
import AVFoundation

@main
struct MediaDeckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var boot = BootModel()

    var body: some Scene {
        WindowGroup {
            RootView(boot: boot)
                .task { await boot.start() }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                LockManager.shared.didEnterBackground()
            case .active:
                LockManager.shared.willEnterForeground()
                Task { await boot.resume() }
                if boot.ready {
                    ClipboardWatcher.shared.check()
                    ShareInbox.process()
                    SearchWatch.shared.checkIfDue()
                    Task { await FollowStore.shared.checkIfDue() }
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background refresh for watched saved searches must be registered before launch ends.
        SearchWatch.register()
        SearchWatch.schedule()
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}

/// Startup: demo server first (adapters need its port), then adapters, then downloads.
@MainActor
final class BootModel: ObservableObject {
    @Published var ready = false
    @Published var serverProblem: String?
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        Theme.apply(AppSettings.shared.theme)
        OverlayWindow.install()
        // Video sound plays even with the silent switch on, like other media apps.
        AudioSessionConfig.apply()
        if await MockServer.shared.start() == nil {
            serverProblem = "The built-in demo server couldn't start, so the demo sites won't load. Your own adapters still work."
            ToastCenter.shared.show(serverProblem!, style: .error)
        }
        AdapterRegistry.shared.bootstrap()
        DownloadManager.shared.bootstrap()
        BrowseModel.shared.ensureTab()
        AppRouter.shared.markReady()
        ready = true
        ClipboardWatcher.shared.check()
        ShareInbox.process()
        WidgetFeedWriter.scheduleUpdate()
        PanicManager.shared.installSwipe()
        // The web video player's process and files, ready before the first WebM.
        WebVideoView.prewarm()
        // Download speed sets how long a web video may take to start.
        Task { await NetworkSpeed.shared.measure() }
        Task { await FollowStore.shared.checkIfDue() }
        // Cached files not opened within the chosen number of days.
        Task.detached(priority: .background) { await ImageCache.shared.expire() }
        if let e = CoreDataStack.shared.loadError {
            ToastCenter.shared.show("Your saved library couldn't be read and was reset: \(e.localizedDescription)", style: .error)
        }
    }

    /// iOS may tear down the listener while suspended; bring it back on the same port.
    func resume() async {
        guard started, !MockServer.shared.isRunning else { return }
        let old = MockServer.shared.port
        if let p = await MockServer.shared.start(), p != old {
            AdapterRegistry.shared.reload()
        }
    }
}

struct RootView: View {
    @ObservedObject var boot: BootModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var lock = LockManager.shared
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var customThemes = CustomThemeStore.shared

    var body: some View {
        ZStack {
            if boot.ready {
                TabView(selection: $router.tab) {
                    BrowseView()
                        .tabItem { Label("Browse", systemImage: "square.grid.3x3") }
                        .tag(AppRouter.Tab.browse)
                    PoolsView()
                        .tabItem { Label("Pools", systemImage: "books.vertical") }
                        .tag(AppRouter.Tab.pools)
                    FavoritesView()
                        .tabItem { Label("Favorites", systemImage: "heart") }
                        .tag(AppRouter.Tab.favorites)
                    // The download queue opens from the Library (a sixth tab would hide under "More").
                    LibraryView()
                        .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
                        .badge(downloads.queue.count)
                        .tag(AppRouter.Tab.library)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppRouter.Tab.settings)
                }
                // Rebuild UIKit-backed chrome when the theme changes so AMOLED/custom colors apply.
                .id("\(settings.theme.rawValue)-\(customThemes.activeID ?? "")-\(customThemes.active.map { $0.background + $0.surface + $0.accent + $0.text } ?? "")")
                .accentColor(settings.theme.custom.map { Color(hex: $0.accent) })
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting…").foregroundColor(.secondary)
                }
            }

            // Toasts, privacy cover and lock screen live in OverlayWindow (above sheets).
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .onChange(of: settings.theme) { Theme.apply($0) }
        .onChange(of: settings.mixWithOthers) { _ in AudioSessionConfig.apply() }
        .onOpenURL { url in Task { @MainActor in ShareInbox.handle(url) } }
    }
}

/// UIKit-level theme: window style override and AMOLED pure-black chrome.
enum Theme {
    static func apply(_ mode: ThemeMode) {
        let style: UIUserInterfaceStyle
        switch mode {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark, .amoled: style = .dark
        case .custom: style = (CustomThemeStore.shared.active?.isDark ?? true) ? .dark : .light
        }
        let black = mode == .amoled
        let custom = mode.custom
        // Custom theme: its background behind lists, its surface color on the bars.
        let listBG: UIColor? = custom.map { UIColor(hex: $0.background) } ?? (black ? .black : nil)
        UITableView.appearance().backgroundColor = listBG
        UICollectionView.appearance().backgroundColor = listBG
        let nav = UINavigationBarAppearance()
        let tab = UITabBarAppearance()
        if let c = custom {
            let surface = UIColor(hex: c.surface), text = UIColor(hex: c.text)
            nav.configureWithOpaqueBackground(); nav.backgroundColor = surface
            nav.titleTextAttributes = [.foregroundColor: text]; nav.largeTitleTextAttributes = [.foregroundColor: text]
            tab.configureWithOpaqueBackground(); tab.backgroundColor = surface
            UITableViewCell.appearance().backgroundColor = surface
        } else if black {
            UITableViewCell.appearance().backgroundColor = nil
            nav.configureWithOpaqueBackground(); nav.backgroundColor = .black
            tab.configureWithOpaqueBackground(); tab.backgroundColor = .black
        } else {
            UITableViewCell.appearance().backgroundColor = nil
            nav.configureWithDefaultBackground()
            tab.configureWithDefaultBackground()
        }
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        let tint = custom.map { UIColor(hex: $0.accent) }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in scene.windows {
                w.overrideUserInterfaceStyle = style
                w.tintColor = tint
            }
        }
    }
}

/// Video sound plays even with the silent switch on, like other media apps. With "Play
/// alongside other audio" on, it mixes with music or podcasts instead of stopping them.
enum AudioSessionConfig {
    static func apply() {
        let options: AVAudioSession.CategoryOptions = AppSettings.shared.mixWithOthers ? [.mixWithOthers] : []
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: options)
    }
}
