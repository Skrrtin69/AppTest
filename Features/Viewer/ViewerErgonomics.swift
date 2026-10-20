import SwiftUI
import UIKit

/// Viewer top-bar buttons that can be shown in the bar or moved into its ⋯ menu.
enum ViewerButton: String, CaseIterable, Identifiable {
    case interval, advance, slideshow, aspect, vertical, direction, tapZones, rotation, background
    var id: String { rawValue }

    /// Shown in the ⋯ menu until the user moves them into the bar.
    static let defaultHidden = [ViewerButton.interval, .direction, .tapZones, .rotation].map(\.rawValue)

    var title: String {
        switch self {
        case .interval: return "Slideshow interval"
        case .advance: return "Loop / Auto-advance"
        case .slideshow: return "Slideshow"
        case .aspect: return "Image size (Fit / Fill / 1:1)"
        case .vertical: return "Vertical reading"
        case .direction: return "Reading direction (left/right)"
        case .tapZones: return "Tap edges to turn pages"
        case .rotation: return "Rotation lock"
        case .background: return "Background color"
        }
    }

    var icon: String {
        switch self {
        case .interval: return "timer"
        case .advance: return "repeat.1"
        case .slideshow: return "play.circle"
        case .aspect: return "aspectratio"
        case .vertical: return "rectangle.split.1x2"
        case .direction: return "arrow.left.arrow.right"
        case .tapZones: return "hand.tap"
        case .rotation: return "lock.rotation"
        case .background: return "circle.lefthalf.filled"
        }
    }
}

/// Settings › Viewer toolbar: pick which buttons sit in the bar; the rest stay in ⋯.
struct ViewerToolbarSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        List {
            Section {
                ForEach(ViewerButton.allCases) { b in
                    Toggle(isOn: Binding(get: { settings.showsInToolbar(b) }, set: { on in
                        var hidden = Set(settings.hiddenViewerButtons)
                        if on { hidden.remove(b.rawValue) } else { hidden.insert(b.rawValue) }
                        settings.hiddenViewerButtons = ViewerButton.allCases.map(\.rawValue).filter(hidden.contains)
                    })) {
                        Label(b.title, systemImage: b.icon)
                    }
                }
            } footer: {
                Text("Buttons that are switched off aren't gone: they're in the viewer's ⋯ menu. Close, the page counter and Info are always shown.")
            }
            Section {
                Button("Restore default") { settings.hiddenViewerButtons = ViewerButton.defaultHidden }
            }
        }
        .navigationTitle("Viewer Toolbar")
    }
}

/// Locks the screen rotation while the viewer is open.
enum OrientationLock {
    /// What the app allows right now; read by AppDelegate.
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    static func apply(_ mode: String) {
        let newMask: UIInterfaceOrientationMask
        switch mode {
        case "portrait": newMask = .portrait
        case "landscape": newMask = .landscape
        default: newMask = .allButUpsideDown
        }
        mask = newMask
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if #available(iOS 16.0, *) {
            for scene in scenes {
                // Every controller in the chain (the viewer is presented over the root) must
                // re-read the allowed orientations, or the request is ignored.
                for window in scene.windows {
                    var vc = window.rootViewController
                    while let c = vc {
                        c.setNeedsUpdateOfSupportedInterfaceOrientations()
                        vc = c.presentedViewController
                    }
                }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { error in
                    NSLog("[Rotation] %@", error.localizedDescription)
                }
            }
        } else {
            let target: UIInterfaceOrientation? = mode == "portrait" ? .portrait : (mode == "landscape" ? .landscapeRight : nil)
            if let t = target { UIDevice.current.setValue(t.rawValue, forKey: "orientation") }
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    /// Next lock state: auto → the current orientation → auto.
    static func toggled(from mode: String) -> String {
        guard mode == "auto" else { return "auto" }
        let landscape = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation.isLandscape ?? false
        return landscape ? "landscape" : "portrait"
    }

    static func label(_ mode: String) -> String {
        switch mode {
        case "portrait": return "Rotation locked: portrait"
        case "landscape": return "Rotation locked: landscape"
        default: return "Rotation: automatic"
        }
    }
}
