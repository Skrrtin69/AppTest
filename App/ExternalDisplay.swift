import SwiftUI
import UIKit

/// When a TV or monitor is connected (cable or AirPlay), the post open in the viewer is
/// shown full screen there while the phone keeps the controls.
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()
    @Published var post: Post?
    @Published private(set) var connected = false

    func setConnected(_ on: Bool) {
        DispatchQueue.main.async { self.connected = on }
    }

    /// Called by the viewer whenever the visible post changes (nil when it closes).
    func show(_ p: Post?) {
        guard AppSettings.shared.useExternalDisplay else { post = nil; return }
        if post?.key != p?.key { post = p }
    }
}

/// Scene delegate for the external screen (role: external display, not interactive).
final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = UIHostingController(rootView: ExternalDisplayView())
        w.isHidden = false
        window = w
        ExternalDisplay.shared.setConnected(true)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        ExternalDisplay.shared.setConnected(false)
    }
}

struct ExternalDisplayView: View {
    @ObservedObject private var display = ExternalDisplay.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = display.post {
                if p.mediaType == .video {
                    ZStack {
                        CachedAsyncImage(url: p.thumbnailURL, maxPixel: 1920, contentMode: .scaleAspectFit)
                        Label("Playing on the phone", systemImage: "iphone").foregroundColor(.white)
                            .padding(10).background(Capsule().fill(Color.black.opacity(0.6)))
                            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 30)
                    }
                } else {
                    CachedAsyncImage(url: p.mediaURL, maxPixel: 3840, contentMode: .scaleAspectFit,
                                     client: AdapterRegistry.shared.adapter(for: p.siteID)?.client)
                        .id(p.key)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 60))
                    Text("MediaDeck").font(.largeTitle.weight(.semibold))
                    Text("Open a post on the phone to show it here.").foregroundColor(.gray)
                }
                .foregroundColor(.white)
            }
        }
    }
}
