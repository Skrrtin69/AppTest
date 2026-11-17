import Foundation
import Network
import UIKit

/// Watches the connection type so large downloads can warn on cellular data.
final class NetworkStatus {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private(set) var isCellular = false
    private(set) var isExpensive = false
    /// Any working connection (Wi-Fi, mobile data or wired).
    private(set) var isOnline = true
    /// False until the first answer arrives: before that, the values above are guesses.
    private(set) var known = false

    /// Posted on the main queue when the connection switches between metered and not, or
    /// goes away or comes back.
    static let changed = Notification.Name("MediaDeckNetworkStatusChanged")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            let expensive = path.isExpensive
            let online = path.status == .satisfied
            // The values are read on the main thread, so they're changed there too.
            DispatchQueue.main.async {
                guard let self = self else { return }
                let wasMetered = self.onMeteredData
                let wasOnline = self.isOnline
                self.isCellular = cellular
                self.isExpensive = expensive
                self.isOnline = online
                self.known = true
                // Also on the first answer, so anything waiting for Wi-Fi can start at launch,
                // and when the connection comes back (downloads cut off by it retry).
                if wasMetered != self.onMeteredData || wasOnline != self.isOnline || !self.reported {
                    self.reported = true
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "network.status"))
    }

    private var reported = false

    /// True when downloads would use mobile data (or a metered hotspot).
    var onMeteredData: Bool { isCellular || isExpensive }
}

/// A yes/no question shown above whatever is on screen, awaited from async code.
enum Confirm {
    @MainActor
    static func ask(title: String, message: String, confirm: String) async -> Bool {
        await withCheckedContinuation { cont in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cont.resume(returning: false) })
            alert.addAction(UIAlertAction(title: confirm, style: .default) { _ in cont.resume(returning: true) })
            guard let top = Presenter.topController() else { cont.resume(returning: true); return }
            top.present(alert, animated: true)
        }
    }
}
