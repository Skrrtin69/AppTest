import SwiftUI
import UIKit
import Combine

/// A window above every sheet and full-screen cover. It shows toasts, the privacy cover
/// and the lock screen, so none of them can be hidden behind presented content.
/// Touches pass through to the app unless the lock screen is showing.
enum OverlayWindow {
    private static var window: PassthroughWindow?
    private static var cancellable: AnyCancellable?

    static func install() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = PassthroughWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        let host = UIHostingController(rootView: OverlayRoot())
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
        // Only intercept touches while locked or covered.
        cancellable = LockManager.shared.$isLocked
            .combineLatest(LockManager.shared.$obscured)
            .receive(on: DispatchQueue.main)
            .sink { locked, obscured in
                w.passthrough = !(locked || obscured)
                if locked { w.makeKey() }
            }
    }
}

final class PassthroughWindow: UIWindow {
    var passthrough = true
    /// Where the current toast is on screen; touches there go to the toast (X / swipe up).
    static var toastFrame: CGRect?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let f = Self.toastFrame, f.contains(point) { return super.hitTest(point, with: event) }
        return passthrough ? nil : super.hitTest(point, with: event)
    }
}

private struct OverlayRoot: View {
    @ObservedObject private var lock = LockManager.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            if lock.obscured && !lock.isLocked {
                Color(UIColor.systemBackground).ignoresSafeArea()
                    .overlay(Image(systemName: "lock.fill").font(.largeTitle).foregroundColor(.secondary))
            }
            if lock.isLocked {
                LockScreenView().transition(.opacity)
            }
            ToastOverlay()
        }
        .preferredColorScheme(settings.theme.colorScheme)
    }
}
