import SwiftUI
import UIKit

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
        if await MockServer.shared.start() == nil {
            serverProblem = "The built-in demo server couldn't start, so the demo sites won't load. Your own adapters still work."
            ToastCenter.shared.show(serverProblem!, style: .error)
        }
        AdapterRegistry.shared.bootstrap()
        DownloadManager.shared.bootstrap()
        BrowseModel.shared.ensureTab()
        ready = true
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

    var body: some View {
        ZStack {
            if boot.ready {
                TabView(selection: $router.tab) {
                    BrowseView()
                        .tabItem { Label("Browse", systemImage: "square.grid.3x3") }
                        .tag(AppRouter.Tab.browse)
                    FavoritesView()
                        .tabItem { Label("Favorites", systemImage: "heart") }
                        .tag(AppRouter.Tab.favorites)
                    LibraryView()
                        .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
                        .tag(AppRouter.Tab.library)
                    DownloadsView()
                        .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                        .badge(downloads.queue.count)
                        .tag(AppRouter.Tab.downloads)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppRouter.Tab.settings)
                }
                // Rebuild UIKit-backed chrome when the theme changes so AMOLED colors apply.
                .id(settings.theme)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting…").foregroundColor(.secondary)
                }
            }

            ToastOverlay()

            if lock.obscured && !lock.isLocked {
                Color(UIColor.systemBackground).ignoresSafeArea()
                    .overlay(Image(systemName: "lock.fill").font(.largeTitle).foregroundColor(.secondary))
            }
            if lock.isLocked {
                LockScreenView().transition(.opacity).zIndex(10)
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .onChange(of: settings.theme) { Theme.apply($0) }
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
        }
        let black = mode == .amoled
        UITableView.appearance().backgroundColor = black ? .black : nil
        UICollectionView.appearance().backgroundColor = black ? .black : nil
        let nav = UINavigationBarAppearance()
        let tab = UITabBarAppearance()
        if black {
            nav.configureWithOpaqueBackground(); nav.backgroundColor = .black
            tab.configureWithOpaqueBackground(); tab.backgroundColor = .black
        } else {
            nav.configureWithDefaultBackground()
            tab.configureWithDefaultBackground()
        }
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in scene.windows { w.overrideUserInterfaceStyle = style }
        }
    }
}
